const { loadFixture } = require("@nomicfoundation/hardhat-network-helpers");
const { expect } = require("chai");

describe("Building", function () {
  async function deployBuildingFixture() {
    const Building = await ethers.getContractFactory("Building");
    const building = await Building.deploy();

    return building;
  }

  let building;
  let owner, alice;

  beforeEach(async function() {
    building = await loadFixture(deployBuildingFixture);
    [ owner, alice ] = await ethers.getSigners();
    await building.setTownHall(owner.address); // Set TownHall as deployer for testing purpose
  });

  describe("Deployment", function () {
    it("should set the right owner", async function () {
      expect(await building.owner()).to.equal(owner.address);
    });

    it("should have 0 total supply initially", async function () {
      expect(await building.totalSupply()).to.equal(0);
    });
  });

  describe("Minting", function () {
    describe("Normal Flow", function() {
      beforeEach(async function() {
        await building.safeMint(owner.address);
      });
      it("should mint a token", async function () {
        expect(await building.ownerOf(0)).to.equal(owner.address);
      });
      it("should mint a token to alice", async function () {
        await building.safeMint(alice.address);
        expect(await building.ownerOf(1)).to.equal(alice.address);
      });
      it("should increase the total supply", async function () {
        expect(await building.totalSupply()).to.equal(1);
      });
      it("should increase the tokenId counter", async function () {
        expect(await building.nextId()).to.equal(1);
      });
      it("should set the correct tokenURI", async function () {
        expect(await building.tokenURI(0)).to.equal("https://api.hunt.town/token-metadata/buildings/0.json");
      });
      it("should revert on unlockTime if the ownership has not transferred to TownHall", async function() {
        await expect(building.unlockTime(0)).to.be.reverted;
      });
      it("should have correct royalty info", async function() {
        const info = await building.royaltyInfo("0", "100");
        expect(info[0]).to.equal(owner.address); // collection creator
        expect(info[1]).to.equal("5"); // 5%
      });
    }); // Normal Flow
    describe("Edge Cases", function() {
      it("should not possible to overwrite the TownHall address once it's initialized", async function() {
        await expect(building.setTownHall(alice.address)).to.be.revertedWithCustomError(
          building,
          "Building__CannotChangeTownHallAddress"
        );
      });
      it("should reject if not owner", async function () {
        await expect(building.connect(alice).safeMint(owner.address)).to.be.revertedWithCustomError(
          building,
          "Building__CallerIsNotTownHall"
        );
      });
    }); // Edge Cases
  }); // Minting

  describe("Burning", function () {
    describe("Normal Flow", function() {
      beforeEach(async function() {
        await building.safeMint(owner.address);
        await building.burn(0, owner.address);
      });
      it("should burn the token", async function () {
        await expect(building.ownerOf(0)).to.be.revertedWith(
          "ERC721: invalid token ID"
        );
      });
      it("should decrease the total supply", async function () {
        expect(await building.totalSupply()).to.equal(0);
      });
      it("should leave the tokenId counter the same", async function () {
        expect(await building.nextId()).to.equal(1);
      });
    }); // Normal Flow
    describe("Edge Cases", function() {
      beforeEach(async function() {
        await building.safeMint(owner.address);
      });
      it("should reject if the msg.sender is not owner", async function () {
        await expect(building.connect(alice).burn(0, owner.address)).to.be.revertedWithCustomError(
          building,
          "Building__CallerIsNotTownHall"
        );
      });
      it("should reject if the msgSender parameter is not the token holder", async function () {
        await expect(building.burn(0, alice.address)).to.be.revertedWithCustomError(
          building,
          "Building__NotOwnerOrApproved"
        );
      });
      it("should reject if the the token has been transferred", async function() {
        await building.transferFrom(owner.address, alice.address, 0);
        await expect(building.burn(0, owner.address)).to.be.revertedWithCustomError(
          building,
          "Building__NotOwnerOrApproved"
        );
      });
      it("should allow owner to burn someone else's token if the msgSender is the token holder", async function() {
        await building.transferFrom(owner.address, alice.address, 0);
        await building.burn(0, alice.address);
        await expect(building.ownerOf(0)).to.be.revertedWith(
          "ERC721: invalid token ID"
        );
      });
      it("should allow owner to burn someone else's token if the msgSender has been approved", async function() {
        await building.approve(alice.address, 0);
        await building.burn(0, alice.address);
        await expect(building.ownerOf(0)).to.be.revertedWith(
          "ERC721: invalid token ID"
        );
      });
    }); // Edge Cases
  }); // Burning
});
