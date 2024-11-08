import { expect } from "chai";
import { floatToDec18 } from "../scripts/math";
import { ethers } from "hardhat";
import { dEURO, StablecoinBridge, TestToken } from "../typechain";
import { evm_increaseTime } from "./helper";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";

describe("Plugin Veto Tests", () => {
  let owner: HardhatEthersSigner;
  let alice: HardhatEthersSigner;

  let bridge: StablecoinBridge;
  let secondBridge: StablecoinBridge;
  let dEURO: dEURO;
  let mockxEURO: TestToken;
  let mockyEURO: TestToken;

  before(async () => {
    [owner, alice] = await ethers.getSigners();
    // create contracts
    const dEUROFactory = await ethers.getContractFactory("dEURO");
    dEURO = await dEUROFactory.deploy(10 * 86400);

    // mocktoken
    const xEUROFactory = await ethers.getContractFactory("TestToken");
    mockxEURO = await xEUROFactory.deploy("CryptoFranc", "xEURO", 18);
    // mocktoken bridge to bootstrap
    let limit = floatToDec18(100_000);
    const bridgeFactory = await ethers.getContractFactory("StablecoinBridge");
    bridge = await bridgeFactory.deploy(
      await mockxEURO.getAddress(),
      await dEURO.getAddress(),
      limit
    );
    await dEURO.initialize(await bridge.getAddress(), "");
    // wait for 1 block
    await evm_increaseTime(60);
    // now we are ready to bootstrap dEURO with Mock-xEURO
    await mockxEURO.mint(owner.address, limit / 2n);
    await mockxEURO.mint(alice.address, limit / 2n);
    // mint some dEURO to block bridges without veto
    let amount = floatToDec18(20_000);
    await mockxEURO.connect(alice).approve(await bridge.getAddress(), amount);
    await bridge.connect(alice).mint(amount);
    // owner also mints some to be able to veto
    await mockxEURO.approve(await bridge.getAddress(), amount);
    await bridge.mint(amount);
  });

  describe("create secondary bridge plugin", () => {
    it("create mock yEURO token&bridge", async () => {
      let limit = floatToDec18(100_000);
      const xEUROFactory = await ethers.getContractFactory("TestToken");
      mockyEURO = await xEUROFactory.deploy("Test Name", "Symbol", 18);
      await mockyEURO.mint(alice.address, floatToDec18(100_000));

      const bridgeFactory = await ethers.getContractFactory("StablecoinBridge");
      secondBridge = await bridgeFactory.deploy(
        await mockyEURO.getAddress(),
        await dEURO.getAddress(),
        limit
      );
    });
    it("Participant suggests minter", async () => {
      let applicationPeriod = await dEURO.MIN_APPLICATION_PERIOD();
      let applicationFee = await dEURO.MIN_FEE();
      let msg = "yEURO Bridge";
      await mockxEURO
        .connect(alice)
        .approve(await dEURO.getAddress(), applicationFee);
      let balance = await dEURO.balanceOf(alice.address);
      expect(balance).to.be.greaterThan(applicationFee);
      await expect(
        dEURO
          .connect(alice)
          .suggestMinter(
            await secondBridge.getAddress(),
            applicationPeriod,
            applicationFee,
            msg
          )
      ).to.emit(dEURO, "MinterApplied");
    });
    it("can't mint before min period", async () => {
      let amount = floatToDec18(1_000);
      await mockyEURO
        .connect(alice)
        .approve(await secondBridge.getAddress(), amount);
      // set allowance
      await expect(
        secondBridge.connect(alice).mint(amount)
      ).to.be.revertedWithCustomError(dEURO, "NotMinter");
    });
    it("deny minter", async () => {
      await expect(
        dEURO.denyMinter(await secondBridge.getAddress(), [], "other denied")
      ).to.emit(dEURO, "MinterDenied");
      await expect(
        secondBridge.connect(alice).mint(floatToDec18(1_000))
      ).to.be.revertedWithCustomError(dEURO, "NotMinter");
    });
  });
});
