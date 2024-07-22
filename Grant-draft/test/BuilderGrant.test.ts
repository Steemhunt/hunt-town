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
    it("current should be 0", async function () {
      expect(await builderGrant.read.currentSeason()).to.equal(0n);
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

    it("should handle withdrawal when balance is zero", async function () {
      await builderGrant.write.emergencyWithdraw();
      await expect(builderGrant.write.emergencyWithdraw()).to.be.rejectedWith("NothingToWithdraw");
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

        this.accounts = (await hre.viem.getWalletClients()).slice(1, 14);
        this.SEASON_PARAMS = [
          0n,
          [10n, 6n, 4n],
          [8151n, 8152n, 8942n, ...fids],
          [...this.accounts.map((account: any) => getAddress(account.account.address))] // alice, bob, carol, ... until rank 13
        ];
      });

      it("should emit SetSeasonData event on setting winners", async function () {
        await expect(builderGrant.write.setSeasonData(this.SEASON_PARAMS))
          .to.emit(builderGrant, "SetSeasonData")
          .withArgs(0n, 13n, this.SEASON_PARAMS[1]);
      });

      it("should not set season data with empty rankers list", async function () {
        await expect(builderGrant.write.setSeasonData([0n, [10n, 6n, 4n], [], []])).to.be.rejectedWith(
          "InvalidRankersParams"
        );
      });

      it("should not set season data with mismatched fids and wallets", async function () {
        await expect(
          builderGrant.write.setSeasonData([0n, [10n, 6n, 4n], [8151n, 8152n], [getAddress(alice.account.address)]])
        ).to.be.rejectedWith("InvalidRankersParams");
      });

      describe("Normal Flow", function () {
        beforeEach(async function () {
          await builderGrant.write.setSeasonData(this.SEASON_PARAMS);
        });

        it("should increase the current season id", async function () {
          expect(await builderGrant.read.currentSeason()).to.equal(1n);
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

      describe("Set Season Data - Edge cases", function () {
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
          await builderGrant.write.claimByTop3([0n, 0n, 1n], { account: alice.account });
          expect(await miniBuildingNFT.read.balanceOf([alice.account.address, 0n])).to.equal(10n);
        });

        it("should claim with 50% donation - rank 1st", async function () {
          await builderGrant.write.claimByTop3([0n, 0n, 2n], { account: alice.account });
          expect(await miniBuildingNFT.read.balanceOf([alice.account.address, 0n])).to.equal(5n);
          // Check donations
          const { rankers } = await builderGrant.read.getSeason([0n]);
          for (let i = 3; i < 8; i++) {
            expect(rankers[i].donationReceived[0]).to.be.true;
          }
          for (let i = 8; i < 13; i++) {
            expect(rankers[i].donationReceived[0]).to.be.false;
          }
        });

        it("should claim with 100% donation - rank 1st", async function () {
          await builderGrant.write.claimByTop3([0n, 0n, 3n], { account: alice.account });
          expect(await miniBuildingNFT.read.balanceOf([alice.account.address, 0n])).to.equal(0n);
          // Check donations
          const { rankers } = await builderGrant.read.getSeason([0n]);
          for (let i = 3; i < 13; i++) {
            expect(rankers[i].donationReceived[0]).to.be.true;
          }
        });

        it("should emit ClaimByTop3 event on claiming", async function () {
          await expect(builderGrant.write.claimByTop3([0n, 0n, 2n], { account: alice.account }))
            .to.emit(builderGrant, "ClaimByTop3")
            .withArgs(getAddress(alice.account.address), 0n, 0n, 2n, 5n, 5n);
        });

        it("should not claim with rank not in top 3", async function () {
          await expect(builderGrant.write.claimByTop3([0n, 3n, 1n], { account: alice.account })).to.be.rejectedWith(
            "InvalidRankingParam"
          );
        });

        it("should not be able to claim with invalid season id", async function () {
          await expect(builderGrant.write.claimByTop3([1n, 0n, 1n], { account: alice.account })).to.be.rejectedWith(
            "InvalidSeasonId"
          );
        });

        it("should not be able to claim with invalid claim type", async function () {
          await expect(builderGrant.write.claimByTop3([0n, 0n, 4n], { account: alice.account })).to.be.rejectedWith(
            "InvalidClaimType"
          );
        });

        it("should not be able to claim twice", async function () {
          await builderGrant.write.claimByTop3([0n, 0n, 1n], { account: alice.account });
          await expect(builderGrant.write.claimByTop3([0n, 0n, 1n], { account: alice.account })).to.be.rejectedWith(
            "AlreadyClaimed"
          );
        });

        describe("After Claimed", function () {
          beforeEach(async function () {
            await builderGrant.write.claimByTop3([0n, 0n, 1n], { account: alice.account }); // 10 mini buildings
            await builderGrant.write.claimByTop3([0n, 1n, 2n], { account: bob.account }); // 3 mini buildings + 3 donations
          });

          it("should record claimedTypes correctly", async function () {
            const { grants } = await builderGrant.read.getSeason([0n]);
            expect(grants[0].claimedType).to.equal(1n);
            expect(grants[1].claimedType).to.equal(2n);
            expect(grants[2].claimedType).to.equal(0n);
          });

          it("should record the grantClaimed correctly", async function () {
            const { rankers } = await builderGrant.read.getSeason([0n]);
            expect(rankers[0].claimedAmount).to.equal(10n);
            expect(rankers[1].claimedAmount).to.equal(3n);
            expect(rankers[2].claimedAmount).to.equal(0n);
          });

          it("should have the correct balance of HUNT", async function () {
            expect(await huntToken.read.balanceOf([builderGrant.address])).to.equal(parseEther("700")); // 2000 - 13 * 100
          });

          it("should not touch winners data", async function () {
            const { rankers } = await builderGrant.read.getSeason([0n]);
            expect(rankers[0].wallet).to.equal(getAddress(alice.account.address));
            expect(rankers[1].wallet).to.equal(getAddress(bob.account.address));
            expect(rankers[2].wallet).to.equal(getAddress(carol.account.address));
          });

          describe("Claim Donations by top 4 and below", function () {
            beforeEach(async function () {
              // alice: 0 donations
              // bob: 3 donations - rank 4th - 6th
              await builderGrant.write.claimByTop3([0n, 2n, 3n], { account: carol.account }); // carol: 4 donations - rank 4th - 7th
              // should be immediately claimable once all top3 decided
            });

            it("should be set donation claimable", async function () {
              expect(await builderGrant.read.isDonationClaimableNow([0n])).to.be.true;
            });

            it("rank 4th should have 2 donations available", async function () {
              expect(await builderGrant.read.claimableDonationAmount([0n, 3n])).to.equal(2n);
            });

            it("should record where donations from correctly", async function () {
              const { rankers } = await builderGrant.read.getSeason([0n]);
              expect(rankers[3].donationReceived[0]).to.be.false;
              expect(rankers[3].donationReceived[1]).to.be.true;
              expect(rankers[3].donationReceived[2]).to.be.true;
            });

            it("should be able to claim donations", async function () {
              await builderGrant.write.claimDonation([0n, 3n], { account: this.accounts[3].account });
              await builderGrant.write.claimDonation([0n, 4n], { account: this.accounts[4].account });
              await builderGrant.write.claimDonation([0n, 5n], { account: this.accounts[5].account });
              await builderGrant.write.claimDonation([0n, 6n], { account: this.accounts[6].account });
              expect(await miniBuildingNFT.read.balanceOf([this.accounts[3].account.address, 0n])).to.equal(2n); // 4th
              expect(await miniBuildingNFT.read.balanceOf([this.accounts[4].account.address, 0n])).to.equal(2n); // 5th
              expect(await miniBuildingNFT.read.balanceOf([this.accounts[5].account.address, 0n])).to.equal(2n); // 6th
              expect(await miniBuildingNFT.read.balanceOf([this.accounts[6].account.address, 0n])).to.equal(1n); // 7th
            });

            it("should not claim donations with invalid season id", async function () {
              await expect(builderGrant.write.claimDonation([1n, 3n], { account: alice.account })).to.be.rejectedWith(
                "InvalidSeasonId"
              );
            });

            it("should not claim donations with invalid rank", async function () {
              await expect(builderGrant.write.claimDonation([0n, 20n], { account: alice.account })).to.be.rejectedWith(
                "InvalidRankingParam"
              );
            });
          }); // Claim donations by top 4 and below

          describe("Claim donations - edge cases", function () {
            // Status:
            // - alice: 0 donations
            // - bob: 3 donations - rank 4th - 6th
            // carol: not decided yet

            it("should not be able to claim donations until top3 have not decided yet", async function () {
              expect(await builderGrant.read.isDonationClaimableNow([0n])).to.be.false;
            });

            it("should revert with DonationNotClaimableYet", async function () {
              await expect(
                builderGrant.read.claimableDonationAmount([0n, 3n], { account: alice.account })
              ).to.be.rejectedWith("DonationNotClaimableYet");
            });

            describe("Top3 claim deadline passed", function () {
              beforeEach(async function () {
                await time.increase(86400 * 8); // 8 days passed
              });

              it("should be able to claim donations if top3 claim deadline passed", async function () {
                expect(await builderGrant.read.isDonationClaimableNow([0n])).to.be.true;
              });

              it("should record where donations from correctly", async function () {
                const { rankers } = await builderGrant.read.getSeason([0n]);
                expect(rankers[3].donationReceived[0]).to.be.false;
                expect(rankers[3].donationReceived[1]).to.be.true;
                expect(rankers[3].donationReceived[2]).to.be.false;
              });

              it("should return claimable donation amount correctly", async function () {
                expect(await builderGrant.read.claimableDonationAmount([0n, 2n])).to.equal(0n); // 3th (carol)
                expect(await builderGrant.read.claimableDonationAmount([0n, 3n])).to.equal(1n); // 4th
                expect(await builderGrant.read.claimableDonationAmount([0n, 4n])).to.equal(1n); // 5th
                expect(await builderGrant.read.claimableDonationAmount([0n, 5n])).to.equal(1n); // 6th
                expect(await builderGrant.read.claimableDonationAmount([0n, 6n])).to.equal(0n); // 7th
              });

              it("should be able to claim donations", async function () {
                await builderGrant.write.claimDonation([0n, 3n], { account: this.accounts[3].account });
                await builderGrant.write.claimDonation([0n, 4n], { account: this.accounts[4].account });
                await builderGrant.write.claimDonation([0n, 5n], { account: this.accounts[5].account });
                expect(await miniBuildingNFT.read.balanceOf([this.accounts[3].account.address, 0n])).to.equal(1n);
                expect(await miniBuildingNFT.read.balanceOf([this.accounts[4].account.address, 0n])).to.equal(1n);
                expect(await miniBuildingNFT.read.balanceOf([this.accounts[5].account.address, 0n])).to.equal(1n);
              });

              it("should not be able to claim donations if already claimed", async function () {
                await builderGrant.write.claimDonation([0n, 3n], { account: this.accounts[3].account });
                await expect(
                  builderGrant.write.claimDonation([0n, 3n], { account: this.accounts[3].account })
                ).to.be.rejectedWith("AlreadyClaimed");
              });

              it("should not be able to claim donations if the msg.sender is not the winner", async function () {
                await expect(
                  builderGrant.write.claimDonation([0n, 3n], { account: this.accounts[4].account })
                ).to.be.rejectedWith("PermissionDenied");
              });

              it("should not be able to claim donations if the claim deadline has passed", async function () {
                await time.increase(86400 * 21); // 21 more days passed -> 29 days passed
                await expect(
                  builderGrant.write.claimDonation([0n, 3n], { account: this.accounts[3].account })
                ).to.be.rejectedWith("DonationClaimDeadlineReached");
              });
            }); // Top3 claim deadline passed
          }); // Claim donations - edge cases
        }); // After Claimed
      }); // Claim
    }); // Set Season Data
  }); // Deposit and withdraw
}); // BuilderGrant
