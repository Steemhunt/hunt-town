import { loadFixture, impersonateAccount, time } from "@nomicfoundation/hardhat-toolbox-viem/network-helpers";
import { expect } from "chai";
import hre, { ignition, network } from "hardhat";
import BuilderGrantV2Module from "../ignition/modules/BuilderGrantV2";
import { getAddress, parseEther, getContract } from "viem";
import { MCV2_BOND_ADDRESS, HUNT_BASE_ADDRESS, MINI_BUILDING_ADDRESS } from "./utils";
import { abi as ERC1155_ABI } from "@openzeppelin/contracts/build/contracts/ERC1155.json";
import { abi as ERC20_ABI } from "@openzeppelin/contracts/build/contracts/ERC20.json";

// NOTE: hardhat-chai-matchers is not officially supported yet, so adding a custom npm package here
// REF: https://github.com/NomicFoundation/hardhat/issues/4874
require("hardhat-chai-matchers-viem");

const INITIAL_HUNT_BALANCE = parseEther("100000");

describe("BuilderGrantV2", function () {
  // We'll return these in our `deployFixtures` function
  let builderGrantV2: any;
  let huntToken: any;
  let miniBuildingNFT: any;
  let owner: any;
  let alice: any;
  let bob: any;
  let carol: any;

  before(async () => {
    // Hard reset (with forking) before all tests to prevent bleeding over from previous BuilderGrantV1 tests
    await network.provider.request({
      method: "hardhat_reset",
      params: [
        {
          forking: {
            jsonRpcUrl: `https://base-mainnet.g.alchemy.com/v2/${process.env.ALCHEMY_API_KEY}`,
            blockNumber: 17162466
          }
        }
      ]
    });
  });

  async function deployFixtures() {
    // Grab signers
    const [owner, alice, bob, carol] = await hre.viem.getWalletClients();

    // Deploy the BuilderGrantV2 contract via Ignition (example)
    const { builderGrantV2 } = await ignition.deploy(BuilderGrantV2Module, {
      parameters: {
        BuilderGrantV2: {
          mcv2Bond: MCV2_BOND_ADDRESS,
          huntBase: HUNT_BASE_ADDRESS,
          miniBuilding: MINI_BUILDING_ADDRESS
        }
      }
    });

    // HUNT Token
    // We impersonate an address that has a large HUNT supply for test funding
    const impersonatedAddress = "0xCB3f3e0E992435390e686D7b638FCb8baBa6c5c7";
    await impersonateAccount(impersonatedAddress);

    // Create a client for HUNT ERC20
    const huntToken = getContract({
      address: HUNT_BASE_ADDRESS,
      abi: ERC20_ABI,
      client: owner
    });

    // Transfer some HUNT to our `owner` so we can use it in tests
    await huntToken.write.transfer([owner.account.address, INITIAL_HUNT_BALANCE], {
      account: impersonatedAddress
    });

    // Mini Building NFT contract reference
    const miniBuildingNFT = getContract({
      address: MINI_BUILDING_ADDRESS,
      abi: ERC1155_ABI,
      client: owner
    });

    return { builderGrantV2, huntToken, miniBuildingNFT, owner, alice, bob, carol };
  }

  beforeEach(async function () {
    // Use Hardhat's "loadFixture" pattern to speed up tests
    ({ builderGrantV2, huntToken, miniBuildingNFT, owner, alice, bob, carol } = await loadFixture(deployFixtures));
  });

  describe("Deployment checks", function () {
    it("currentSeason() should be 0 initially", async function () {
      expect(await builderGrantV2.read.currentSeason()).to.equal(0n);
    });
  });

  describe("Deposit and Withdraw", function () {
    const DEPOSIT_AMOUNT = parseEther("2000");

    beforeEach(async function () {
      // Approve and deposit HUNT into BuilderGrantV2
      await huntToken.write.approve([builderGrantV2.address, DEPOSIT_AMOUNT]);
      await builderGrantV2.write.deposit([DEPOSIT_AMOUNT]);
    });

    it("should deposit the correct amount", async function () {
      expect(await huntToken.read.balanceOf([builderGrantV2.address])).to.equal(DEPOSIT_AMOUNT);
    });

    it("should allow emergencyWithdraw by owner", async function () {
      const originalBalance = await huntToken.read.balanceOf([owner.account.address]);
      await builderGrantV2.write.emergencyWithdraw();
      expect(await huntToken.read.balanceOf([builderGrantV2.address])).to.equal(0n);
      expect(await huntToken.read.balanceOf([owner.account.address])).to.equal(originalBalance + DEPOSIT_AMOUNT);
    });

    it("should not allow emergencyWithdraw by non-owner", async function () {
      await expect(builderGrantV2.write.emergencyWithdraw([], { account: alice.account })).to.be.rejectedWith(
        "OwnableUnauthorizedAccount"
      );
    });

    it("should revert if emergencyWithdraw is called but balance is already 0", async function () {
      await builderGrantV2.write.emergencyWithdraw(); // first time OK
      await expect(builderGrantV2.write.emergencyWithdraw()).to.be.rejectedWith("NothingToWithdraw");
    });

    it("should emit Deposit event on deposit", async function () {
      await huntToken.write.approve([builderGrantV2.address, DEPOSIT_AMOUNT]);
      await expect(builderGrantV2.write.deposit([DEPOSIT_AMOUNT]))
        .to.emit(builderGrantV2, "Deposit")
        .withArgs(getAddress(owner.account.address), DEPOSIT_AMOUNT);
    });

    it("should emit EmergencyWithdraw event on emergency withdraw", async function () {
      await expect(builderGrantV2.write.emergencyWithdraw())
        .to.emit(builderGrantV2, "EmergencyWithdraw")
        .withArgs(getAddress(owner.account.address), DEPOSIT_AMOUNT);
    });
  });

  describe("Seasons and Claims", function () {
    const DEPOSIT_AMOUNT = parseEther("1000");

    beforeEach(async function () {
      // Approve & deposit HUNT so we can set seasons
      await huntToken.write.approve([builderGrantV2.address, DEPOSIT_AMOUNT]);
      await builderGrantV2.write.deposit([DEPOSIT_AMOUNT]);
    });

    it("should create a new season and set rankers", async function () {
      const fids = [1001n, 1002n];
      const wallets = [getAddress(alice.account.address), getAddress(bob.account.address)];
      const rewards = [3n, 2n];

      // setSeasonData(seasonId=0, fids, wallets, rewards)
      await expect(builderGrantV2.write.setSeasonData([0n, fids, wallets, rewards]))
        .to.emit(builderGrantV2, "SetSeasonData")
        .withArgs(0n, 2n); // seasonId=0, rankersCount=2

      const seasonCount = await builderGrantV2.read.currentSeason();
      expect(seasonCount).to.equal(1n);

      // verify getSeason(0)
      const season0 = await builderGrantV2.read.getSeason([0n]);
      expect(season0.totalClaimed).to.equal(0n);
      expect(season0.rankers.length).to.equal(2);

      expect(season0.rankers[0].fid).to.equal(1001n);
      expect(season0.rankers[0].wallet).to.equal(getAddress(alice.account.address));
      expect(season0.rankers[0].totalReward).to.equal(3n);
      expect(season0.rankers[0].isClaimed).to.equal(false);

      expect(season0.rankers[1].fid).to.equal(1002n);
      expect(season0.rankers[1].wallet).to.equal(getAddress(bob.account.address));
      expect(season0.rankers[1].totalReward).to.equal(2n);
      expect(season0.rankers[1].isClaimed).to.equal(false);
    });

    it("should revert if array lengths do not match", async function () {
      await expect(
        builderGrantV2.write.setSeasonData([
          0n,
          [1001n, 1002n],
          [getAddress(alice.account.address)], // mismatch
          [3n, 2n]
        ])
      ).to.be.rejectedWith("InvalidRankersParams");
    });

    it("should revert if total reward needed > contract's balance * (1 Mini Building = 100 HUNT)", async function () {
      // totalReward=20 => 20*100HUNT = 2000, but we only have 1000 deposited
      await expect(
        builderGrantV2.write.setSeasonData([0n, [1001n], [getAddress(alice.account.address)], [20n]])
      ).to.be.rejectedWith("NotEnoughGrantBalance");
    });

    describe("Updating a Season", function () {
      beforeEach(async function () {
        // Create a season #0
        await builderGrantV2.write.setSeasonData([
          0n,
          [1001n, 1002n],
          [getAddress(alice.account.address), getAddress(bob.account.address)],
          [3n, 2n]
        ]);
      });

      it("should allow overwriting season #0 if no claims yet", async function () {
        // Overwrite with new data
        await builderGrantV2.write.setSeasonData([
          0n,
          [2001n, 2002n],
          [getAddress(bob.account.address), getAddress(carol.account.address)],
          [5n, 1n]
        ]);

        const season0 = await builderGrantV2.read.getSeason([0n]);
        expect(season0.rankers.length).to.equal(2);
        expect(season0.rankers[0].fid).to.equal(2001n);
        expect(season0.rankers[1].fid).to.equal(2002n);
      });

      it("should revert if trying to overwrite after someone has claimed", async function () {
        // Alice claims from the original data
        await builderGrantV2.write.claimReward([0n], { account: alice.account });
        await expect(
          builderGrantV2.write.setSeasonData([0n, [2001n], [getAddress(carol.account.address)], [10n]])
        ).to.be.rejectedWith("SeasonDataIsNotUpdateable");
      });
    });

    describe("Claiming Rewards", function () {
      beforeEach(async function () {
        // Season #0: alice => 3 mini buildings, bob => 2 mini buildings
        await builderGrantV2.write.setSeasonData([
          0n,
          [1001n, 1002n],
          [getAddress(alice.account.address), getAddress(bob.account.address)],
          [3n, 2n]
        ]);
      });

      it("should allow a ranker to claim exactly once", async function () {
        // Check initial mini building balance is 0
        expect(await miniBuildingNFT.read.balanceOf([alice.account.address, 0n])).to.equal(0n);

        await expect(builderGrantV2.write.claimReward([0n], { account: alice.account }))
          .to.emit(builderGrantV2, "ClaimReward")
          .withArgs(getAddress(alice.account.address), 0n, 0n, 3n);

        // Now alice should have 3 mini buildings
        expect(await miniBuildingNFT.read.balanceOf([alice.account.address, 0n])).to.equal(3n);

        // Further claim should fail
        await expect(builderGrantV2.write.claimReward([0n], { account: alice.account })).to.be.rejectedWith(
          "AlreadyClaimed"
        );
      });

      it("should revert if a non-ranker tries to claim", async function () {
        await expect(builderGrantV2.write.claimReward([0n], { account: carol.account })).to.be.rejectedWith(
          "NotARanker"
        );
      });

      it("should update totalClaimed properly", async function () {
        const seasonBefore = await builderGrantV2.read.getSeason([0n]);
        expect(seasonBefore.totalClaimed).to.equal(0n);

        // Bob claims
        await builderGrantV2.write.claimReward([0n], { account: bob.account });

        const seasonAfter = await builderGrantV2.read.getSeason([0n]);
        expect(seasonAfter.totalClaimed).to.equal(2n);
      });
    });
  });
});
