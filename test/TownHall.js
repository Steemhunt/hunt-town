const { time, loadFixture } = require('@nomicfoundation/hardhat-network-helpers');
const { expect } = require('chai');

describe('TownHall', function () {
  async function deployFixtures() {
    const Building = await ethers.getContractFactory('Building');
    const building = await Building.deploy();

    const HuntToken = await ethers.getContractFactory('HuntTokenMock');
    const huntToken = await HuntToken.deploy();

    const TownHall = await ethers.getContractFactory('TownHall');
    const townHall = await TownHall.deploy(building.address, huntToken.address);

    await building.setTownHall(townHall.address);

    return [townHall, building, huntToken];
  }

  let townHall, building, huntToken;
  let owner, alice, bob;
  let LOCK_UP_AMOUNT, LOCK_UP_DURATION;
  const INITIAL_ALICE_BALANCE = 4500n * 10n ** 18n;

  beforeEach(async function () {
    [townHall, building, huntToken] = await loadFixture(deployFixtures);
    LOCK_UP_AMOUNT = (await townHall.LOCK_UP_AMOUNT()).toBigInt();
    LOCK_UP_DURATION = (await townHall.LOCK_UP_DURATION()).toBigInt();
    [owner, alice, bob] = await ethers.getSigners();
    await huntToken.transfer(alice.address, INITIAL_ALICE_BALANCE);
  });

  describe('Deployment', function () {
    it('should set the Town Hall address correctly', async function () {
      expect(await building.townHall()).to.equal(townHall.address);
    });

    it('alice should have initial token balance', async function () {
      expect(await huntToken.balanceOf(alice.address)).to.equal(INITIAL_ALICE_BALANCE);
    });
  });

  describe('Mint', function () {
    describe('Normal cases', async function () {
      beforeEach(async function () {
        await huntToken.connect(alice).approve(townHall.address, LOCK_UP_AMOUNT);
        await townHall.connect(alice).mint(alice.address);
      });

      it('should create a building NFT and send it to alice', async function () {
        expect(await building.totalSupply()).to.equal(1);
        expect(await building.ownerOf(0)).to.equal(alice.address);
      });

      it('should set correct mintedAt timestamp', async function () {
        expect(await townHall.mintedAt(0)).to.equal(await time.latest());
      });

      it('should return correct unlockTime', async function () {
        expect(await townHall.unlockTime(0)).to.equal(BigInt(await time.latest()) + LOCK_UP_DURATION);
      });

      it('should also be able to call unlockTime from building contract', async function () {
        expect(await building.unlockTime(0)).to.equal(await townHall.unlockTime(0));
      });

      it("should decrease Alice's balance by LOCK_UP_AMOUNT", async function () {
        expect(await huntToken.balanceOf(alice.address)).to.equal(INITIAL_ALICE_BALANCE - LOCK_UP_AMOUNT);
      });

      it("should increase TownHall's balance by LOCK_UP_AMOUNT", async function () {
        expect(await huntToken.balanceOf(townHall.address)).to.equal(LOCK_UP_AMOUNT);
      });

      it('should emit Mint event', async function () {
        await huntToken.connect(alice).approve(townHall.address, LOCK_UP_AMOUNT);

        const nextBlockTimestamp = BigInt(await time.latest()) + 10n;
        await time.setNextBlockTimestamp(nextBlockTimestamp); // set the timestamp of the next block but don't mine a new block

        await expect(townHall.connect(alice).mint(alice.address))
          .emit(townHall, 'Mint')
          .withArgs(alice.address, 1, nextBlockTimestamp);
      });
    });

    describe('Edge cases', function () {
      it('should revert if alice does not have enough balance', async function () {
        const mintingCount = BigInt(parseInt(INITIAL_ALICE_BALANCE / LOCK_UP_AMOUNT));
        await huntToken.connect(alice).approve(townHall.address, LOCK_UP_AMOUNT * mintingCount);

        for (let i = 0; i < mintingCount; i++) {
          await townHall.connect(alice).mint(alice.address);
        }

        // NFT count
        expect(await building.balanceOf(alice.address)).to.equal(mintingCount);

        // Left over HUNT amount
        expect(await huntToken.balanceOf(alice.address)).to.equal(
          INITIAL_ALICE_BALANCE - LOCK_UP_AMOUNT * mintingCount
        );

        // one more try should fail
        await expect(townHall.connect(alice).mint(alice.address)).to.be.revertedWith('ERC20: insufficient allowance');
      });

      it('should be able to mint the NFT to a different address', async function () {
        await huntToken.connect(alice).approve(townHall.address, LOCK_UP_AMOUNT);
        await townHall.connect(alice).mint(bob.address);

        expect(await building.balanceOf(alice.address)).to.equal(0);
        expect(await building.balanceOf(bob.address)).to.equal(1);

        // Deduct HUNT tokens from caller, not the receiver
        expect(await huntToken.balanceOf(alice.address)).to.equal(INITIAL_ALICE_BALANCE - LOCK_UP_AMOUNT);
      });

      it("should revert on mintedAt if the token hasn't minted", async function () {
        await expect(townHall.mintedAt(0)).to.be.revertedWithCustomError(townHall, 'TownHall__InvalidTokenId');
      });

      it("should revert on unlockTime if the token hasn't minted", async function () {
        await expect(townHall.unlockTime(0)).to.be.revertedWithCustomError(townHall, 'TownHall__InvalidTokenId');
      });
    });
  });

  describe('Burn', function () {
    beforeEach(async function () {
      await huntToken.connect(alice).approve(townHall.address, LOCK_UP_AMOUNT);
      await townHall.connect(alice).mint(alice.address);
    });

    it('should emit Burn event', async function () {
      await time.increaseTo(await townHall.unlockTime(0));

      const nextBlockTimestamp = BigInt(await time.latest()) + 10n;
      await time.setNextBlockTimestamp(nextBlockTimestamp); // set the timestamp of the next block but don't mine a new block

      await expect(townHall.connect(alice).burn(0))
        .emit(townHall, 'Burn')
        .withArgs(alice.address, 0, nextBlockTimestamp);
    });

    describe('Normal cases', async function () {
      beforeEach(async function () {
        await time.increaseTo(await townHall.unlockTime(0));
        await townHall.connect(alice).burn(0);
      });

      it('should burn the NFT', async function () {
        await expect(building.ownerOf(0)).to.be.revertedWith('ERC721: invalid token ID');
      });

      it('should decrease the totalSupply', async function () {
        expect(await building.totalSupply()).to.equal(0);
      });

      it('should not decrease the tokenId', async function () {
        expect(await building.nextId()).to.equal(1);
      });

      it('should refund locked HUNT tokens to the owner', async function () {
        expect(await huntToken.balanceOf(alice.address)).to.equal(INITIAL_ALICE_BALANCE);
      });

      it('should decrease the HUNT token balance from townHall contracct', async function () {
        expect(await huntToken.balanceOf(townHall.address)).to.equal(0);
      });
    });

    describe('Edge cases', async function () {
      it('should revert if before unlockTime', async function () {
        await expect(townHall.connect(alice).burn(0)).to.be.revertedWithCustomError(
          townHall,
          'TownHall__LockUpPeroidStillLeft'
        );
      });

      it('should revert if the user does not have the ownership or approval', async function () {
        await time.increaseTo(await townHall.unlockTime(0));
        await expect(townHall.connect(owner).burn(0)).to.be.revertedWithCustomError(
          building,
          'Building__NotOwnerOrApproved'
        );
      });

      it('should not revert if the caller is approved to spend the NFT', async function () {
        await time.increaseTo(await townHall.unlockTime(0));
        await building.connect(alice).approve(bob.address, 0);
        await townHall.connect(bob).burn(0);

        await expect(building.ownerOf(0)).to.be.revertedWith('ERC721: invalid token ID');

        // should refund to the caller instead of the owner
        expect(await huntToken.balanceOf(alice.address)).to.equal(INITIAL_ALICE_BALANCE - LOCK_UP_AMOUNT);
        expect(await huntToken.balanceOf(bob.address)).to.equal(LOCK_UP_AMOUNT);
      });
    });
  });
});
