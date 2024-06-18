import { loadFixture, impersonateAccount } from "@nomicfoundation/hardhat-toolbox-viem/network-helpers";
import { expect } from "chai";
import hre, { ignition } from "hardhat";
import HuntGrantModule from "../ignition/modules/HuntGrant";
import { getAddress, parseEther, getContract } from "viem";
import { TOWN_HALL_ADDRESS, BUILDING_NFT_ADDRESS, HUNT_ADDRESS } from "./utils";
import { abi as ERC721_ABI } from "@openzeppelin/contracts/build/contracts/ERC721.json";
import { abi as ERC20_ABI } from "@openzeppelin/contracts/build/contracts/ERC20.json";

// NOTE: hardhat-chai-matchers is not officially supported yet, so adding a custom npm package here
// REF: https://github.com/NomicFoundation/hardhat/issues/4874
require("hardhat-chai-matchers-viem");

const INITIAL_HUNT_BALANCE = parseEther("100000");

describe("HuntGrant", function () {
  async function deployFixtures() {
    const [owner, alice, bob, carol, david] = await hre.viem.getWalletClients();
    const { huntGrant } = await ignition.deploy(HuntGrantModule, {
      parameters: {
        HuntGrant: {
          townHall: TOWN_HALL_ADDRESS
        }
      }
    });

    const publicClient = await hre.viem.getPublicClient();

    // HUNT Token
    const impersonatedAddress = "0xCB3f3e0E992435390e686D7b638FCb8baBa6c5c7";
    await impersonateAccount(impersonatedAddress);
    const huntToken = getContract({
      address: HUNT_ADDRESS,
      abi: ERC20_ABI,
      client: owner
    });
    // Send owner's balance to impersonated account
    await huntToken.write.transfer([owner.account.address, INITIAL_HUNT_BALANCE], {
      account: impersonatedAddress
    });

    // Building NFT
    const buildingNFT = getContract({
      address: BUILDING_NFT_ADDRESS,
      abi: ERC721_ABI,
      client: owner
    });

    return [huntGrant, huntToken, buildingNFT, owner, alice, bob, carol, david, publicClient];
  }

  let huntGrant: any,
    huntToken: any,
    buildingNFT: any,
    owner: any,
    alice: any,
    bob: any,
    carol: any,
    david: any,
    publicClient: any;

  beforeEach(async function () {
    [huntGrant, huntToken, buildingNFT, owner, alice, bob, carol, david, publicClient] = await loadFixture(
      deployFixtures
    );
  });

  describe("Deployment", function () {
    it("should set the lastSeason to 0", async function () {
      expect(await huntGrant.read.lastSeason()).to.equal(0n);
    });
    it("should set the currentSeason to 1", async function () {
      expect(await huntGrant.read.currentSeason()).to.equal(1n);
    });
  });

  describe("Deposit and withdraw", function () {
    const DEPOSIT_AMOUNT = parseEther("34000");

    beforeEach(async function () {
      await huntToken.write.approve([huntGrant.address, DEPOSIT_AMOUNT]);
      await huntGrant.write.deposit([DEPOSIT_AMOUNT]);
    });

    it("should deposit the correct amount", async function () {
      expect(await huntToken.read.balanceOf([huntGrant.address])).to.equal(DEPOSIT_AMOUNT);
    });

    it("should be able to emergency withdraw by owner", async function () {
      const originalBalance = await huntToken.read.balanceOf([owner.account.address]);
      await huntGrant.write.emergencyWithdraw();
      expect(await huntToken.read.balanceOf([huntGrant.address])).to.equal(0n);
      expect(await huntToken.read.balanceOf([owner.account.address])).to.equal(originalBalance + DEPOSIT_AMOUNT);
    });

    it("should not be able to emergency withdraw by non-owner", async function () {
      await expect(huntGrant.write.emergencyWithdraw([], { account: alice.account })).to.be.rejectedWith(
        "OwnableUnauthorizedAccount"
      );
    });

    it("should emit Deposit event on deposit", async function () {
      await huntToken.write.approve([huntGrant.address, DEPOSIT_AMOUNT]);
      await expect(huntGrant.write.deposit([DEPOSIT_AMOUNT]))
        .to.emit(huntGrant, "Deposit")
        .withArgs(getAddress(owner.account.address), DEPOSIT_AMOUNT);
    });

    it("should emit EmergencyWithdraw event on emergency withdraw", async function () {
      await expect(huntGrant.write.emergencyWithdraw())
        .to.emit(huntGrant, "EmergencyWithdraw")
        .withArgs(getAddress(owner.account.address), DEPOSIT_AMOUNT);
    });

    describe("Set Winners", function () {
      beforeEach(async function () {
        this.SEASON_PARAMS = [
          1n,
          [getAddress(alice.account.address), getAddress(bob.account.address), getAddress(carol.account.address)],
          [parseEther("20000"), parseEther("10000"), parseEther("4000")]
        ];
      });

      it("should emit SetWinners event on setting winners", async function () {
        await expect(huntGrant.write.setWinners(this.SEASON_PARAMS))
          .to.emit(huntGrant, "SetWinners")
          .withArgs(1n, this.SEASON_PARAMS[1], this.SEASON_PARAMS[2]);
      });

      describe("Normal Flow", function () {
        beforeEach(async function () {
          await huntGrant.write.setWinners(this.SEASON_PARAMS);
        });

        it("should increase the current season id", async function () {
          expect(await huntGrant.read.currentSeason()).to.equal(2n);
        });

        it("should set winners correctly", async function () {
          const { grantDistributed, winners, maxGrantAmounts, claimedTypes } = await huntGrant.read.getSeason([1n]);

          expect(grantDistributed).to.equal(0n);
          expect(winners).to.deep.equal(this.SEASON_PARAMS[1]);
          expect(maxGrantAmounts).to.deep.equal(this.SEASON_PARAMS[2]);
          expect(claimedTypes).to.deep.equal([0, 0, 0]);
        });
      }); // Normal Flow

      describe("Set Winners - Edge cases", function () {
        it("should not be able to set winners by non-owner", async function () {
          await expect(
            huntGrant.write.setWinners(this.SEASON_PARAMS, {
              account: alice.account
            })
          ).to.be.rejectedWith("OwnableUnauthorizedAccount");
        });

        it("should not be able to set the season id = 0", async function () {
          await expect(
            huntGrant.write.setWinners([
              0n, // Prev season
              this.SEASON_PARAMS[1],
              this.SEASON_PARAMS[2]
            ])
          ).to.be.rejectedWith("InvalidSeasonId");
        });

        it("should not be able to set the season id next to the current season", async function () {
          await expect(
            huntGrant.write.setWinners([
              2n, // must be the current season id
              this.SEASON_PARAMS[1],
              this.SEASON_PARAMS[2]
            ])
          ).to.be.rejectedWith("InvalidSeasonId");
        });

        it("cannot overwrite the already declared winners", async function () {
          await huntGrant.write.setWinners(this.SEASON_PARAMS);

          await expect(
            huntGrant.write.setWinners([
              1n, // must be the current season id
              this.SEASON_PARAMS[1],
              this.SEASON_PARAMS[2]
            ])
          ).to.be.rejectedWith("SeasonDataAlreadyExists");
        });

        it("cannot set the maxGrants params more than the current balance", async function () {
          await expect(
            huntGrant.write.setWinners([
              1n, // must be the current season id
              this.SEASON_PARAMS[1],
              [parseEther("20000"), parseEther("10000"), parseEther("5000")]
            ])
          ).to.be.rejectedWith("NotEnoughGrantBalance");
        });
      }); // Set Winners - Edge cases

      describe("Claim", function () {
        beforeEach(async function () {
          await huntGrant.write.setWinners(this.SEASON_PARAMS);
        });

        it("should claim with 100% buildings - rank 1st", async function () {
          await huntGrant.write.claim([1n, 1], { account: alice.account });
          expect(await buildingNFT.read.balanceOf([alice.account.address])).to.equal(20n);
        });

        it("should claim with 100% buildings - rank 2nd", async function () {
          await huntGrant.write.claim([1n, 1], { account: bob.account });
          expect(await buildingNFT.read.balanceOf([bob.account.address])).to.equal(10n);
        });

        it("should claim with 100% buildings - rank 3rd", async function () {
          await huntGrant.write.claim([1n, 1], { account: carol.account });
          expect(await buildingNFT.read.balanceOf([carol.account.address])).to.equal(4n);
        });

        it("should claim with 50% buildings - rank 1st", async function () {
          await huntGrant.write.claim([1n, 2], { account: alice.account });
          expect(await buildingNFT.read.balanceOf([alice.account.address])).to.equal(10n);
          expect(await huntToken.read.balanceOf([alice.account.address])).to.equal(parseEther("5000"));
        });

        it("should claim with 50% buildings - rank 2nd", async function () {
          await huntGrant.write.claim([1n, 2], { account: bob.account });
          expect(await buildingNFT.read.balanceOf([bob.account.address])).to.equal(5n);
          expect(await huntToken.read.balanceOf([bob.account.address])).to.equal(parseEther("2500"));
        });

        it("should claim with 50% buildings - rank 3rd", async function () {
          await huntGrant.write.claim([1n, 2], { account: carol.account });
          expect(await buildingNFT.read.balanceOf([carol.account.address])).to.equal(2n);
          expect(await huntToken.read.balanceOf([carol.account.address])).to.equal(parseEther("1000"));
        });

        it("should claim with 100% liquidity - rank 1st", async function () {
          await huntGrant.write.claim([1n, 3], { account: alice.account });
          expect(await buildingNFT.read.balanceOf([alice.account.address])).to.equal(0n);
          expect(await huntToken.read.balanceOf([alice.account.address])).to.equal(parseEther("10000"));
        });

        it("should claim with 100% liquidity - rank 2nd", async function () {
          await huntGrant.write.claim([1n, 3], { account: bob.account });
          expect(await buildingNFT.read.balanceOf([bob.account.address])).to.equal(0n);
          expect(await huntToken.read.balanceOf([bob.account.address])).to.equal(parseEther("5000"));
        });

        it("should claim with 100% liquidity - rank 3rd", async function () {
          await huntGrant.write.claim([1n, 3], { account: carol.account });
          expect(await buildingNFT.read.balanceOf([carol.account.address])).to.equal(0n);
          expect(await huntToken.read.balanceOf([carol.account.address])).to.equal(parseEther("2000"));
        });

        it("should emit Claim event on claiming", async function () {
          await expect(huntGrant.write.claim([1n, 1n], { account: alice.account }))
            .to.emit(huntGrant, "Claim")
            .withArgs(getAddress(alice.account.address), 1n, 0n, 1n, 20n, 0n);
        });

        describe("Claim - Edge cases", function () {
          it("should not be able to claim with invalid season id", async function () {
            await expect(huntGrant.write.claim([0n, 1], { account: alice.account })).to.be.rejectedWith("NotAWinner");
          });

          it("should not be able to claim with invalid claim type", async function () {
            await expect(huntGrant.write.claim([1n, 4], { account: alice.account })).to.be.rejectedWith(
              "InvalidClaimType"
            );
          });

          it("should not be able to claim twice", async function () {
            await huntGrant.write.claim([1n, 1], { account: alice.account });
            await expect(huntGrant.write.claim([1n, 1], { account: alice.account })).to.be.rejectedWith(
              "AlreadyClaimed"
            );
          });
        }); // Claim - Edge cases
      }); // Claim
    }); // Set Winners
  }); // Deposit and withdraw
}); // HuntGrant
