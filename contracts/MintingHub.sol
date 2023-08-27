// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./utils/Ownable.sol";

import "./interface/IERC20.sol";
import "./interface/IReserve.sol";
import "./interface/IFrankencoin.sol";
import "./interface/IPosition.sol";

/**
 * The central hub for creating, cloning and challenging collateralized Frankencoin positions.
 * Only one instance of this contract is required, whereas every new position comes with a new position
 * contract. Pending challenges are stored as structs in an array.
 */
contract MintingHub {
    /**
     * Irrevocable fee in ZCHF when proposing a new position (but not when cloning an existing one).
     */
    uint256 public constant OPENING_FEE = 1000 * 10 ** 18;

    /**
     * When a challenge is split, this is the minimum bid amount each of the two resulting challenges
     * should have.
     */
    uint256 public constant MIN_SPLIT_OFF_VALUE = 2_500 ether; // 2500 ZCHF

    /**
     * The challenger reward in parts per million (ppm) relative to the challenged amount, whereas
     * challenged amount if defined as the challenged collateral amount times the liquidation price.
     */
    uint32 public constant CHALLENGER_REWARD = 20000; // 2%

    IPositionFactory private immutable POSITION_FACTORY; // position contract to clone

    IFrankencoin public immutable zchf; // currency
    Challenge[] public challenges; // list of open challenges

    /**
     * Map to remember pending postponed collateral returns.
     * It maps collateral => beneficiary => amount.
     */
    mapping(address collateral => mapping(address owner => uint256 amount)) public pendingReturns;

    struct Challenge {
        address challenger; // the address from which the challenge was initiated
        IPosition position; // the position that was challenged
        uint256 size; // how much collateral the challenger provided
        uint256 end; // the deadline of the challenge (block.timestamp)
        address bidder; // the address from which the highest bid was made, if any
        uint256 bid; // the highest bid in ZCHF (total amount, not price per unit)
    }

    event PositionOpened(address indexed owner, address indexed position, address zchf, address collateral, uint256 price);
    event ChallengeStarted(address indexed challenger, address indexed position, uint256 size, uint256 number);
    event ChallengeAverted(address indexed position, uint256 number);
    event ChallengeSucceeded(address indexed position, uint256 bid, uint256 number);
    event NewBid(uint256 challengedId, uint256 bidAmount, address bidder);
    event PostPonedReturn(address collateral, address indexed beneficiary, uint256 amount);

    constructor(address _zchf, address _factory) {
        zchf = IFrankencoin(_zchf);
        POSITION_FACTORY = IPositionFactory(_factory);
    }

    function openPositionOneWeek(
        address _collateralAddress,
        uint256 _minCollateral,
        uint256 _initialCollateral,
        uint256 _mintingMaximum,
        uint256 _expirationSeconds,
        uint256 _challengeSeconds,
        uint32 _yearlyInterestPPM,
        uint256 _liqPrice,
        uint32 _reservePPM
    ) public returns (address) {
        return
            openPosition(
                _collateralAddress,
                _minCollateral,
                _initialCollateral,
                _mintingMaximum,
                7 days,
                _expirationSeconds,
                _challengeSeconds,
                _yearlyInterestPPM,
                _liqPrice,
                _reservePPM
            );
    }

    /**
     * Open a collateralized loan position. See also https://docs.frankencoin.com/positions/open .
     * For a successful call, you must set an allowance for the collateral token, allowing
     * the minting hub to transfer the initial collateral amount to the newly created position and to
     * withdraw the fees.
     *
     * @param _collateralAddress        address of collateral token
     * @param _minCollateral     minimum collateral required to prevent dust amounts
     * @param _initialCollateral amount of initial collateral to be deposited
     * @param _mintingMaximum    maximal amount of ZCHF that can be minted by the position owner
     * @param _expirationSeconds position tenor in unit of timestamp (seconds) from 'now'
     * @param _challengeSeconds  challenge period. Longer for less liquid collateral.
     * @param _yearlyInterestPPM ppm of minted amount that is paid as fee to the equity contract for each year of duration
     * @param _liqPrice          Liquidation price with (36 - token decimals) decimals,
     *                           e.g. 18 decimals for an 18 decimal collateral, 36 decimals for a 0 decimal collateral.
     * @param _reservePPM        ppm of minted amount that is locked as borrower's reserve, e.g. 20%
     * @return address           address of created position
     */
    function openPosition(
        address _collateralAddress,
        uint256 _minCollateral,
        uint256 _initialCollateral,
        uint256 _mintingMaximum,
        uint256 _initPeriodSeconds,
        uint256 _expirationSeconds,
        uint256 _challengeSeconds,
        uint32 _yearlyInterestPPM,
        uint256 _liqPrice,
        uint32 _reservePPM
    ) public returns (address) {
        require(_yearlyInterestPPM <= 1000000);
        require(_reservePPM <= 1000000);
        IPosition pos = IPosition(
            POSITION_FACTORY.createNewPosition(
                msg.sender,
                address(zchf),
                _collateralAddress,
                _minCollateral,
                _mintingMaximum,
                _initPeriodSeconds,
                _expirationSeconds,
                _challengeSeconds,
                _yearlyInterestPPM,
                _liqPrice,
                _reservePPM
            )
        );
        require(IERC20(_collateralAddress).decimals() <= 24); // leaves 12 digits for price
        require(_initialCollateral >= _minCollateral, "must start with min col");
        require(_minCollateral * _liqPrice >= 5000 ether); // must start with at least 5000 ZCHF worth of collateral
        zchf.registerPosition(address(pos));
        zchf.transferFrom(msg.sender, address(zchf.reserve()), OPENING_FEE);
        IERC20(_collateralAddress).transferFrom(msg.sender, address(pos), _initialCollateral);

        emit PositionOpened(msg.sender, address(pos), address(zchf), _collateralAddress, _liqPrice);
        return address(pos);
    }

    modifier validPos(address position) {
        require(zchf.isPosition(position) == address(this), "not our pos");
        _;
    }

    /**
     * Clones an existing position and immediately tries to mint the specified amount using the given amount of collateral.
     * This requires an allowance to be set on the collateral contract such that the minting hub can withdraw the collateral.
     */
    function clonePosition(address position, uint256 _initialCollateral, uint256 _initialMint, uint256 expiration) public validPos(position) returns (address) {
        IPosition existing = IPosition(position);
        existing.reduceLimitForClone(_initialMint, expiration);
        address pos = POSITION_FACTORY.clonePosition(position);
        zchf.registerPosition(pos);
        IPosition(pos).initializeClone(msg.sender, existing.price(), _initialCollateral, _initialMint, expiration);
        existing.collateral().transferFrom(msg.sender, pos, _initialCollateral); // At the end to guard against ERC-777 reentrancy

        emit PositionOpened(msg.sender, address(pos), address(zchf), address(existing.collateral()), existing.price());
        return address(pos);
    }

    /**
     * Launch a challenge on a position
     * @param _positionAddr      address of the position we want to challenge
     * @param _collateralAmount  size of the collateral we want to challenge (dec 18)
     * @return index of the challenge in challenge-array
     */
    function launchChallenge(address _positionAddr, uint256 _collateralAmount, uint256 expectedPrice) external validPos(_positionAddr) returns (uint256) {
        IPosition position = IPosition(_positionAddr);
        if (position.price() != expectedPrice) revert UnexpectedPrice();
        IERC20(position.collateral()).transferFrom(msg.sender, address(this), _collateralAmount); // At the beginning to guard against ERC-777 reentrancy
        uint256 pos = challenges.length;
        challenges.push(Challenge(msg.sender, position, _collateralAmount, block.timestamp + position.challengePeriod(), address(0x0), 0));
        position.notifyChallengeStarted(_collateralAmount);
        emit ChallengeStarted(msg.sender, address(position), _collateralAmount, pos);
        return pos;
    }

    error UnexpectedPrice();
    error SplitTooSmall(uint256 size1, uint256 size2);

    /**
     * Splits a challenge into two smaller challenges.
     * This can be useful to guard an attack, where a challenger launches a challenge so big that most bidders do not
     * have the liquidity available to bid a sufficient amount. With this function, the can split of smaller slices of
     * the challenge and avert it piece by piece.
     */
    function splitChallenge(uint256 _challengeNumber, uint256 splitOffAmount) external returns (uint256) {
        Challenge storage challenge = challenges[_challengeNumber];
        require(challenge.challenger != address(0x0));
        Challenge memory copy = Challenge(
            challenge.challenger,
            challenge.position,
            splitOffAmount,
            challenge.end,
            challenge.bidder,
            (challenge.bid * splitOffAmount) / challenge.size
        );
        challenge.bid -= copy.bid;
        challenge.size -= copy.size;

        uint256 min = IPosition(challenge.position).minimumCollateral();
        require(challenge.size >= min);
        require(copy.size >= min);
        if (challenge.bid < MIN_SPLIT_OFF_VALUE || copy.bid < MIN_SPLIT_OFF_VALUE) revert SplitTooSmall(challenge.bid, copy.bid);

        uint256 pos = challenges.length;
        challenges.push(copy);
        emit ChallengeStarted(challenge.challenger, address(challenge.position), challenge.size, _challengeNumber);
        emit ChallengeStarted(copy.challenger, address(copy.position), copy.size, pos);
        return pos;
    }

    function minBid(uint256 challenge) public view returns (uint256) {
        return _minBid(challenges[challenge]);
    }

    /**
     * The minimum bid size for the next bid. It must be 0.5% higher than the previous bid.
     */
    function _minBid(Challenge storage challenge) internal view returns (uint256) {
        return (challenge.bid * 1005) / 1000;
    }

    /**
     * Post a bid in ZCHF given an open challenge. Requires a ZCHF allowance from the caller to the minting hub.
     *
     * @param _challengeNumber   index of the challenge as broadcast in the event
     * @param _bidAmountZCHF     how much to bid for the collateral of this challenge (dec 18)
     * @param expectedSize       size verification to guard against frontrunners doing a split-challenge-attack
     */
    function bid(uint256 _challengeNumber, uint256 _bidAmountZCHF, uint256 expectedSize) external {
        Challenge storage challenge = challenges[_challengeNumber];

        // Deactivated: if (block.timestamp >= challenge.end) revert TooLate();
        // Reason: in case the bidder got blacklisted by the collateral issuer, it should be possible to bid even higher

        if (expectedSize != challenge.size) revert UnexpectedSize();
        if (challenge.bid > 0) {
            zchf.transfer(challenge.bidder, challenge.bid); // return old bid
        }
        emit NewBid(_challengeNumber, _bidAmountZCHF, msg.sender);
        IPosition pos = challenge.position;
        uint256 size_ = challenge.size;
        uint256 endTime = challenge.end;
        // ask position if the bid was high enough to avert the challenge
        if (pos.tryAvertChallenge(size_, _bidAmountZCHF, endTime)) {
            // bid was high enough, let bidder buy collateral from challenger
            emit ChallengeAverted(address(pos), _challengeNumber);
            zchf.transferFrom(msg.sender, challenge.challenger, _bidAmountZCHF);
            delete challenges[_challengeNumber]; // delete challenge before transferring collateral to avoid ERC777 re-entrency
            pos.collateral().transfer(msg.sender, size_);
        } else {
            // challenge is not averted, update bid
            if (_bidAmountZCHF < _minBid(challenge)) revert BidTooLow(_bidAmountZCHF, _minBid(challenge));
            uint256 earliestEnd = block.timestamp + 30 minutes;
            if (earliestEnd >= endTime) {
                // bump remaining time like ebay does when last minute bids come in
                // An attacker trying to postpone the challenge forever must increase the bid by 0.5%
                // every 30 minutes, or double it every three days, making the attack hard to sustain
                // for a prolonged period of time.
                challenge.end = earliestEnd;
            }
            zchf.transferFrom(msg.sender, address(this), _bidAmountZCHF);
            challenge.bid = _bidAmountZCHF;
            challenge.bidder = msg.sender;
        }
    }

    error TooLate();
    error UnexpectedSize();
    error BidTooLow(uint256 bid, uint256 min);

    function isChallengeOpen(uint256 _challengeNumber) external view returns (bool) {
        return challenges[_challengeNumber].end > block.timestamp;
    }

    /**
     * Ends a challenge successfully after the auction period ended, whereas successfully means that the challenger
     * could show that the price of the collateral is too low to make the position well-collateralized.
     *
     * In case that the collateral cannot be transfered back to the challenger (i.e. because the collateral token has a blacklist and the
     * challenger is on it), it is possible to postpone the return of the collateral.
     *
     * @param postponeCollateralReturn Can be used to postpone the return of the collateral to the challenger. Usually false.
     */
    function end(uint256 _challengeNumber, bool postponeCollateralReturn) public {
        Challenge memory challenge = challenges[_challengeNumber];
        require(challenge.challenger != address(0x0));
        require(block.timestamp >= challenge.end, "period has not ended");
        delete challenges[_challengeNumber]; // delete first to avoid reentrancy with ERC-777 tokens

        // challenge must have been successful, because otherwise it would have immediately ended on placing the winning bid

        // notify the position that will send the collateral to the bidder. If there is no bid, send the collateral to msg.sender
        address recipient = challenge.bidder == address(0x0) ? msg.sender : challenge.bidder;
        (address owner, uint256 effectiveBid, uint256 repayment, uint32 reservePPM) = challenge.position.notifyChallengeSucceeded(
            recipient,
            challenge.bid,
            challenge.size
        );
        if (effectiveBid < challenge.bid) {
            // overbid, return excess amount
            IERC20(zchf).transfer(recipient, challenge.bid - effectiveBid);
        }
        uint256 reward = (effectiveBid * CHALLENGER_REWARD) / 1000_000;
        uint256 fundsNeeded = reward + repayment;
        if (effectiveBid > fundsNeeded) {
            zchf.transfer(owner, effectiveBid - fundsNeeded);
        } else if (effectiveBid < fundsNeeded) {
            zchf.notifyLoss(fundsNeeded - effectiveBid); // ensure we have enough to pay everything
        }
        zchf.transfer(challenge.challenger, reward); // pay out the challenger reward
        zchf.burnWithoutReserve(repayment, reservePPM); // Repay the challenged part
        _returnCollateral(challenge.position.collateral(), challenge.challenger, challenge.size, postponeCollateralReturn);
        emit ChallengeSucceeded(address(challenge.position), challenge.bid, _challengeNumber);
    }

    /**
     * Challengers can call this method to withdraw collateral whose return was postponed.
     */
    function returnPostponedCollateral(address collateral, address target) external {
        uint256 amount = pendingReturns[collateral][msg.sender];
        delete pendingReturns[collateral][msg.sender];
        IERC20(collateral).transfer(target, amount);
    }

    function _returnCollateral(IERC20 collateral, address recipient, uint256 amount, bool postpone) internal {
        if (postpone) {
            // Postponing helps in case the challenger was blacklisted on the collateral token or otherwise cannot receive it at the moment.
            pendingReturns[address(collateral)][recipient] += amount;
            emit PostPonedReturn(address(collateral), recipient, amount);
        } else {
            collateral.transfer(recipient, amount); // return the challenger's collateral
        }
    }
}

interface IPositionFactory {
    function createNewPosition(
        address _owner,
        address _zchf,
        address _collateral,
        uint256 _minCollateral,
        uint256 _initialLimit,
        uint256 _initPeriodSeconds,
        uint256 _duration,
        uint256 _challengePeriod,
        uint32 _yearlyInterestPPM,
        uint256 _liqPrice,
        uint32 _reserve
    ) external returns (address);

    function clonePosition(address _existing) external returns (address);
}
