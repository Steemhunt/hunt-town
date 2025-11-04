import assert from "node:assert/strict";
import { describe, it, beforeEach } from "node:test";
import { network } from "hardhat";
import { getAddress, getContract, erc20Abi } from "viem";

// Constants for testing
const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";
const BOND_ADDRESS = "0xc5a076cad94176c2996B32d8466Be1cE757FAa27";
const BOND_PERIPHERY_ADDRESS = "0x492C412369Db76C9cdD9939e6C521579301473a3";
const HUNT_TOKEN = "0x37f0c2915CeCC7e977183B8543Fc0864d03E064C"; // HUNT token address
const TEST_TOKEN = "0xDF2B673Ec06d210C8A8Be89441F8de60B5C679c9"; // SIGNET
const INITIAL_HUNT_BALANCE = 10_000n * 10n ** 18n; // 10,000 HUNT tokens for testing
const VOTE_EXPIRATION_DAYS = 30n;

describe("Mintpad", async function () {
  const connection = await network.connect("baseFork");
  const { viem, networkHelpers } = connection;
  const { impersonateAccount, stopImpersonatingAccount } = networkHelpers;

  async function estimateTokenAmount(token: `0x${string}`, huntAmount: bigint) {
    const publicClient = await viem.getPublicClient();

    const bondPeriphery = getContract({
      address: BOND_PERIPHERY_ADDRESS,
      abi: [
        {
          name: "getTokensForReserve",
          type: "function",
          stateMutability: "view",
          inputs: [
            { name: "tokenAddress", type: "address" },
            { name: "reserveAmount", type: "uint256" },
            { name: "useCeilDivision", type: "bool" }
          ],
          outputs: [
            { name: "tokensToMint", type: "uint256" },
            { name: "reserveAddress", type: "address" }
          ]
        }
      ] as const,
      client: publicClient
    });
    const [tokensToMint] = await bondPeriphery.read.getTokensForReserve([token, huntAmount, true]);
    return tokensToMint;
  }

  async function deployMintpadFixture() {
    const [owner, alice, bob] = await viem.getWalletClients();

    const mintpad = await viem.deployContract("Mintpad", [BOND_ADDRESS]);

    // Impersonate an address with enough HUNT balance and transfer HUNT to Mintpad contract
    const impersonatedAddress = "0xCB3f3e0E992435390e686D7b638FCb8baBa6c5c7";
    await impersonateAccount(impersonatedAddress);
    const huntToken = getContract({
      address: HUNT_TOKEN,
      abi: erc20Abi,
      client: owner
    });
    await huntToken.write.transfer([mintpad.address, INITIAL_HUNT_BALANCE], {
      account: impersonatedAddress
    });
    await stopImpersonatingAccount(impersonatedAddress);

    const testToken = getContract({
      address: TEST_TOKEN,
      abi: erc20Abi,
      client: owner
    });

    return { mintpad, owner, alice, bob, huntToken, testToken };
  }

  let mintpad: any;
  let owner: any;
  let alice: any;
  let bob: any;
  let huntToken: any;
  let testToken: any;

  beforeEach(async function () {
    ({ mintpad, owner, alice, bob, huntToken, testToken } = await networkHelpers.loadFixture(deployMintpadFixture));
  });

  describe("Contract initialization", function () {
    it("should deploy with correct bond address", async function () {
      const bondAddress = await mintpad.read.BOND();
      assert.equal(bondAddress.toLowerCase(), BOND_ADDRESS.toLowerCase());
    });

    it("should initialize dayCounter to zero", async function () {
      const dayCounter = await mintpad.read.dayCounter();
      assert.equal(dayCounter, 0n);
    });

    it("should have received HUNT tokens", async function () {
      const contractBalance = await huntToken.read.balanceOf([mintpad.address]);
      assert.equal(contractBalance, INITIAL_HUNT_BALANCE);
    });

    it("should initialize isRollOverInProgress to false", async function () {
      const isRollOverInProgress = await mintpad.read.isRollOverInProgress();
      assert.equal(isRollOverInProgress, false);
    });

    it("should set VOTE_EXPIRATION_DAYS to 30", async function () {
      const expirationDays = await mintpad.read.VOTE_EXPIRATION_DAYS();
      assert.equal(expirationDays, VOTE_EXPIRATION_DAYS);
    });
  }); // Contract initialization

  describe("Admin functions", function () {
    describe("startRollOver", function () {
      it("should allow owner to start roll-over", async function () {
        await mintpad.write.startRollOver({ account: owner.account });

        const isRollOverInProgress = await mintpad.read.isRollOverInProgress();
        const dayCounter = await mintpad.read.dayCounter();

        assert.equal(isRollOverInProgress, true);
        assert.equal(dayCounter, 1n);
      });

      it("should revert when non-owner tries to start roll-over", async function () {
        await assert.rejects(mintpad.write.startRollOver({ account: alice.account }), /OwnableUnauthorizedAccount/);
      });

      it("should increment dayCounter each time", async function () {
        await mintpad.write.startRollOver({ account: owner.account });
        let dayCounter = await mintpad.read.dayCounter();
        assert.equal(dayCounter, 1n);

        await mintpad.write.endRollOver([100], { account: owner.account });
        await mintpad.write.startRollOver({ account: owner.account });
        dayCounter = await mintpad.read.dayCounter();
        assert.equal(dayCounter, 2n);
      });
    }); // startRollOver

    describe("endRollOver", function () {
      beforeEach(async function () {
        await mintpad.write.startRollOver({ account: owner.account });
      });

      it("should allow owner to end roll-over", async function () {
        const totalHuntReward = 1000; // 1000 HUNT in ether units

        await mintpad.write.endRollOver([totalHuntReward], { account: owner.account });

        const isRollOverInProgress = await mintpad.read.isRollOverInProgress();
        assert.equal(isRollOverInProgress, false);

        const dayCounter = await mintpad.read.dayCounter();
        const stats = await mintpad.read.dailyStats([dayCounter]);
        assert.equal(stats[2], totalHuntReward); // totalHuntReward field
      });

      it("should revert when non-owner tries to end roll-over", async function () {
        await assert.rejects(
          mintpad.write.endRollOver([1000], { account: alice.account }),
          /OwnableUnauthorizedAccount/
        );
      });

      it("should revert when not in roll-over", async function () {
        await mintpad.write.endRollOver([1000], { account: owner.account });

        await assert.rejects(
          mintpad.write.endRollOver([1000], { account: owner.account }),
          /Mintpad__RollOverNotInProgress/
        );
      });
    }); // endRollOver

    describe("addVotingPoints", function () {
      beforeEach(async function () {
        await mintpad.write.startRollOver({ account: owner.account });
      });

      it("should allow owner to add voting points", async function () {
        const users = [alice.account.address, bob.account.address];
        const points = [100, 200];

        await mintpad.write.addVotingPoints([users, points], { account: owner.account });

        const dayCounter = await mintpad.read.dayCounter();
        const alicePoints = await mintpad.read.dailyUserVotingPoint([dayCounter, alice.account.address]);
        const bobPoints = await mintpad.read.dailyUserVotingPoint([dayCounter, bob.account.address]);

        assert.equal(alicePoints, 100);
        assert.equal(bobPoints, 200);

        const stats = await mintpad.read.dailyStats([dayCounter]);
        assert.equal(stats[0], 300); // totalVotingPointGiven
      });

      it("should add to existing voting points", async function () {
        const users = [alice.account.address, bob.account.address];
        const points1 = [100, 200];
        const points2 = [50, 75];

        await mintpad.write.addVotingPoints([users, points1], { account: owner.account });
        await mintpad.write.addVotingPoints([users, points2], { account: owner.account });

        const dayCounter = await mintpad.read.dayCounter();
        const alicePoints = await mintpad.read.dailyUserVotingPoint([dayCounter, alice.account.address]);
        const bobPoints = await mintpad.read.dailyUserVotingPoint([dayCounter, bob.account.address]);

        assert.equal(alicePoints, 150); // 100 + 50
        assert.equal(bobPoints, 275); // 200 + 75

        const stats = await mintpad.read.dailyStats([dayCounter]);
        assert.equal(stats[0], 425); // totalVotingPointGiven: 300 + 125
      });

      it("should emit VotingPointsAdded event", async function () {
        const users = [alice.account.address];
        const points = [100];

        const dayCounter = await mintpad.read.dayCounter();

        await viem.assertions.emitWithArgs(
          mintpad.write.addVotingPoints([users, points], { account: owner.account }),
          mintpad,
          "VotingPointsAdded",
          [dayCounter, 1n, 100n]
        );
      });

      it("should revert when non-owner tries to add voting points", async function () {
        await assert.rejects(
          mintpad.write.addVotingPoints([[alice.account.address], [100]], { account: alice.account }),
          /OwnableUnauthorizedAccount/
        );
      });

      it("should revert when not in roll-over", async function () {
        await mintpad.write.endRollOver([1000], { account: owner.account });

        await assert.rejects(
          mintpad.write.addVotingPoints([[alice.account.address], [100]], { account: owner.account }),
          /Mintpad__RollOverNotInProgress/
        );
      });

      it("should revert when array lengths mismatch", async function () {
        await assert.rejects(
          mintpad.write.addVotingPoints([[alice.account.address, bob.account.address], [100]], {
            account: owner.account
          }),
          /Mintpad__InvalidParams\("length mismatch"\)/
        );
      });
    }); // addVotingPoints

    describe("setVotingPoint", function () {
      beforeEach(async function () {
        await mintpad.write.startRollOver({ account: owner.account });
      });

      it("should allow owner to set voting point for a user", async function () {
        await mintpad.write.setVotingPoint([alice.account.address, 150], { account: owner.account });

        const dayCounter = await mintpad.read.dayCounter();
        const alicePoints = await mintpad.read.dailyUserVotingPoint([dayCounter, alice.account.address]);

        assert.equal(alicePoints, 150);
      });

      it("should emit VotingPointsAdded event with correct delta when setting from zero", async function () {
        const dayCounter = await mintpad.read.dayCounter();

        await viem.assertions.emitWithArgs(
          mintpad.write.setVotingPoint([alice.account.address, 100], { account: owner.account }),
          mintpad,
          "VotingPointsAdded",
          [dayCounter, 1n, 100n]
        );
      });

      it("should emit VotingPointsAdded event with positive delta when increasing", async function () {
        await mintpad.write.setVotingPoint([alice.account.address, 100], { account: owner.account });

        const dayCounter = await mintpad.read.dayCounter();

        await viem.assertions.emitWithArgs(
          mintpad.write.setVotingPoint([alice.account.address, 150], { account: owner.account }),
          mintpad,
          "VotingPointsAdded",
          [dayCounter, 1n, 50n] // 150 - 100
        );
      });

      it("should emit VotingPointsAdded event with negative delta when decreasing", async function () {
        await mintpad.write.setVotingPoint([alice.account.address, 100], { account: owner.account });

        const dayCounter = await mintpad.read.dayCounter();

        await viem.assertions.emitWithArgs(
          mintpad.write.setVotingPoint([alice.account.address, 60], { account: owner.account }),
          mintpad,
          "VotingPointsAdded",
          [dayCounter, 1n, -40n] // 60 - 100
        );
      });

      it("should replace existing voting point (not add)", async function () {
        await mintpad.write.addVotingPoints([[alice.account.address], [100]], { account: owner.account });
        await mintpad.write.setVotingPoint([alice.account.address, 50], { account: owner.account });

        const dayCounter = await mintpad.read.dayCounter();
        const alicePoints = await mintpad.read.dailyUserVotingPoint([dayCounter, alice.account.address]);

        assert.equal(alicePoints, 50); // Should be 50, not 150
      });

      it("should revert when non-owner tries to set voting point", async function () {
        await assert.rejects(
          mintpad.write.setVotingPoint([alice.account.address, 100], { account: alice.account }),
          /OwnableUnauthorizedAccount/
        );
      });

      it("should revert when not in roll-over", async function () {
        await mintpad.write.endRollOver([1000], { account: owner.account });

        await assert.rejects(
          mintpad.write.setVotingPoint([alice.account.address, 100], { account: owner.account }),
          /Mintpad__RollOverNotInProgress/
        );
      });
    }); // setVotingPoint

    describe("refundHUNT", function () {
      it("should allow owner to refund HUNT tokens", async function () {
        const initialContractBalance = await huntToken.read.balanceOf([mintpad.address]);
        const initialOwnerBalance = await huntToken.read.balanceOf([owner.account.address]);
        const refundAmount = 10_000n * 10n ** 18n;

        await mintpad.write.refundHUNT([refundAmount], { account: owner.account });

        const finalContractBalance = await huntToken.read.balanceOf([mintpad.address]);
        const finalOwnerBalance = await huntToken.read.balanceOf([owner.account.address]);

        assert.equal(finalContractBalance, initialContractBalance - refundAmount);
        assert.equal(finalOwnerBalance, initialOwnerBalance + refundAmount);
      });

      it("should revert when non-owner tries to refund HUNT", async function () {
        await assert.rejects(
          mintpad.write.refundHUNT([1000n * 10n ** 18n], { account: alice.account }),
          /OwnableUnauthorizedAccount/
        );
      });

      it("should revert with zero amount", async function () {
        await assert.rejects(
          mintpad.write.refundHUNT([0n], { account: owner.account }),
          /Mintpad__InvalidParams\("amount cannot be zero"\)/
        );
      });

      it("should revert with insufficient balance", async function () {
        const excessiveAmount = INITIAL_HUNT_BALANCE + 1n;

        await assert.rejects(
          mintpad.write.refundHUNT([excessiveAmount], { account: owner.account }),
          /Mintpad__InvalidParams\("insufficient balance"\)/
        );
      });
    }); // refundHUNT

    describe("setDayCounter", function () {
      it("should allow owner to set day counter", async function () {
        await mintpad.write.setDayCounter([10], { account: owner.account });

        const dayCounter = await mintpad.read.dayCounter();
        assert.equal(dayCounter, 10n);
      });

      it("should revert when non-owner tries to set day counter", async function () {
        await assert.rejects(
          mintpad.write.setDayCounter([10], { account: alice.account }),
          /OwnableUnauthorizedAccount/
        );
      });
    }); // setDayCounter
  }); // Admin functions

  describe("Vote function", function () {
    // Helper to set up a day with voting points
    async function setupDay(alicePoints = 1000, bobPoints = 500) {
      await mintpad.write.startRollOver({ account: owner.account });
      const users = [alice.account.address, bob.account.address];
      const points = [alicePoints, bobPoints];
      await mintpad.write.addVotingPoints([users, points], { account: owner.account });
      await mintpad.write.endRollOver([10000], { account: owner.account }); // 10000 HUNT reward
    }

    describe("Parameter validation", function () {
      beforeEach(async function () {
        await setupDay();
      });

      it("should revert with invalid token address (zero address)", async function () {
        await assert.rejects(
          mintpad.write.vote([ZERO_ADDRESS, 100], { account: alice.account }),
          /Mintpad__InvalidParams\("zero address"\)/
        );
      });

      it("should revert with non-existent token", async function () {
        const nonExistentToken = "0x0000000000000000000000000000000000000001";
        await assert.rejects(
          mintpad.write.vote([nonExistentToken, 100], { account: alice.account }),
          /Mintpad__InvalidParams\("not child token"\)/
        );
      });

      it("should revert with zero voteAmount", async function () {
        await assert.rejects(
          mintpad.write.vote([TEST_TOKEN, 0], { account: alice.account }),
          /Mintpad__InvalidParams\("voteAmount"\)/
        );
      });

      it("should revert when user has insufficient voting points", async function () {
        await assert.rejects(
          mintpad.write.vote([TEST_TOKEN, 1001], { account: alice.account }), // Alice has 1000 points
          /Mintpad__InsufficientVotingPoints/
        );
      });

      it("should revert when voting during roll-over", async function () {
        await mintpad.write.startRollOver({ account: owner.account });

        await assert.rejects(
          mintpad.write.vote([TEST_TOKEN, 100], { account: alice.account }),
          /Mintpad__RollOverInProgress/
        );
      });
    }); // Parameter validation

    describe("Success cases", function () {
      beforeEach(async function () {
        await setupDay();
      });
      it("should allow user to vote with available points", async function () {
        const voteAmount = 500;
        const dayCounter = await mintpad.read.dayCounter();

        await mintpad.write.vote([TEST_TOKEN, voteAmount], { account: alice.account });

        const userRemainingPoints = await mintpad.read.dailyUserVotingPoint([dayCounter, alice.account.address]);
        const userTokenVotes = await mintpad.read.dailyUserTokenVotes([dayCounter, alice.account.address, TEST_TOKEN]);
        const stats = await mintpad.read.dailyStats([dayCounter]);

        assert.equal(userRemainingPoints, 1000 - voteAmount); // Started with 1000
        assert.equal(userTokenVotes, voteAmount);
        assert.equal(stats[1], voteAmount); // totalVotingPointSpent
      });

      it("should allow multiple votes from same user", async function () {
        const voteAmount1 = 300;
        const voteAmount2 = 400;
        const dayCounter = await mintpad.read.dayCounter();

        await mintpad.write.vote([TEST_TOKEN, voteAmount1], { account: alice.account });
        await mintpad.write.vote([TEST_TOKEN, voteAmount2], { account: alice.account });

        const userRemainingPoints = await mintpad.read.dailyUserVotingPoint([dayCounter, alice.account.address]);
        const userTokenVotes = await mintpad.read.dailyUserTokenVotes([dayCounter, alice.account.address, TEST_TOKEN]);

        assert.equal(userRemainingPoints, 1000 - voteAmount1 - voteAmount2); // Started with 1000
        assert.equal(userTokenVotes, voteAmount1 + voteAmount2);
      });

      it("should emit Voted event on successful vote", async function () {
        const voteAmount = 500;
        const dayCounter = await mintpad.read.dayCounter();

        await viem.assertions.emitWithArgs(
          mintpad.write.vote([TEST_TOKEN, voteAmount], { account: alice.account }),
          mintpad,
          "Voted",
          [dayCounter, getAddress(alice.account.address), getAddress(TEST_TOKEN), voteAmount]
        );
      });

      it("should track votes from multiple users", async function () {
        const aliceVote = 500;
        const bobVote = 300;
        const dayCounter = await mintpad.read.dayCounter();

        await mintpad.write.vote([TEST_TOKEN, aliceVote], { account: alice.account });
        await mintpad.write.vote([TEST_TOKEN, bobVote], { account: bob.account });

        const aliceTokenVotes = await mintpad.read.dailyUserTokenVotes([dayCounter, alice.account.address, TEST_TOKEN]);
        const bobTokenVotes = await mintpad.read.dailyUserTokenVotes([dayCounter, bob.account.address, TEST_TOKEN]);
        const stats = await mintpad.read.dailyStats([dayCounter]);

        assert.equal(aliceTokenVotes, aliceVote);
        assert.equal(bobTokenVotes, bobVote);
        assert.equal(stats[1], aliceVote + bobVote); // totalVotingPointSpent
      });

      it("should increment votingCount for each vote", async function () {
        const dayCounter = await mintpad.read.dayCounter();

        // Check initial votingCount is 0
        let stats = await mintpad.read.dailyStats([dayCounter]);
        assert.equal(stats[4], 0); // votingCount

        // First vote
        await mintpad.write.vote([TEST_TOKEN, 100], { account: alice.account });
        stats = await mintpad.read.dailyStats([dayCounter]);
        assert.equal(stats[4], 1); // votingCount should be 1

        // Second vote from same user
        await mintpad.write.vote([TEST_TOKEN, 200], { account: alice.account });
        stats = await mintpad.read.dailyStats([dayCounter]);
        assert.equal(stats[4], 2); // votingCount should be 2

        // Third vote from different user
        await mintpad.write.vote([TEST_TOKEN, 300], { account: bob.account });
        stats = await mintpad.read.dailyStats([dayCounter]);
        assert.equal(stats[4], 3); // votingCount should be 3
      });

      it("should track votingCount independently per day", async function () {
        // Day 1: 2 votes
        let dayCounter = await mintpad.read.dayCounter();
        await mintpad.write.vote([TEST_TOKEN, 100], { account: alice.account });
        await mintpad.write.vote([TEST_TOKEN, 200], { account: bob.account });

        let day1Stats = await mintpad.read.dailyStats([dayCounter]);
        assert.equal(day1Stats[4], 2); // votingCount for day 1

        // Start Day 2
        await mintpad.write.startRollOver({ account: owner.account });
        await mintpad.write.addVotingPoints(
          [
            [alice.account.address, bob.account.address],
            [1000, 500]
          ],
          {
            account: owner.account
          }
        );
        await mintpad.write.endRollOver([1000], { account: owner.account });

        // Day 2: 1 vote
        dayCounter = await mintpad.read.dayCounter();
        await mintpad.write.vote([TEST_TOKEN, 100], { account: alice.account });

        let day2Stats = await mintpad.read.dailyStats([dayCounter]);
        assert.equal(day2Stats[4], 1); // votingCount for day 2 should be 1

        // Day 1 stats should remain unchanged
        day1Stats = await mintpad.read.dailyStats([dayCounter - 1n]);
        assert.equal(day1Stats[4], 2); // votingCount for day 1 still 2
      });
    }); // Success cases
  }); // Vote function

  describe("Claim function", function () {
    const DAY_1_HUNT_REWARD = 1000;
    const DAY_2_HUNT_REWARD = 2000;
    const ALICE_VOTINGS = [800, 600];
    const BOB_VOTINGS = [0, 400];
    const DAILY_ALICE_REWARDS_EXPECTED = [1000n * 10n ** 18n, 1200n * 10n ** 18n];
    const DAILY_BOB_REWARDS_EXPECTED = [0n, 800n * 10n ** 18n];

    // Helper to set up multiple days with voting
    async function setupMultipleDays() {
      // Day 1
      await mintpad.write.startRollOver({ account: owner.account });
      await mintpad.write.addVotingPoints(
        [
          [alice.account.address, bob.account.address],
          [1000, 500]
        ],
        {
          account: owner.account
        }
      );
      await mintpad.write.endRollOver([DAY_1_HUNT_REWARD], { account: owner.account });

      // Alice votes 800 points on Day 1
      await mintpad.write.vote([TEST_TOKEN, ALICE_VOTINGS[0]], { account: alice.account });

      // Day 2
      await mintpad.write.startRollOver({ account: owner.account });
      await mintpad.write.addVotingPoints(
        [
          [alice.account.address, bob.account.address],
          [1000, 500]
        ],
        {
          account: owner.account
        }
      );
      await mintpad.write.endRollOver([DAY_2_HUNT_REWARD], { account: owner.account });

      // Alice votes 600 points, Bob votes 400 points on Day 2
      await mintpad.write.vote([TEST_TOKEN, ALICE_VOTINGS[1]], { account: alice.account });
      await mintpad.write.vote([TEST_TOKEN, BOB_VOTINGS[1]], { account: bob.account });

      // Day 3 (current day, no claims yet)
      await mintpad.write.startRollOver({ account: owner.account });
      await mintpad.write.addVotingPoints(
        [
          [alice.account.address, bob.account.address],
          [1000, 500]
        ],
        {
          account: owner.account
        }
      );
      await mintpad.write.endRollOver([1234], { account: owner.account });
    }

    describe("Parameter validation", function () {
      beforeEach(async function () {
        await setupMultipleDays();
      });

      it("should revert with invalid token address (zero address)", async function () {
        await assert.rejects(
          mintpad.write.claim([ZERO_ADDRESS, 100n * 10n ** 18n, 0], { account: alice.account }),
          /Mintpad__InvalidParams\("zero address"\)/
        );
      });

      it("should revert with non-existent token", async function () {
        const nonExistentToken = "0x0000000000000000000000000000000000000001";
        await assert.rejects(
          mintpad.write.claim([nonExistentToken, 100n * 10n ** 18n, 0], { account: alice.account }),
          /Mintpad__InvalidParams\("not child token"\)/
        );
      });

      it("should revert with zero tokensToMint", async function () {
        await assert.rejects(
          mintpad.write.claim([TEST_TOKEN, 0n, 0], { account: alice.account }),
          /Mintpad__InvalidParams\("tokensToMint must be greater than 0"\)/
        );
      });

      it("should revert when claiming during roll-over", async function () {
        await mintpad.write.startRollOver({ account: owner.account });

        await assert.rejects(
          mintpad.write.claim([TEST_TOKEN, 100n * 10n ** 18n, 0], { account: alice.account }),
          /Mintpad__RollOverInProgress/
        );
      });

      it("should revert when user has nothing to claim", async function () {
        // Bob never voted for TEST_TOKEN on Day 1
        await mintpad.write.setDayCounter([1], { account: owner.account });

        await assert.rejects(
          mintpad.write.claim([TEST_TOKEN, 100n * 10n ** 18n, 0], { account: bob.account }),
          /Mintpad__NothingToClaim/
        );
      });
    }); // Parameter validation

    describe("Success cases", function () {
      beforeEach(async function () {
        await setupMultipleDays();
      });

      it("should allow alice to claim rewards", async function () {
        // Alice can claim rewards from Day 1 and Day 2 = 2200 HUNT
        const [claimableHunt, endDay] = await mintpad.read.getClaimableHunt([alice.account.address, TEST_TOKEN]);

        assert.equal(claimableHunt, DAILY_ALICE_REWARDS_EXPECTED[0] + DAILY_ALICE_REWARDS_EXPECTED[1]);
        assert.equal(endDay, 2n); // Can claim up to Day 2 (Day 3 is current)

        const initialAliceBalance = await testToken.read.balanceOf([alice.account.address]);

        // Calculate token amount dynamically based on claimable HUNT
        const tokenAmount = await estimateTokenAmount(TEST_TOKEN, claimableHunt);
        await mintpad.write.claim([TEST_TOKEN, tokenAmount, 0], { account: alice.account });

        const finalAliceBalance = await testToken.read.balanceOf([alice.account.address]);
        assert.equal(finalAliceBalance, initialAliceBalance + tokenAmount);

        // Check that lastClaimDay was updated
        const lastClaimDay = await mintpad.read.userTokenLastClaimDay([alice.account.address, TEST_TOKEN]);
        assert.equal(lastClaimDay, 2n);
      });

      it("should allow bob to claim rewards", async function () {
        // Bob can claim rewards from Day 2 = 800 HUNT
        const [claimableHunt, endDay] = await mintpad.read.getClaimableHunt([bob.account.address, TEST_TOKEN]);

        assert.equal(claimableHunt, DAILY_BOB_REWARDS_EXPECTED[1]);
        assert.equal(endDay, 2n); // Can claim up to Day 2 (Day 3 is current)

        const initialBobBalance = await testToken.read.balanceOf([bob.account.address]);

        // Calculate token amount dynamically based on claimable HUNT
        const tokenAmount = await estimateTokenAmount(TEST_TOKEN, claimableHunt);
        await mintpad.write.claim([TEST_TOKEN, tokenAmount, 0], { account: bob.account });

        const finalBobBalance = await testToken.read.balanceOf([bob.account.address]);
        assert.equal(finalBobBalance, initialBobBalance + tokenAmount);

        // Check that lastClaimDay was updated
        const lastClaimDay = await mintpad.read.userTokenLastClaimDay([bob.account.address, TEST_TOKEN]);
        assert.equal(lastClaimDay, 2n);
      });

      it("should emit Claimed event", async function () {
        // Calculate token amount dynamically for Alice's claimable HUNT
        const [claimableHunt] = await mintpad.read.getClaimableHunt([alice.account.address, TEST_TOKEN]);
        const tokenAmount = await estimateTokenAmount(TEST_TOKEN, claimableHunt);

        const tx = mintpad.write.claim([TEST_TOKEN, tokenAmount, 0], { account: alice.account });

        // Just check that it emits the event with correct user and token
        await viem.assertions.emit(tx, mintpad, "Claimed");
      });

      it("should handle donations correctly", async function () {
        const donationBp = 1000n; // 10% donation

        const bondContract = getContract({
          address: BOND_ADDRESS,
          abi: [
            {
              name: "tokenBond",
              type: "function",
              stateMutability: "view",
              inputs: [{ name: "token", type: "address" }],
              outputs: [
                { name: "creator", type: "address" },
                { name: "mintRoyalty", type: "uint16" },
                { name: "burnRoyalty", type: "uint16" },
                { name: "createdAt", type: "uint40" },
                { name: "reserveToken", type: "address" },
                { name: "reserveBalance", type: "uint256" }
              ]
            }
          ],
          client: owner
        }) as any;

        const [tokenCreator] = await bondContract.read.tokenBond([TEST_TOKEN]);

        const initialAliceBalance = BigInt(await testToken.read.balanceOf([alice.account.address]));
        const initialCreatorBalance = BigInt(await testToken.read.balanceOf([tokenCreator]));

        // Calculate token amount dynamically for Alice's claimable HUNT
        const [claimableHunt] = await mintpad.read.getClaimableHunt([alice.account.address, TEST_TOKEN]);
        const tokenAmount = await estimateTokenAmount(TEST_TOKEN, claimableHunt);

        await mintpad.write.claim([TEST_TOKEN, tokenAmount, Number(donationBp)], {
          account: alice.account
        });

        const finalAliceBalance = BigInt(await testToken.read.balanceOf([alice.account.address]));
        const finalCreatorBalance = BigInt(await testToken.read.balanceOf([tokenCreator]));

        // Check that donation was sent to creator
        assert.equal(finalCreatorBalance, initialCreatorBalance + (tokenAmount * donationBp) / 10000n);
        assert.equal(finalAliceBalance, initialAliceBalance + tokenAmount - (tokenAmount * donationBp) / 10000n);
      });

      it("should prevent double claiming", async function () {
        // Calculate token amount dynamically for Alice's claimable HUNT
        const [claimableHunt] = await mintpad.read.getClaimableHunt([alice.account.address, TEST_TOKEN]);
        const tokenAmount = await estimateTokenAmount(TEST_TOKEN, claimableHunt);

        // First claim
        await mintpad.write.claim([TEST_TOKEN, tokenAmount, 0], { account: alice.account });

        // Second claim should fail (nothing to claim)
        await assert.rejects(
          mintpad.write.claim([TEST_TOKEN, tokenAmount, 0], { account: alice.account }),
          /Mintpad__NothingToClaim/
        );
      });

      it("should track totalHuntClaimed on current day", async function () {
        const currentDay = await mintpad.read.dayCounter();
        const publicClient = await viem.getPublicClient();

        // Check initial totalHuntClaimed
        let stats = await mintpad.read.dailyStats([currentDay]);
        const initialClaimed = stats[3]; // totalHuntClaimed

        // Calculate token amount dynamically for Alice's claimable HUNT
        const [aliceClaimableHunt] = await mintpad.read.getClaimableHunt([alice.account.address, TEST_TOKEN]);
        const aliceTokenAmount = await estimateTokenAmount(TEST_TOKEN, aliceClaimableHunt);

        // Alice claims (2200 HUNT worth of rewards)
        const aliceTxHash = await mintpad.write.claim([TEST_TOKEN, aliceTokenAmount, 0], {
          account: alice.account
        });
        const aliceReceipt = await publicClient.waitForTransactionReceipt({ hash: aliceTxHash });
        const aliceClaimedEvents = await mintpad.getEvents.Claimed(
          {},
          { fromBlock: aliceReceipt.blockNumber, toBlock: aliceReceipt.blockNumber }
        );
        const aliceActualHuntSpent = aliceClaimedEvents[0].args.actualHuntSpent!;

        // Check totalHuntClaimed is updated on current day with exact value
        stats = await mintpad.read.dailyStats([currentDay]);
        const afterAliceClaimed = stats[3]; // totalHuntClaimed
        assert.equal(
          afterAliceClaimed,
          initialClaimed + aliceActualHuntSpent,
          "totalHuntClaimed should equal initial + Alice's actualHuntSpent"
        );

        // Check if Bob has anything to claim
        const [bobClaimable] = await mintpad.read.getClaimableHunt([bob.account.address, TEST_TOKEN]);
        if (bobClaimable > 0n) {
          // Calculate token amount dynamically for Bob's claimable HUNT
          const bobTokenAmount = await estimateTokenAmount(TEST_TOKEN, bobClaimable);

          // Bob claims (800 HUNT worth of rewards)
          const bobTxHash = await mintpad.write.claim([TEST_TOKEN, bobTokenAmount, 0], {
            account: bob.account
          });
          const bobReceipt = await publicClient.waitForTransactionReceipt({ hash: bobTxHash });
          const bobClaimedEvents = await mintpad.getEvents.Claimed(
            {},
            { fromBlock: bobReceipt.blockNumber, toBlock: bobReceipt.blockNumber }
          );
          const bobActualHuntSpent = bobClaimedEvents[0].args.actualHuntSpent!;

          // Check totalHuntClaimed is accumulated on current day with exact value
          stats = await mintpad.read.dailyStats([currentDay]);
          const afterBothClaimed = stats[3]; // totalHuntClaimed
          assert.equal(
            afterBothClaimed,
            initialClaimed + aliceActualHuntSpent + bobActualHuntSpent,
            "totalHuntClaimed should equal initial + both actualHuntSpent values"
          );
        }
      });

      it("should increment claimCount on current day", async function () {
        const currentDay = await mintpad.read.dayCounter();

        // Check initial claimCount
        let stats = await mintpad.read.dailyStats([currentDay]);
        const initialClaimCount = stats[5]; // claimCount

        // Calculate token amount dynamically for Alice's claimable HUNT
        const [aliceClaimableHunt] = await mintpad.read.getClaimableHunt([alice.account.address, TEST_TOKEN]);
        const aliceTokenAmount = await estimateTokenAmount(TEST_TOKEN, aliceClaimableHunt);

        // Alice claims
        await mintpad.write.claim([TEST_TOKEN, aliceTokenAmount, 0], { account: alice.account });

        // Check claimCount is incremented on current day
        stats = await mintpad.read.dailyStats([currentDay]);
        assert.equal(stats[5], initialClaimCount + 1); // claimCount should be incremented by 1

        // Check if Bob has anything to claim
        const [bobClaimable] = await mintpad.read.getClaimableHunt([bob.account.address, TEST_TOKEN]);
        if (bobClaimable > 0n) {
          // Calculate token amount dynamically for Bob's claimable HUNT
          const bobTokenAmount = await estimateTokenAmount(TEST_TOKEN, bobClaimable);

          // Bob claims
          await mintpad.write.claim([TEST_TOKEN, bobTokenAmount, 0], { account: bob.account });

          // Check claimCount is incremented again on current day
          stats = await mintpad.read.dailyStats([currentDay]);
          assert.equal(stats[5], initialClaimCount + 2); // claimCount should be incremented by 2
        }
      });

      it("should track claims independently per day", async function () {
        const currentDay = await mintpad.read.dayCounter();

        // Get initial claim count for day 3
        let day3Stats = await mintpad.read.dailyStats([currentDay]);
        const day3InitialClaimCount = day3Stats[5];

        // Calculate token amount dynamically for Alice's claimable HUNT
        const [aliceClaimableHunt] = await mintpad.read.getClaimableHunt([alice.account.address, TEST_TOKEN]);
        const aliceTokenAmount = await estimateTokenAmount(TEST_TOKEN, aliceClaimableHunt);

        // Alice claims on Day 3 (current day)
        await mintpad.write.claim([TEST_TOKEN, aliceTokenAmount, 0], { account: alice.account });

        day3Stats = await mintpad.read.dailyStats([currentDay]);
        assert.equal(day3Stats[5], day3InitialClaimCount + 1); // claimCount for day 3 should increment

        // Setup Day 4 with new votes
        await mintpad.write.startRollOver({ account: owner.account });
        await mintpad.write.addVotingPoints([[bob.account.address], [1000]], { account: owner.account });
        await mintpad.write.endRollOver([1500], { account: owner.account });

        // Bob votes on Day 4
        await mintpad.write.vote([TEST_TOKEN, 500], { account: bob.account });

        // Setup Day 5
        await mintpad.write.startRollOver({ account: owner.account });
        await mintpad.write.addVotingPoints([[bob.account.address], [1000]], { account: owner.account });
        await mintpad.write.endRollOver([1600], { account: owner.account });

        const day5 = await mintpad.read.dayCounter();

        // Bob claims on Day 5 (his votes from Day 4)
        const [bobClaimable] = await mintpad.read.getClaimableHunt([bob.account.address, TEST_TOKEN]);
        if (bobClaimable > 0n) {
          // Calculate token amount dynamically for Bob's claimable HUNT
          const bobTokenAmount = await estimateTokenAmount(TEST_TOKEN, bobClaimable);
          await mintpad.write.claim([TEST_TOKEN, bobTokenAmount, 0], { account: bob.account });

          // Day 5 should have 1 claim
          let day5Stats = await mintpad.read.dailyStats([day5]);
          assert.equal(day5Stats[5], 1); // claimCount for day 5 should be 1

          // Day 3 stats should remain unchanged
          day3Stats = await mintpad.read.dailyStats([currentDay]);
          assert.equal(day3Stats[5], day3InitialClaimCount + 1); // claimCount for day 3 unchanged
        }
      });
    }); // Success cases

    describe("View functions", function () {
      describe("getClaimableHunt", function () {
        it("should return 0 when no votes exist", async function () {
          const [claimableHunt] = await mintpad.read.getClaimableHunt([alice.account.address, TEST_TOKEN]);
          assert.equal(claimableHunt, 0n);
        });

        it("should calculate claimable HUNT correctly", async function () {
          await setupMultipleDays();

          const [claimableHunt, endDay] = await mintpad.read.getClaimableHunt([alice.account.address, TEST_TOKEN]);

          assert.equal(claimableHunt, DAILY_ALICE_REWARDS_EXPECTED[0] + DAILY_ALICE_REWARDS_EXPECTED[1]);
          assert.equal(endDay, 2n); // Can claim up to Day 2
        });

        it("should handle multiple users correctly", async function () {
          await setupMultipleDays();

          const [aliceClaimable] = await mintpad.read.getClaimableHunt([alice.account.address, TEST_TOKEN]);
          const [bobClaimable] = await mintpad.read.getClaimableHunt([bob.account.address, TEST_TOKEN]);

          assert.equal(aliceClaimable, DAILY_ALICE_REWARDS_EXPECTED[0] + DAILY_ALICE_REWARDS_EXPECTED[1]);
          assert.equal(bobClaimable, DAILY_BOB_REWARDS_EXPECTED[1]);
        });

        it("should return 0 after claim", async function () {
          await setupMultipleDays();

          // Calculate token amount dynamically for Alice's claimable HUNT
          const [claimableHunt] = await mintpad.read.getClaimableHunt([alice.account.address, TEST_TOKEN]);
          const tokenAmount = await estimateTokenAmount(TEST_TOKEN, claimableHunt);

          await mintpad.write.claim([TEST_TOKEN, tokenAmount, 0], { account: alice.account });

          const [newClaimableHunt] = await mintpad.read.getClaimableHunt([alice.account.address, TEST_TOKEN]);
          assert.equal(newClaimableHunt, 0n);
        });

        it("should handle vote expiration (30 days)", async function () {
          await setupMultipleDays();

          // Set day counter to 32 (so votes before day 2 are expired)
          await mintpad.write.setDayCounter([32], { account: owner.account });
          const [claimableHunt] = await mintpad.read.getClaimableHunt([alice.account.address, TEST_TOKEN]);

          // Only Day 2 vote should be claimable (Day 1 is > 30 days ago)
          assert.equal(claimableHunt, DAILY_ALICE_REWARDS_EXPECTED[1]);

          // Set day counter to 33 (so votes before day 3 are expired)
          await mintpad.write.setDayCounter([33], { account: owner.account });
          const [claimableHunt1] = await mintpad.read.getClaimableHunt([alice.account.address, TEST_TOKEN]);

          // All expired
          assert.equal(claimableHunt1, 0n);
        });
      }); // getClaimableHunt
    }); // View functions
  }); // Claim function
}); // Mintpad
