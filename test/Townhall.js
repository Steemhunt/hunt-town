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
  let owner, alice, bob;
  let LOCK_UP_AMOUNT, LOCK_UP_DURATION;
  const INITIAL_ALICE_BALANCE = 4500n * 10n**18n;

  beforeEach(async function() {
    [ townhall, building, huntToken ] = await loadFixture(deployFixtures);
    LOCK_UP_AMOUNT = (await townhall.LOCK_UP_AMOUNT()).toBigInt();
    LOCK_UP_DURATION = (await townhall.LOCK_UP_DURATION()).toBigInt();
    [ owner, alice, bob ] = await ethers.getSigners();
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
    describe("Normal cases", async function() {
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

    describe.only("Edge cases", function() {
      it("should revert if alice does not have enough balance", async function() {
        const mintingCount = BigInt(parseInt(INITIAL_ALICE_BALANCE / LOCK_UP_AMOUNT));
        await huntToken.connect(alice).approve(townhall.address, LOCK_UP_AMOUNT * mintingCount);

        for(let i = 0; i < mintingCount; i++) {
          await townhall.connect(alice).mint();
        }

        // NFT count
        expect(await building.balanceOf(alice.address)).to.equal(mintingCount);

        // Left over HUNT amount
        expect(await huntToken.balanceOf(alice.address)).to.equal(INITIAL_ALICE_BALANCE - LOCK_UP_AMOUNT * mintingCount);

        // one more try should fail
        await expect(townhall.connect(alice).mint()).to.be.revertedWith("ERC20: insufficient allowance");
      });
    });
  });

  describe("Burn", function () {
    beforeEach(async function() {
      await huntToken.connect(alice).approve(townhall.address, LOCK_UP_AMOUNT);
      await townhall.connect(alice).mint();
    });

    describe("Normal cases", async function() {
      beforeEach(async function() {
        await time.increaseTo(await townhall.unlockTime(0));
        await townhall.connect(alice).burn(0);
      });

      it("should burn the NFT", async function () {
        await expect(building.ownerOf(0)).to.be.revertedWith("ERC721: invalid token ID");
      });

      it("should decrease the totalSupply", async function() {
        expect(await building.totalSupply()).to.equal(0);
      });

      it("should not decrease the tokenId", async function() {
        expect(await building.nextId()).to.equal(1);
      });

      it("should refund locked HUNT tokens to the owner", async function() {
        expect(await huntToken.balanceOf(alice.address)).to.equal(INITIAL_ALICE_BALANCE);
      });

      it("should decrease the HUNT token balance from townhall contracct", async function() {
        expect(await huntToken.balanceOf(townhall.address)).to.equal(0);
      });
    });

    describe("Edge cases", async function() {
      it("should revert if before unlockTime", async function () {
        await expect(townhall.connect(alice).burn(0)).to.be.revertedWithCustomError(townhall, "Townhall__LockUpPeroidStillLeft");
      });

      it("should revert if the user does not have the ownership or approval", async function() {
        await time.increaseTo( await townhall.unlockTime(0));
        await expect(townhall.connect(owner).burn(0)).to.be.revertedWithCustomError(building, "Building__NotOwnerOrApproved");
      });

      it("should not revert if the caller is approved to spend the NFT", async function() {
        await time.increaseTo( await townhall.unlockTime(0));
        await building.connect(alice).approve(bob.address, 0);
        await townhall.connect(bob).burn(0);

        await expect(building.ownerOf(0)).to.be.revertedWith("ERC721: invalid token ID");

        // should refund to the caller instead of the owner
        expect(await huntToken.balanceOf(alice.address)).to.equal(INITIAL_ALICE_BALANCE - LOCK_UP_AMOUNT);
        expect(await huntToken.balanceOf(bob.address)).to.equal(LOCK_UP_AMOUNT);
      });
    });
  });
});
