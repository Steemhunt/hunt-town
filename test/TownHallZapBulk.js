const { time, loadFixture } = require("@nomicfoundation/hardhat-network-helpers");
const { expect } = require("chai");

describe("TownHallZap - Bulk", function () {
  let townHallZap, townHall, building, huntToken;
  let owner, alice;
  let LOCK_UP_AMOUNT, LOCK_UP_DURATION;
  const TEST_COUNT = 10;
  const INITIAL_ALICE_BALANCE = BigInt(TEST_COUNT) * 1000n * 10n**18n;

  async function deployFixtures() {
    const Building = await ethers.getContractFactory("Building");
    const building = await Building.deploy();

    const HuntToken = await ethers.getContractFactory("HuntTokenMock");
    const huntToken = await HuntToken.deploy();

    const TownHall = await ethers.getContractFactory("TownHall");
    const townHall = await TownHall.deploy(building.address, huntToken.address);
    await building.setTownHall(townHall.address);

    const TownHallZap = await ethers.getContractFactory("TownHallZap");
    const townHallZap = await TownHallZap.deploy(townHall.address, huntToken.address);

    return [ townHallZap, townHall, building, huntToken ];
  }

  beforeEach(async function() {
    [ townHallZap, townHall, building, huntToken ] = await loadFixture(deployFixtures);
    LOCK_UP_AMOUNT = (await townHall.LOCK_UP_AMOUNT()).toBigInt();
    LOCK_UP_DURATION = (await townHall.LOCK_UP_DURATION()).toBigInt();
    [ owner, alice ] = await ethers.getSigners();
    await huntToken.transfer(alice.address, INITIAL_ALICE_BALANCE);
  });

  describe("Bulk Minting", function () {
    beforeEach(async function() {
      await huntToken.connect(alice).approve(townHallZap.address, LOCK_UP_AMOUNT * BigInt(TEST_COUNT));
      await townHallZap.connect(alice).mintBulk(alice.address, TEST_COUNT);
    });

    it("should mint many building NFTs and send it to alice", async function() {
      expect(await building.totalSupply()).to.equal(TEST_COUNT);
      expect(await building.balanceOf(alice.address)).to.equal(TEST_COUNT);
    });

    it("should set correct mintedAt timestamp", async function() {
      for(let i = 0; i < TEST_COUNT; i++) {
        expect(await townHall.mintedAt(0)).to.equal(await time.latest());
      }
    });

    it("should return correct unlockTime", async function() {
      for(let i = 0; i < TEST_COUNT; i++) {
        expect(await townHall.unlockTime(0)).to.equal(BigInt(await time.latest()) + LOCK_UP_DURATION);
      }
    });

    it("should decrease Alice's balance by LOCK_UP_AMOUNT x TEST_COUNT", async function() {
      expect(await huntToken.balanceOf(alice.address)).to.equal(INITIAL_ALICE_BALANCE - LOCK_UP_AMOUNT * BigInt(TEST_COUNT));
    });

    it("should increase TownHall's balance by LOCK_UP_AMOUNT", async function() {
      expect(await huntToken.balanceOf(townHall.address)).to.equal(LOCK_UP_AMOUNT * BigInt(TEST_COUNT));
    });
  }); // MintBulk

  describe("Edge Cases", function() {
    it("should revert if too many minting count", async function() {
      await expect(townHallZap.connect(alice).mintBulk(alice.address, 201)).to.be.revertedWithCustomError(
        townHallZap,
        "TownHallZap__TooManyCount"
      );
    });
  });
});
