import { loadFixture, impersonateAccount, time } from "@nomicfoundation/hardhat-toolbox-viem/network-helpers";
import { expect } from "chai";
import hre, { ignition } from "hardhat";
import BuilderGrantModule from "../ignition/modules/BuilderGrant";
import { getAddress, parseEther, getContract } from "viem";
import { MCV2_BOND_ADDRESS, HUNT_BASE_ADDRESS, MINI_BUILDING_ADDRESS } from "./utils";
import { abi as ERC1155_ABI } from "@openzeppelin/contracts/build/contracts/ERC1155.json";
import { abi as ERC20_ABI } from "@openzeppelin/contracts/build/contracts/ERC20.json";

// NOTE: hardhat-chai-matchers is not officially supported yet, so adding a custom npm package here
// REF: https://github.com/NomicFoundation/hardhat/issues/4874
require("hardhat-chai-matchers-viem");

const INITIAL_HUNT_BALANCE = parseEther("100000");

describe("BuilderGrant", function () {
  async function deployFixtures() {
    const [owner, alice, bob, carol] = await hre.viem.getWalletClients();
    const { builderGrant } = await ignition.deploy(BuilderGrantModule, {
      parameters: {
        BuilderGrant: {
          mcv2Bond: MCV2_BOND_ADDRESS,
          huntBase: HUNT_BASE_ADDRESS,
          miniBuilding: MINI_BUILDING_ADDRESS
        }
      }
    });

    // HUNT Token
    const impersonatedAddress = "0xCB3f3e0E992435390e686D7b638FCb8baBa6c5c7";
    await impersonateAccount(impersonatedAddress);
    const huntToken = getContract({
      address: HUNT_BASE_ADDRESS,
      abi: ERC20_ABI,
      client: owner
    });
    // Send owner's balance to impersonated account
    await huntToken.write.transfer([owner.account.address, INITIAL_HUNT_BALANCE], {
      account: impersonatedAddress
    });

    // Mini Building NFT
    const miniBuildingNFT = getContract({
      address: MINI_BUILDING_ADDRESS,
      abi: ERC1155_ABI,
      client: owner
    });

    return [builderGrant, huntToken, miniBuildingNFT, owner, alice, bob, carol];
  }

  let builderGrant: any, huntToken: any, miniBuildingNFT: any, owner: any, alice: any, bob: any, carol: any;

  beforeEach(async function () {
    [builderGrant, huntToken, miniBuildingNFT, owner, alice, bob, carol] = await loadFixture(deployFixtures);
  });

  describe("Deployment", function () {
    it("should set the lastSeason to 0", async function () {
      expect(await builderGrant.read.lastSeason()).to.equal(0n);
    });
    it("should set the currentSeason to 1", async function () {
      expect(await builderGrant.read.currentSeason()).to.equal(1n);
    });
  });

  describe("Deposit and withdraw", function () {
    const DEPOSIT_AMOUNT = parseEther("2000");

    beforeEach(async function () {
      await huntToken.write.approve([builderGrant.address, 999999999n * 10n ** 18n]);
      await builderGrant.write.deposit([DEPOSIT_AMOUNT]);
    });

    it("should deposit the correct amount", async function () {
      expect(await huntToken.read.balanceOf([builderGrant.address])).to.equal(DEPOSIT_AMOUNT);
    });

    it("should be able to emergency withdraw by owner", async function () {
      const originalBalance = await huntToken.read.balanceOf([owner.account.address]);
      await builderGrant.write.emergencyWithdraw();
      expect(await huntToken.read.balanceOf([builderGrant.address])).to.equal(0n);
      expect(await huntToken.read.balanceOf([owner.account.address])).to.equal(originalBalance + DEPOSIT_AMOUNT);
    });

    it("should not be able to emergency withdraw by non-owner", async function () {
      await expect(builderGrant.write.emergencyWithdraw([], { account: alice.account })).to.be.rejectedWith(
        "OwnableUnauthorizedAccount"
      );
    });

    it("should emit Deposit event on deposit", async function () {
      await expect(builderGrant.write.deposit([DEPOSIT_AMOUNT]))
        .to.emit(builderGrant, "Deposit")
        .withArgs(getAddress(owner.account.address), DEPOSIT_AMOUNT);
    });

    it("should emit EmergencyWithdraw event on emergency withdraw", async function () {
      await expect(builderGrant.write.emergencyWithdraw())
        .to.emit(builderGrant, "EmergencyWithdraw")
        .withArgs(getAddress(owner.account.address), DEPOSIT_AMOUNT);
    });

    describe("Set Season Data", function () {
      beforeEach(async function () {
        // Generate dummy fids, addresses for rankers
        const fids = Array.from({ length: 10 }, (_, i) => {
          return BigInt(i + 10000);
        });
        const accounts = Array.from({ length: 10 }, (_, i) => {
          return `0x${(i + 1).toString().padStart(40, "0")}`;
        });

        this.SEASON_PARAMS = [
          0n,
          [10n, 6n, 4n],
          [8151n, 8152n, 8942n, ...fids],
          [
            getAddress(alice.account.address),
            getAddress(bob.account.address),
            getAddress(carol.account.address),
            ...accounts
          ]
        ];
      });

      it("should emit SetSeasonData event on setting winners", async function () {
        await expect(builderGrant.write.setSeasonData(this.SEASON_PARAMS))
          .to.emit(builderGrant, "SetSeasonData")
          .withArgs(0n, 13n, this.SEASON_PARAMS[1]);
      });

      describe("Normal Flow", function () {
        beforeEach(async function () {
          await builderGrant.write.setSeasonData(this.SEASON_PARAMS);
        });

        it("should increase the current season id", async function () {
          expect(await builderGrant.read.currentSeason()).to.equal(0n);
        });

        it("should set season data correctly", async function () {
          const { claimStartedAt, totalClaimed, grants, rankers } = await builderGrant.read.getSeason([0n]);

          expect(claimStartedAt).to.equal(await time.latest());
          expect(totalClaimed).to.equal(0n);
          expect(grants).to.deep.equal(this.SEASON_PARAMS[1].map((amount: bigint) => ({ claimedType: 0n, amount })));
          expect(rankers).to.deep.equal(
            this.SEASON_PARAMS[2].map((fid: number, i: number) => ({
              fid: fid,
              wallet: this.SEASON_PARAMS[3][i],
              claimedAmount: 0,
              donationReceived: [false, false, false]
            }))
          );
        });
      }); // Normal Flow

      describe.only("Set Season Data - Edge cases", function () {
        it("should not be able to set winners by non-owner", async function () {
          await expect(
            builderGrant.write.setSeasonData(this.SEASON_PARAMS, {
              account: alice.account
            })
          ).to.be.rejectedWith("OwnableUnauthorizedAccount");
        });

        it("should not be able to set the season id next to the current season", async function () {
          await expect(
            builderGrant.write.setSeasonData([
              1n, // must be the current season id
              this.SEASON_PARAMS[1],
              this.SEASON_PARAMS[2],
              this.SEASON_PARAMS[3]
            ])
          ).to.be.rejectedWith("InvalidSeasonId");
        });

        it("can overwrite the data if not claimed", async function () {
          await builderGrant.write.setSeasonData(this.SEASON_PARAMS);

          await builderGrant.write.setSeasonData([
            0n,
            [8n, 6n, 4n],
            this.SEASON_PARAMS[2],
            [
              getAddress(carol.account.address),
              getAddress(bob.account.address),
              getAddress(alice.account.address),
              ...this.SEASON_PARAMS[3].slice(3)
            ]
          ]);

          const { grants, rankers } = await builderGrant.read.getSeason([0n]);
          expect(grants[0]).to.deep.equal({ claimedType: 0n, amount: 8n });
          expect(rankers[0].wallet).to.equal(getAddress(carol.account.address));
        });

        it("should not be able to set grants amount if not even", async function () {
          await expect(
            builderGrant.write.setSeasonData([0n, [9n, 6n, 4n], this.SEASON_PARAMS[2], this.SEASON_PARAMS[3]])
          ).to.be.rejectedWith("InvalidGrantAmount");
        });

        it("can NOT overwrite the datat if anyone has claimed", async function () {
          await builderGrant.write.setSeasonData(this.SEASON_PARAMS);

          await builderGrant.write.claimByTop3([0n, 0, 1], { account: alice.account });
          await builderGrant.write.deposit([DEPOSIT_AMOUNT]); // To prevent NotEnoughGrantBalance() error comes out first

          await expect(builderGrant.write.setSeasonData(this.SEASON_PARAMS)).to.be.rejectedWith(
            "SeasonDataIsNotUpdateable"
          );
        });

        it("cannot set the maxGrants params more than the current balance", async function () {
          await builderGrant.write.emergencyWithdraw();
          await builderGrant.write.deposit([DEPOSIT_AMOUNT - 1n]);

          await expect(builderGrant.write.setSeasonData(this.SEASON_PARAMS)).to.be.rejectedWith(
            "NotEnoughGrantBalance"
          );
        });
      }); // Set Season Data - Edge cases

      describe("Claim", function () {
        beforeEach(async function () {
          await builderGrant.write.setSeasonData(this.SEASON_PARAMS);
        });

        it("should claim with 100% self - rank 1st", async function () {
          await builderGrant.write.claimByTop3([1n, 0, 1], { account: alice.account });
          expect(await miniBuildingNFT.read.balanceOf([alice.account.address], 1)).to.equal(200n);
        });

        it("should claim with 50% donation - rank 1st", async function () {
          await builderGrant.write.claimByTop3([1n, 0, 2], { account: alice.account });
          expect(await miniBuildingNFT.read.balanceOf([alice.account.address], 1)).to.equal(100n);
          // Check donations
          const { rankers } = await builderGrant.read.getSeason([1n]);
          for (let i = 3; i < 103; i++) {
            expect(rankers[i].donationReceived[0]).to.be.true;
          }
        });

        it("should claim with 100% donation - rank 1st", async function () {
          await builderGrant.write.claimByTop3([1n, 0, 3], { account: alice.account });
          // Check donations
          const { rankers } = await builderGrant.read.getSeason([1n]);
          for (let i = 3; i < 203; i++) {
            expect(rankers[i].donationReceived[0]).to.be.true;
          }
        });

        it("should emit ClaimByTop3 event on claiming", async function () {
          await expect(builderGrant.write.claimByTop3([1n, 0, 1], { account: alice.account }))
            .to.emit(builderGrant, "ClaimByTop3")
            .withArgs(getAddress(alice.account.address), 1n, 0, 1, 200n, 0n);
        });

        describe("After Claimed", function () {
          beforeEach(async function () {
            await builderGrant.write.claimByTop3([1n, 0, 1], { account: alice.account }); // 200 mini buildings
            await builderGrant.write.claimByTop3([1n, 1, 2], { account: bob.account }); // 50 mini buildings + 50 donations
            await builderGrant.write.claimByTop3([1n, 2, 3], { account: carol.account }); // 40 donations
          });

          it("should record claimedTypes correctly", async function () {
            const { claimedTypes } = await builderGrant.read.getSeason([1n]);
            expect(claimedTypes).to.deep.equal([1, 2, 3]);
          });

          it("should record the grantClaimed correctly", async function () {
            const { grantClaimed } = await builderGrant.read.getSeason([1n]);
            expect(grantClaimed).to.equal(290n);
          });

          it("should have the correct balance of HUNT", async function () {
            expect(await huntToken.read.balanceOf([builderGrant.address])).to.equal(parseEther("10000"));
          });

          it("should not touch winners data", async function () {
            const { winners } = await builderGrant.read.getSeason([1n]);
            expect(winners).to.deep.equal([
              getAddress(alice.account.address),
              getAddress(bob.account.address),
              getAddress(carol.account.address)
            ]);
          });
        });

        describe("Claim - Edge cases", function () {
          it("should not be able to claim with invalid season id", async function () {
            await expect(builderGrant.write.claimByTop3([0n, 0, 1], { account: alice.account })).to.be.rejectedWith(
              "NotARanker"
            );
          });

          it("should not be able to claim with invalid claim type", async function () {
            await expect(builderGrant.write.claimByTop3([1n, 0, 4], { account: alice.account })).to.be.rejectedWith(
              "InvalidClaimType"
            );
          });

          it("should not be able to claim twice", async function () {
            await builderGrant.write.claimByTop3([1n, 0, 1], { account: alice.account });
            await expect(builderGrant.write.claimByTop3([1n, 0, 1], { account: alice.account })).to.be.rejectedWith(
              "AlreadyClaimed"
            );
          });
        }); // Claim - Edge cases
      }); // Claim
    }); // Set Season Data
  }); // Deposit and withdraw
}); // BuilderGrant
