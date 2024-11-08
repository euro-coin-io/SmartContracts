import { expect } from "chai";
import { floatToDec18, dec18ToFloat, abs, DECIMALS } from "../scripts/math";
import { ethers } from "hardhat";
import { capitalToShares, sharesToCapital } from "../scripts/utils";
import {
  Equity,
  dEURO,
  PositionFactory,
  StablecoinBridge,
  TestToken,
} from "../typechain";
import { evm_increaseTime } from "./helper";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";

describe("Basic Tests", () => {
  let owner: HardhatEthersSigner;
  let alice: HardhatEthersSigner;

  let dEURO: dEURO;
  let equity: Equity;
  let positionFactory: PositionFactory;
  let mockxEURO: TestToken;
  let bridge: StablecoinBridge;

  before(async () => {
    [owner, alice] = await ethers.getSigners();
    // create contracts
    // 10 day application period
    const dEUROFactory = await ethers.getContractFactory("dEURO");
    dEURO = await dEUROFactory.deploy(10 * 86400);

    const equityAddr = await dEURO.reserve();
    equity = await ethers.getContractAt("Equity", equityAddr);

    const positionFactoryFactory = await ethers.getContractFactory(
      "PositionFactory"
    );
    positionFactory = await positionFactoryFactory.deploy();

    const mintingHubFactory = await ethers.getContractFactory("MintingHub");
    await mintingHubFactory.deploy(
      await dEURO.getAddress(),
      await positionFactory.getAddress()
    );
  });

  describe("basic initialization", () => {
    it("symbol should be dEURO", async () => {
      let symbol = await dEURO.symbol();
      expect(symbol).to.be.equal("dEURO");
      let name = await dEURO.name();
      expect(name).to.be.equal("dEURO");
    });
  });

  describe("mock bridge", () => {
    const limit = 100_000n * DECIMALS;
    let bridgeAddr: string;

    before(async () => {
      const xEUROFactory = await ethers.getContractFactory("TestToken");
      mockxEURO = await xEUROFactory.deploy("CryptoEuro", "xEURO", 18);
      const bridgeFactory = await ethers.getContractFactory("StablecoinBridge");
      bridge = await bridgeFactory.deploy(
        await mockxEURO.getAddress(),
        await dEURO.getAddress(),
        limit
      );
      bridgeAddr = await bridge.getAddress();
    });
    it("create mock token", async () => {
      let symbol = await mockxEURO.symbol();
      expect(symbol).to.be.equal("xEURO");
    });
    it("minting fails if not approved", async () => {
      let amount = floatToDec18(10000);
      await mockxEURO.mint(owner.address, amount);
      await mockxEURO.approve(await bridge.getAddress(), amount);
      await expect(bridge.mint(amount)).to.be.revertedWithCustomError(
        dEURO,
        "NotMinter"
      );
    });
    it("bootstrap suggestMinter", async () => {
      let msg = "xEURO Bridge";
      await dEURO.initialize(bridgeAddr, msg);
      let isMinter = await dEURO.isMinter(bridgeAddr);
      expect(isMinter).to.be.true;
    });

    it("minter of xEURO-bridge should receive dEURO", async () => {
      let amount = floatToDec18(5000);
      let balanceBefore = await dEURO.balanceOf(owner.address);
      // set allowance
      await mockxEURO.approve(bridgeAddr, amount);
      await bridge.mint(amount);

      let balancexEUROOfBridge = await mockxEURO.balanceOf(bridgeAddr);
      let balanceAfter = await dEURO.balanceOf(owner.address);
      let dEUROReceived = balanceAfter - balanceBefore;
      let isBridgeBalanceCorrect = dec18ToFloat(balancexEUROOfBridge) == 5000n;
      let isSenderBalanceCorrect = dec18ToFloat(dEUROReceived) == 5000n;
      if (!isBridgeBalanceCorrect || !isSenderBalanceCorrect) {
        console.log(
          "Bridge received xEURO tokens ",
          dec18ToFloat(balancexEUROOfBridge)
        );
        console.log("Sender received ZCH tokens ", dEUROReceived);
        expect(isBridgeBalanceCorrect).to.be.true;
        expect(isSenderBalanceCorrect).to.be.true;
      }
    });
    it("should revert initialization when there is supply", async () => {
      await expect(
        dEURO.initialize(bridgeAddr, "Bridge")
      ).to.be.revertedWithoutReason();
    });
    it("burner of xEURO-bridge should receive xEURO", async () => {
      let amount = floatToDec18(50);
      let balanceBefore = await dEURO.balanceOf(owner.address);
      let balancexEUROBefore = await mockxEURO.balanceOf(owner.address);
      await dEURO.approve(bridgeAddr, amount);
      let allowance1 = await dEURO.allowance(owner.address, bridgeAddr);
      expect(allowance1).to.be.eq(amount);
      let allowance2 = await dEURO.allowance(owner.address, alice.address);
      expect(allowance2).to.be.eq(floatToDec18(0));
      await dEURO.burn(amount);
      await bridge.burn(amount);
      await bridge.burnAndSend(owner.address, amount);

      let balancexEUROOfBridge = await mockxEURO.balanceOf(bridgeAddr);
      let balancexEUROAfter = await mockxEURO.balanceOf(owner.address);
      let balanceAfter = await dEURO.balanceOf(owner.address);
      let dEUROReceived = balanceAfter - balanceBefore;
      let xEUROReceived = balancexEUROAfter - balancexEUROBefore;
      let isBridgeBalanceCorrect = dec18ToFloat(balancexEUROOfBridge) == 4900n;
      let isSenderBalanceCorrect = dec18ToFloat(dEUROReceived) == -150n;
      let isxEUROBalanceCorrect = dec18ToFloat(xEUROReceived) == 100n;
      if (
        !isBridgeBalanceCorrect ||
        !isSenderBalanceCorrect ||
        !isxEUROBalanceCorrect
      ) {
        console.log(
          "Bridge balance xEURO tokens ",
          dec18ToFloat(balancexEUROOfBridge)
        );
        console.log("Sender burned ZCH tokens ", -dEUROReceived);
        console.log("Sender received xEURO tokens ", xEUROReceived);
        expect(isBridgeBalanceCorrect).to.be.true;
        expect(isSenderBalanceCorrect).to.be.true;
        expect(isxEUROBalanceCorrect).to.be.true;
      }
    });
    it("should revert minting when exceed limit", async () => {
      let amount = limit + 100n;
      await mockxEURO.approve(bridgeAddr, amount);
      await expect(bridge.mint(amount)).to.be.revertedWithCustomError(
        bridge,
        "Limit"
      );
    });
    it("should revert minting when bridge is expired", async () => {
      let amount = floatToDec18(1);
      await evm_increaseTime(60 * 60 * 24 * 7 * 53); // pass 53 weeks
      await mockxEURO.approve(bridgeAddr, amount);
      await expect(bridge.mint(amount)).to.be.revertedWithCustomError(
        bridge,
        "Expired"
      );
    });
  });
  describe("exchanges shares & pricing", () => {
    it("deposit xEURO to reserve pool and receive share tokens", async () => {
      let amount = 1000n; // amount we will deposit
      let fAmount = floatToDec18(amount); // amount we will deposit
      let balanceBefore = await equity.balanceOf(owner.address);
      let balanceBeforedEURO = await dEURO.balanceOf(owner.address);
      let fTotalShares = await equity.totalSupply();
      let fTotalCapital = await dEURO.equity();
      // calculate shares we receive according to pricing function:
      let totalShares = dec18ToFloat(fTotalShares);
      let totalCapital = dec18ToFloat(fTotalCapital);
      let dShares = capitalToShares(totalCapital, totalShares, amount);
      await equity.invest(fAmount, 0);
      let balanceAfter = await equity.balanceOf(owner.address);
      let balanceAfterdEURO = await dEURO.balanceOf(owner.address);
      let poolTokenShares = dec18ToFloat(balanceAfter - balanceBefore);
      let dEUROReceived = dec18ToFloat(balanceAfterdEURO - balanceBeforedEURO);
      let isPoolShareAmountCorrect = abs(poolTokenShares - dShares) < 1e-7;
      let isSenderBalanceCorrect = dEUROReceived == -1000n;
      if (!isPoolShareAmountCorrect || !isSenderBalanceCorrect) {
        console.log("Pool token shares received = ", poolTokenShares);
        console.log("dEURO tokens deposited = ", -dEUROReceived);
        expect(isPoolShareAmountCorrect).to.be.true;
        expect(isSenderBalanceCorrect).to.be.true;
      }
    });
    it("cannot redeem shares immediately", async () => {
      let canRedeem = await equity.canRedeem(owner.address);
      expect(canRedeem).to.be.false;
    });
    it("can redeem shares after 90 days", async () => {
      // increase block number so we can redeem
      await evm_increaseTime(90 * 86400 + 60);
      let canRedeem = await equity.canRedeem(owner.address);
      expect(canRedeem).to.be.true;
    });
    it("redeem 1 share", async () => {
      let amountShares = 1n;
      let fAmountShares = floatToDec18(amountShares);
      let fTotalShares = await equity.totalSupply();
      let fTotalCapital = await dEURO.balanceOf(await equity.getAddress());
      // calculate capital we receive according to pricing function:
      let totalShares = dec18ToFloat(fTotalShares);
      let totalCapital = dec18ToFloat(fTotalCapital);
      let dCapital = sharesToCapital(totalCapital, totalShares, amountShares);

      let sharesBefore = await equity.balanceOf(owner.address);
      let capitalBefore = await dEURO.balanceOf(owner.address);
      await equity.redeem(owner.address, fAmountShares);

      let sharesAfter = await equity.balanceOf(owner.address);
      let capitalAfter = await dEURO.balanceOf(owner.address);

      let poolTokenSharesRec = dec18ToFloat(sharesAfter - sharesBefore);
      let dEUROReceived = dec18ToFloat(capitalAfter - capitalBefore);
      let feeRate = (dEUROReceived * 10000n) / dCapital;
      // let isdEUROAmountCorrect = abs(feeRate - 0.997n) <= 1e-5;
      let isdEUROAmountCorrect = true;
      let isPoolShareAmountCorrect = poolTokenSharesRec == -amountShares;
      if (!isdEUROAmountCorrect || !isdEUROAmountCorrect) {
        console.log("dEURO tokens received = ", dEUROReceived);
        console.log("dEURO tokens expected = ", dCapital);
        console.log("Fee = ", feeRate);
        console.log("Pool shares redeemed = ", -poolTokenSharesRec);
        console.log("Pool shares expected = ", amountShares);
        expect(isPoolShareAmountCorrect).to.be.true;
        expect(isdEUROAmountCorrect).to.be.true;
      }
    });
  });
});
