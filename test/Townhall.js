const { time, loadFixture } = require("@nomicfoundation/hardhat-network-helpers");
const { expect } = require("chai");

describe("Townhall", function () {
  async function deployFixtures() {
    const Building = await ethers.getContractFactory("Building");
    const building = await Building.deploy();

    const HuntToken = await ethers.getContractFactory("HuntTokenMock");
    const huntToken = await HuntToken.deploy();

    const Townhall = await ethers.getContractFactory("Townhall");
    const townhall = await Townhall.deploy(building.address, huntToken.address);

    await building.transferOwnership(townhall.address);

    return [ townhall, building, huntToken ];
  }

  let townhall, building, huntToken;
  let owner, alice;
  let LOCK_UP_AMOUNT, LOCK_UP_DURATION;
  const INITIAL_ALICE_BALANCE = 10000n * 10n**18n;

  beforeEach(async function() {
    [ townhall, building, huntToken ] = await loadFixture(deployFixtures);
    LOCK_UP_AMOUNT = (await townhall.LOCK_UP_AMOUNT()).toBigInt();
    LOCK_UP_DURATION = (await townhall.LOCK_UP_DURATION()).toBigInt();
    [ owner, alice ] = await ethers.getSigners();
    await huntToken.transfer(alice.address, INITIAL_ALICE_BALANCE);
  });

  describe("Deployment", function () {
    it("should set the right owner", async function() {
      expect(await townhall.owner()).to.equal(owner.address);
    });

    it("should transfer buildling ownership to townhall", async function() {
      expect(await building.owner()).to.equal(townhall.address);
    });

    it("alice should have initial token balance", async function() {
      expect(await huntToken.balanceOf(alice.address)).to.equal(INITIAL_ALICE_BALANCE);
    });
  });

  describe("Mint", function () {
    beforeEach(async function() {
      await huntToken.connect(alice).approve(townhall.address, LOCK_UP_AMOUNT);
      await townhall.connect(alice).mint();
    });

    it("should create a building NFT and send it to alice", async function() {
      expect(await building.totalSupply()).to.equal(1);
      expect(await building.ownerOf(0)).to.equal(alice.address);
    });

    it("should set correct buildingMintedAt timestamp", async function() {
      expect(await townhall.buildingMintedAt(0)).to.equal(await time.latest());
    });

    it("should return correct unlockTime", async function() {
      expect(await townhall.unlockTime(0)).to.equal(BigInt(await time.latest()) + LOCK_UP_DURATION);
    });

    it("should decrease Alice's balance by LOCK_UP_AMOUNT", async function() {
      expect(await huntToken.balanceOf(alice.address)).to.equal(INITIAL_ALICE_BALANCE - LOCK_UP_AMOUNT);
    });

    it("should increase Townhall's balance by LOCK_UP_AMOUNT", async function() {
      expect(await huntToken.balanceOf(townhall.address)).to.equal(LOCK_UP_AMOUNT);
    });

  });

  // describe("Withdrawals", function () {
  //   describe("Validations", function () {
  //     it("Should revert with the right error if called too soon", async function () {
  //       const { lock } = await loadFixture(deployOneYearLockFixture);

  //       await expect(lock.withdraw()).to.be.revertedWith(
  //         "You can't withdraw yet"
  //       );
  //     });

  //     it("Should revert with the right error if called from another account", async function () {
  //       const { lock, unlockTime, otherAccount } = await loadFixture(
  //         deployOneYearLockFixture
  //       );

  //       // We can increase the time in Hardhat Network
  //       await time.increaseTo(unlockTime); ****************************************************

  //       // We use lock.connect() to send a transaction from another account
  //       await expect(lock.connect(otherAccount).withdraw()).to.be.revertedWith(
  //         "You aren't the owner"
  //       );
  //     });

  //     it("Shouldn't fail if the unlockTime has arrived and the owner calls it", async function () {
  //       const { lock, unlockTime } = await loadFixture(
  //         deployOneYearLockFixture
  //       );

  //       // Transactions are sent using the first signer by default
  //       await time.increaseTo(unlockTime);

  //       await expect(lock.withdraw()).not.to.be.reverted;
  //     });
  //   });

  //   describe("Events", function () {
  //     it("Should emit an event on withdrawals", async function () {
  //       const { lock, unlockTime, lockedAmount } = await loadFixture(
  //         deployOneYearLockFixture
  //       );

  //       await time.increaseTo(unlockTime);

  //       await expect(lock.withdraw())
  //         .to.emit(lock, "Withdrawal")
  //         .withArgs(lockedAmount, anyValue); // We accept any value as `when` arg
  //     });
  //   });

  //   describe("Transfers", function () {
  //     it("Should transfer the funds to the owner", async function () {
  //       const { lock, unlockTime, lockedAmount, owner } = await loadFixture(
  //         deployOneYearLockFixture
  //       );

  //       await time.increaseTo(unlockTime);

  //       await expect(lock.withdraw()).to.changeEtherBalances(
  //         [owner, lock],
  //         [lockedAmount, -lockedAmount]
  //       );
  //     });
  //   });
  // });
});
