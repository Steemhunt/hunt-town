import assert from "node:assert/strict";
import { describe, it, beforeEach } from "node:test";
import { network } from "hardhat";
import { getContract, erc20Abi } from "viem";

// Constants for testing
const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";
const BOND_ADDRESS = "0xc5a076cad94176c2996B32d8466Be1cE757FAa27";
const BOND_PERIPHERY_ADDRESS = "0x492C412369Db76C9cdD9939e6C521579301473a3";
const HUNT_TOKEN = "0x37f0c2915CeCC7e977183B8543Fc0864d03E064C";
const TEST_TOKEN = "0xDF2B673Ec06d210C8A8Be89441F8de60B5C679c9"; // SIGNET
const INITIAL_HUNT_BALANCE = 10_000n * 10n ** 18n;
const DAILY_HUNT_REWARD = 1000n * 10n ** 18n; // 1000 HUNT per day in Wei
const SECONDS_PER_DAY = 86400n;

describe("Mintpad", async function () {
  const connection = await network.connect("baseFork");
  const { viem, networkHelpers } = connection;
  const { impersonateAccount, stopImpersonatingAccount, time } = networkHelpers;

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

  async function signVotingPoint(
    mintpadAddress: `0x${string}`,
    userAddress: `0x${string}`,
    day: bigint,
    votingPoint: number,
    signerWallet: any
  ) {
    const chainId = await signerWallet.getChainId();

    const domain = {
      name: "Mintpad",
      version: "1",
      chainId: chainId,
      verifyingContract: mintpadAddress
    };

    const types = {
      VotingPoint: [
        { name: "user", type: "address" },
        { name: "day", type: "uint256" },
        { name: "votingPoint", type: "uint32" }
      ]
    };

    const message = {
      user: userAddress,
      day: day,
      votingPoint: votingPoint
    };

    const signature = await signerWallet.signTypedData({
      domain,
      types,
      primaryType: "VotingPoint",
      message
    });

    return signature;
  }

  async function deployMintpadFixture() {
    const [owner, signer, alice, bob] = await viem.getWalletClients();

    // @ts-ignore - Constructor signature updated
    const mintpad = await viem.deployContract("Mintpad", [signer.account.address, DAILY_HUNT_REWARD]);

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

    return { mintpad, owner, signer, alice, bob, huntToken, testToken };
  }

  let mintpad: any;
  let owner: any;
  let signer: any;
  let alice: any;
  let bob: any;
  let huntToken: any;
  let testToken: any;

  beforeEach(async function () {
    ({ mintpad, owner, signer, alice, bob, huntToken, testToken } = await networkHelpers.loadFixture(
      deployMintpadFixture
    ));
  });

  describe("Contract initialization", function () {
    it("should deploy with correct parameters", async function () {
      const bondAddress = await mintpad.read.BOND();
      const signerAddress = await mintpad.read.signer();
      const dailyHuntReward = await mintpad.read.dailyHuntReward();
      const contractBalance = await huntToken.read.balanceOf([mintpad.address]);

      assert.equal(bondAddress.toLowerCase(), BOND_ADDRESS.toLowerCase());
      assert.equal(signerAddress.toLowerCase(), signer.account.address.toLowerCase());
      assert.equal(dailyHuntReward, DAILY_HUNT_REWARD);
      assert.equal(contractBalance, INITIAL_HUNT_BALANCE);
    });

    it("should initialize getCurrentDay to 0", async function () {
      const currentDay = await mintpad.read.getCurrentDay();
      assert.equal(currentDay, 0n);
    });

    it("should revert with zero signer address", async function () {
      await assert.rejects(
        // @ts-ignore - Constructor signature updated
        viem.deployContract("Mintpad", [ZERO_ADDRESS, DAILY_HUNT_REWARD]),
        /Mintpad__InvalidParams\("zero address"\)/
      );
    });

    it("should revert with zero dailyHuntReward", async function () {
      await assert.rejects(
        // @ts-ignore - Constructor signature updated
        viem.deployContract("Mintpad", [signer.account.address, 0]),
        /Mintpad__InvalidParams\("dailyHuntReward cannot be zero"\)/
      );
    });
  }); // Contract initialization

  describe("Admin functions", function () {
    describe("updateSignerAddress", function () {
      it("should allow owner to update signer address", async function () {
        const newSigner = bob.account.address;

        const tx = mintpad.write.updateSignerAddress([newSigner], { account: owner.account });
        await viem.assertions.emit(tx, mintpad, "SignerAddressUpdated");

        const updatedSigner = await mintpad.read.signer();
        assert.equal(updatedSigner.toLowerCase(), newSigner.toLowerCase());
      });

      it("should revert when non-owner tries to update", async function () {
        await assert.rejects(
          mintpad.write.updateSignerAddress([bob.account.address], { account: alice.account }),
          /OwnableUnauthorizedAccount/
        );
      });

      it("should revert with zero address", async function () {
        await assert.rejects(
          mintpad.write.updateSignerAddress([ZERO_ADDRESS], { account: owner.account }),
          /Mintpad__InvalidParams\("zero address"\)/
        );
      });
    }); // updateSignerAddress

    describe("setDailyHuntReward", function () {
      it("should allow owner to set daily hunt reward", async function () {
        const newReward = 2000n * 10n ** 18n;

        const tx = mintpad.write.setDailyHuntReward([newReward], { account: owner.account });
        await viem.assertions.emit(tx, mintpad, "DailyHuntRewardUpdated");

        const updatedReward = await mintpad.read.dailyHuntReward();
        assert.equal(updatedReward, newReward);
      });

      it("should revert when non-owner tries to update", async function () {
        await assert.rejects(
          mintpad.write.setDailyHuntReward([2000n * 10n ** 18n], { account: alice.account }),
          /OwnableUnauthorizedAccount/
        );
      });

      it("should revert with zero value", async function () {
        await assert.rejects(
          mintpad.write.setDailyHuntReward([0n], { account: owner.account }),
          /Mintpad__InvalidParams\("dailyHuntReward cannot be zero"\)/
        );
      });
    }); // setDailyHuntReward

    describe("refundHUNT", function () {
      it("should allow owner to refund HUNT tokens", async function () {
        const refundAmount = 5_000n * 10n ** 18n;
        const initialOwnerBalance = await huntToken.read.balanceOf([owner.account.address]);

        await mintpad.write.refundHUNT([refundAmount], { account: owner.account });

        const finalOwnerBalance = await huntToken.read.balanceOf([owner.account.address]);
        const finalContractBalance = await huntToken.read.balanceOf([mintpad.address]);

        assert.equal(finalOwnerBalance, initialOwnerBalance + refundAmount);
        assert.equal(finalContractBalance, INITIAL_HUNT_BALANCE - refundAmount);
      });

      it("should revert when non-owner tries to refund", async function () {
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
  }); // Admin functions

  describe("activateVotingPoint", function () {
    it("should activate voting points with valid signature", async function () {
      const votingPoint = 1000;
      const day = await mintpad.read.getCurrentDay();
      const signature = await signVotingPoint(mintpad.address, alice.account.address, day, votingPoint, signer);

      const tx = mintpad.write.activateVotingPoint([votingPoint, signature], { account: alice.account });
      await viem.assertions.emit(tx, mintpad, "VotingPointActivated");

      const alicePoints = await mintpad.read.dailyUserVotingPoint([day, alice.account.address]);
      const stats = await mintpad.read.dailyStats([day]);

      assert.equal(alicePoints[0], votingPoint); // activated
      assert.equal(alicePoints[1], votingPoint); // left
      assert.equal(stats[0], votingPoint); // totalVotingPointGiven
    });

    it("should revert with invalid signature", async function () {
      const votingPoint = 1000;
      const day = await mintpad.read.getCurrentDay();
      const wrongSignature = await signVotingPoint(mintpad.address, bob.account.address, day, votingPoint, signer);

      await assert.rejects(
        mintpad.write.activateVotingPoint([votingPoint, wrongSignature], { account: alice.account }),
        /Mintpad__InvalidSignature/
      );
    });

    it("should revert if already activated for the day", async function () {
      const votingPoint = 1000;
      const day = await mintpad.read.getCurrentDay();
      const signature = await signVotingPoint(mintpad.address, alice.account.address, day, votingPoint, signer);

      await mintpad.write.activateVotingPoint([votingPoint, signature], { account: alice.account });

      const signature2 = await signVotingPoint(mintpad.address, alice.account.address, day, 500, signer);
      await assert.rejects(
        mintpad.write.activateVotingPoint([500, signature2], { account: alice.account }),
        /Mintpad__AlreadyActivated/
      );
    });

    it("should revert with zero voting point", async function () {
      const day = await mintpad.read.getCurrentDay();
      const signature = await signVotingPoint(mintpad.address, alice.account.address, day, 0, signer);

      await assert.rejects(
        mintpad.write.activateVotingPoint([0, signature], { account: alice.account }),
        /Mintpad__InvalidParams\("votingPoint cannot be zero"\)/
      );
    });

    it("should allow activation on new day", async function () {
      const votingPoint = 1000;
      const day0 = await mintpad.read.getCurrentDay();
      const signature0 = await signVotingPoint(mintpad.address, alice.account.address, day0, votingPoint, signer);

      await mintpad.write.activateVotingPoint([votingPoint, signature0], { account: alice.account });

      // Move to next day
      await time.increase(Number(SECONDS_PER_DAY));

      const day1 = await mintpad.read.getCurrentDay();
      assert.equal(day1, 1n);

      const signature1 = await signVotingPoint(mintpad.address, alice.account.address, day1, votingPoint, signer);
      await mintpad.write.activateVotingPoint([votingPoint, signature1], { account: alice.account });

      const alicePointsDay1 = await mintpad.read.dailyUserVotingPoint([day1, alice.account.address]);
      assert.equal(alicePointsDay1[0], votingPoint); // activated
      assert.equal(alicePointsDay1[1], votingPoint); // left
    });
  }); // activateVotingPoint

  describe("vote", function () {
    async function activatePoints(user: any, points: number) {
      const day = await mintpad.read.getCurrentDay();
      const signature = await signVotingPoint(mintpad.address, user.account.address, day, points, signer);
      await mintpad.write.activateVotingPoint([points, signature], { account: user.account });
    }

    it("should allow voting with activated points", async function () {
      await activatePoints(alice, 1000);

      const day = await mintpad.read.getCurrentDay();
      const voteAmount = 500;

      const tx = mintpad.write.vote([TEST_TOKEN, voteAmount], { account: alice.account });
      await viem.assertions.emit(tx, mintpad, "Voted");

      const remainingPoints = await mintpad.read.dailyUserVotingPoint([day, alice.account.address]);
      const tokenVotes = await mintpad.read.dailyUserTokenVotes([day, alice.account.address, TEST_TOKEN]);
      const stats = await mintpad.read.dailyStats([day]);

      assert.equal(remainingPoints[0], 1000); // activated - Original activated amount
      assert.equal(remainingPoints[1], 500); // left - Remaining after vote
      assert.equal(tokenVotes, voteAmount);
      assert.equal(stats[1], voteAmount); // totalVotingPointSpent
      assert.equal(stats[2], 1); // votingCount
    });

    it("should allow multiple votes from same user", async function () {
      await activatePoints(alice, 1000);

      const day = await mintpad.read.getCurrentDay();
      await mintpad.write.vote([TEST_TOKEN, 300], { account: alice.account });
      await mintpad.write.vote([TEST_TOKEN, 400], { account: alice.account });

      const remainingPoints = await mintpad.read.dailyUserVotingPoint([day, alice.account.address]);
      const tokenVotes = await mintpad.read.dailyUserTokenVotes([day, alice.account.address, TEST_TOKEN]);
      const stats = await mintpad.read.dailyStats([day]);

      assert.equal(remainingPoints[0], 1000); // activated - Original activated amount
      assert.equal(remainingPoints[1], 300); // left - Remaining after votes
      assert.equal(tokenVotes, 700);
      assert.equal(stats[1], 700); // totalVotingPointSpent
      assert.equal(stats[2], 2); // votingCount
    });

    it("should revert with insufficient voting points", async function () {
      await activatePoints(alice, 100);

      await assert.rejects(
        mintpad.write.vote([TEST_TOKEN, 101], { account: alice.account }),
        /Mintpad__InsufficientVotingPoints/
      );
    });

    it("should revert with zero vote amount", async function () {
      await activatePoints(alice, 1000);

      await assert.rejects(
        mintpad.write.vote([TEST_TOKEN, 0], { account: alice.account }),
        /Mintpad__InvalidParams\("voteAmount"\)/
      );
    });

    it("should revert with invalid token address", async function () {
      await activatePoints(alice, 1000);

      await assert.rejects(
        mintpad.write.vote([ZERO_ADDRESS, 100], { account: alice.account }),
        /Mintpad__InvalidParams\("zero address"\)/
      );

      // Test with HUNT token itself (valid ERC20 with 18 decimals but not a child token)
      await assert.rejects(
        mintpad.write.vote([HUNT_TOKEN, 100], { account: alice.account }),
        /Mintpad__InvalidParams\("not HUNT child token"\)/
      );
    });
  }); // vote

  describe("claim", function () {
    async function setupVotingScenario() {
      // Day 0: Alice votes 800 points
      const day0 = await mintpad.read.getCurrentDay();
      const sig0Alice = await signVotingPoint(mintpad.address, alice.account.address, day0, 1000, signer);
      await mintpad.write.activateVotingPoint([1000, sig0Alice], { account: alice.account });
      await mintpad.write.vote([TEST_TOKEN, 800], { account: alice.account });

      // Move to Day 1
      await time.increase(Number(SECONDS_PER_DAY));

      // Day 1: Alice votes 600, Bob votes 400
      const day1 = await mintpad.read.getCurrentDay();
      const sig1Alice = await signVotingPoint(mintpad.address, alice.account.address, day1, 1000, signer);
      const sig1Bob = await signVotingPoint(mintpad.address, bob.account.address, day1, 500, signer);
      await mintpad.write.activateVotingPoint([1000, sig1Alice], { account: alice.account });
      await mintpad.write.activateVotingPoint([500, sig1Bob], { account: bob.account });
      await mintpad.write.vote([TEST_TOKEN, 600], { account: alice.account });
      await mintpad.write.vote([TEST_TOKEN, 400], { account: bob.account });

      // Move to Day 2 (claims can be made for Day 0 and Day 1)
      await time.increase(Number(SECONDS_PER_DAY));

      return { day0, day1 };
    }

    it("should allow claiming rewards", async function () {
      await setupVotingScenario();

      // Alice should get: Day 0: 800/800 * 1000 = 1000 HUNT, Day 1: 600/1000 * 1000 = 600 HUNT
      // Total: 1600 HUNT
      const [claimableHunt, endDay] = await mintpad.read.getClaimableHunt([alice.account.address, TEST_TOKEN]);

      // Day 0: 800/800 * 1000 = 1000 HUNT
      // Day 1: 600/1000 * 1000 = 600 HUNT
      // Total = 1600 HUNT
      const expectedHunt = 1600n * 10n ** 18n;
      assert.equal(claimableHunt, expectedHunt);
      assert.equal(endDay, 1n);

      const tokensToMint = await estimateTokenAmount(TEST_TOKEN, claimableHunt);
      const initialBalance = await testToken.read.balanceOf([alice.account.address]);

      await mintpad.write.claim([TEST_TOKEN, tokensToMint, 0], { account: alice.account });

      const finalBalance = await testToken.read.balanceOf([alice.account.address]);
      assert.equal(finalBalance, initialBalance + tokensToMint);

      const lastClaimDay = await mintpad.read.userTokenLastClaimDay([alice.account.address, TEST_TOKEN]);
      assert.equal(lastClaimDay, 1n);
    });

    it("should handle donations correctly", async function () {
      await setupVotingScenario();

      const donationBp = 1000n; // 10%
      const [claimableHunt] = await mintpad.read.getClaimableHunt([bob.account.address, TEST_TOKEN]);
      const tokensToMint = await estimateTokenAmount(TEST_TOKEN, claimableHunt);

      const publicClient = await viem.getPublicClient();
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
        client: publicClient
      });

      const [tokenCreator] = await bondContract.read.tokenBond([TEST_TOKEN]);
      const initialCreatorBalance = await testToken.read.balanceOf([tokenCreator]);
      const initialBobBalance = await testToken.read.balanceOf([bob.account.address]);

      await mintpad.write.claim([TEST_TOKEN, tokensToMint, Number(donationBp)], { account: bob.account });

      const finalCreatorBalance = await testToken.read.balanceOf([tokenCreator]);
      const finalBobBalance = await testToken.read.balanceOf([bob.account.address]);

      const donationAmount = (tokensToMint * donationBp) / 10000n;
      assert.equal(finalCreatorBalance, initialCreatorBalance + donationAmount);
      assert.equal(finalBobBalance, initialBobBalance + tokensToMint - donationAmount);
    });

    it("should prevent double claiming", async function () {
      await setupVotingScenario();

      const [claimableHunt] = await mintpad.read.getClaimableHunt([alice.account.address, TEST_TOKEN]);
      const tokensToMint = await estimateTokenAmount(TEST_TOKEN, claimableHunt);

      await mintpad.write.claim([TEST_TOKEN, tokensToMint, 0], { account: alice.account });

      await assert.rejects(
        mintpad.write.claim([TEST_TOKEN, tokensToMint, 0], { account: alice.account }),
        /Mintpad__NothingToClaim/
      );
    });

    it("should revert with zero tokensToMint", async function () {
      await setupVotingScenario();

      await assert.rejects(
        mintpad.write.claim([TEST_TOKEN, 0n, 0], { account: alice.account }),
        /Mintpad__InvalidParams\("tokensToMint must be greater than 0"\)/
      );
    });

    it("should revert with nothing to claim", async function () {
      // Claim function no longer validates token upfront (no _validChildToken modifier)
      // It will revert with NothingToClaim when there are no votes for the token
      await assert.rejects(
        mintpad.write.claim([TEST_TOKEN, 100n * 10n ** 18n, 0], { account: alice.account }),
        /Mintpad__NothingToClaim/
      );
    });

    describe("Vote expiration (30 days)", function () {
      it("should allow claiming votes within 30 days", async function () {
        // Setup voting on day 0
        const day0 = await mintpad.read.getCurrentDay();
        const sig0 = await signVotingPoint(mintpad.address, alice.account.address, day0, 1000, signer);
        await mintpad.write.activateVotingPoint([1000, sig0], { account: alice.account });
        await mintpad.write.vote([TEST_TOKEN, 800], { account: alice.account });

        // Move forward 29 days (still within 30-day window)
        await time.increase(Number(SECONDS_PER_DAY * 29n));

        const [claimableHunt] = await mintpad.read.getClaimableHunt([alice.account.address, TEST_TOKEN]);
        // Day 0: 800/800 * 1000 = 1000 HUNT
        assert.equal(claimableHunt, 1000n * 10n ** 18n);
      });

      it("should allow claiming votes exactly at 30 days", async function () {
        // Setup voting on day 0
        const day0 = await mintpad.read.getCurrentDay();
        const sig0 = await signVotingPoint(mintpad.address, alice.account.address, day0, 1000, signer);
        await mintpad.write.activateVotingPoint([1000, sig0], { account: alice.account });
        await mintpad.write.vote([TEST_TOKEN, 800], { account: alice.account });

        // Move forward exactly 30 days
        await time.increase(Number(SECONDS_PER_DAY * 30n));

        const [claimableHunt] = await mintpad.read.getClaimableHunt([alice.account.address, TEST_TOKEN]);
        // Day 0: 800/800 * 1000 = 1000 HUNT (still claimable on day 30)
        assert.equal(claimableHunt, 1000n * 10n ** 18n);
      });

      it("should expire votes after 31 days", async function () {
        // Setup voting on day 0
        const day0 = await mintpad.read.getCurrentDay();
        const sig0 = await signVotingPoint(mintpad.address, alice.account.address, day0, 1000, signer);
        await mintpad.write.activateVotingPoint([1000, sig0], { account: alice.account });
        await mintpad.write.vote([TEST_TOKEN, 800], { account: alice.account });

        // Move forward 31 days (past expiration)
        await time.increase(Number(SECONDS_PER_DAY * 31n));

        const [claimableHunt] = await mintpad.read.getClaimableHunt([alice.account.address, TEST_TOKEN]);
        assert.equal(claimableHunt, 0n); // Votes expired
      });

      it("should only expire old votes, keeping recent ones", async function () {
        // Day 0: Alice votes
        const day0 = await mintpad.read.getCurrentDay();
        const sig0 = await signVotingPoint(mintpad.address, alice.account.address, day0, 1000, signer);
        await mintpad.write.activateVotingPoint([1000, sig0], { account: alice.account });
        await mintpad.write.vote([TEST_TOKEN, 400], { account: alice.account });

        // Move to Day 15
        await time.increase(Number(SECONDS_PER_DAY * 15n));
        const day15 = await mintpad.read.getCurrentDay();
        const sig15 = await signVotingPoint(mintpad.address, alice.account.address, day15, 1000, signer);
        await mintpad.write.activateVotingPoint([1000, sig15], { account: alice.account });
        await mintpad.write.vote([TEST_TOKEN, 600], { account: alice.account });

        // Move to Day 32 (Day 0 expired, Day 15 still valid)
        await time.increase(Number(SECONDS_PER_DAY * 17n));

        const [claimableHunt] = await mintpad.read.getClaimableHunt([alice.account.address, TEST_TOKEN]);
        // Day 0: expired (not included)
        // Day 15: 600/600 * 1000 = 1000 HUNT
        assert.equal(claimableHunt, 1000n * 10n ** 18n);
      });
    }); // Vote expiration (30 days)

    it("should update daily stats on claim", async function () {
      await setupVotingScenario();

      const currentDay = await mintpad.read.getCurrentDay();
      const initialStats = await mintpad.read.dailyStats([currentDay]);

      const [claimableHunt] = await mintpad.read.getClaimableHunt([alice.account.address, TEST_TOKEN]);
      const tokensToMint = await estimateTokenAmount(TEST_TOKEN, claimableHunt);

      const publicClient = await viem.getPublicClient();
      const txHash = await mintpad.write.claim([TEST_TOKEN, tokensToMint, 0], { account: alice.account });
      const receipt = await publicClient.waitForTransactionReceipt({ hash: txHash });
      const claimedEvents = await mintpad.getEvents.Claimed(
        {},
        { fromBlock: receipt.blockNumber, toBlock: receipt.blockNumber }
      );
      const actualHuntSpent = claimedEvents[0].args.actualHuntSpent!;

      const finalStats = await mintpad.read.dailyStats([currentDay]);
      assert.equal(finalStats[3], initialStats[3] + 1); // claimCount
      assert.equal(finalStats[4], initialStats[4] + actualHuntSpent); // totalHuntClaimed
    });

    it("should revert with excessive leftover when tokensToMint is too low", async function () {
      await setupVotingScenario();

      const [claimableHunt] = await mintpad.read.getClaimableHunt([alice.account.address, TEST_TOKEN]);
      const tokensToMint = await estimateTokenAmount(TEST_TOKEN, claimableHunt);

      // Request significantly fewer tokens to cause excessive leftover (< 98% efficiency)
      // This will result in actualHuntSpent being much less than totalHuntToClaim
      const inefficientTokensToMint = (tokensToMint * 97n) / 100n; // Request only 97% of optimal amount

      await assert.rejects(
        mintpad.write.claim([TEST_TOKEN, inefficientTokensToMint, 0], { account: alice.account }),
        /Mintpad__ExcessiveLeftover/
      );
    });
  }); // claim

  describe("getDeploymentDayTimestamp", function () {
    it("should return UTC midnight of deployment day", async function () {
      const deploymentTimestamp = await mintpad.read.getDeploymentDayTimestamp();

      // Should be aligned to UTC midnight (divisible by 86400)
      assert.equal(deploymentTimestamp % SECONDS_PER_DAY, 0n);
    });

    it("should be consistent with getCurrentDay calculation", async function () {
      const deploymentTimestamp = await mintpad.read.getDeploymentDayTimestamp();
      const currentDay = await mintpad.read.getCurrentDay();

      // Get current block timestamp
      const currentTimestamp = BigInt(await time.latest());

      // Verify the relationship: currentDay = (currentTimestamp - deploymentTimestamp) / SECONDS_PER_DAY
      const expectedDay = (currentTimestamp - deploymentTimestamp) / SECONDS_PER_DAY;
      assert.equal(currentDay, expectedDay);
    });

    it("should remain constant after time passes", async function () {
      const initialTimestamp = await mintpad.read.getDeploymentDayTimestamp();

      // Move forward 5 days
      await time.increase(Number(SECONDS_PER_DAY * 5n));

      const laterTimestamp = await mintpad.read.getDeploymentDayTimestamp();
      assert.equal(initialTimestamp, laterTimestamp);
    });
  }); // getDeploymentDayTimestamp

  describe("getClaimableHuntMultiple", function () {
    // Use another verified HUNT child token on Base: MT
    const TEST_TOKEN_2 = "0xFf45161474C39cB00699070Dd49582e417b57a7E";

    async function activatePoints(user: any, points: number) {
      const day = await mintpad.read.getCurrentDay();
      const signature = await signVotingPoint(mintpad.address, user.account.address, day, points, signer);
      await mintpad.write.activateVotingPoint([points, signature], { account: user.account });
    }

    it("should return claimable amounts for multiple tokens", async function () {
      // Day 0: Alice votes for both tokens
      await activatePoints(alice, 1000);
      await mintpad.write.vote([TEST_TOKEN, 400], { account: alice.account });
      await mintpad.write.vote([TEST_TOKEN_2, 300], { account: alice.account });

      // Move to Day 1 so we can query claimable
      await time.increase(Number(SECONDS_PER_DAY));

      const [huntAmounts, endDays] = await mintpad.read.getClaimableHuntMultiple([
        alice.account.address,
        [TEST_TOKEN, TEST_TOKEN_2]
      ]);

      // Day 0: Total votes = 700, dailyHuntReward = 1000 HUNT
      // TEST_TOKEN: 400/700 * 1000 ≈ 571.42 HUNT
      // TEST_TOKEN_2: 300/700 * 1000 ≈ 428.57 HUNT
      const expectedToken1 = (400n * DAILY_HUNT_REWARD) / 700n;
      const expectedToken2 = (300n * DAILY_HUNT_REWARD) / 700n;

      assert.equal(huntAmounts.length, 2);
      assert.equal(endDays.length, 2);
      assert.equal(huntAmounts[0], expectedToken1);
      assert.equal(huntAmounts[1], expectedToken2);
      assert.equal(endDays[0], 0n);
      assert.equal(endDays[1], 0n);
    });

    it("should return zeros for tokens with no votes", async function () {
      // Day 0: Alice votes for only TEST_TOKEN
      await activatePoints(alice, 1000);
      await mintpad.write.vote([TEST_TOKEN, 500], { account: alice.account });

      // Move to Day 1
      await time.increase(Number(SECONDS_PER_DAY));

      const [huntAmounts, endDays] = await mintpad.read.getClaimableHuntMultiple([
        alice.account.address,
        [TEST_TOKEN, TEST_TOKEN_2]
      ]);

      // TEST_TOKEN: 500/500 * 1000 = 1000 HUNT
      // TEST_TOKEN_2: 0 (no votes)
      assert.equal(huntAmounts[0], DAILY_HUNT_REWARD);
      assert.equal(huntAmounts[1], 0n);
      assert.equal(endDays[0], 0n);
      assert.equal(endDays[1], 0n);
    });

    it("should handle empty token array", async function () {
      const [huntAmounts, endDays] = await mintpad.read.getClaimableHuntMultiple([alice.account.address, []]);

      assert.equal(huntAmounts.length, 0);
      assert.equal(endDays.length, 0);
    });

    it("should return consistent results with individual getClaimableHunt calls", async function () {
      // Day 0: Alice votes for both tokens
      await activatePoints(alice, 1000);
      await mintpad.write.vote([TEST_TOKEN, 600], { account: alice.account });
      await mintpad.write.vote([TEST_TOKEN_2, 200], { account: alice.account });

      // Move to Day 1
      await time.increase(Number(SECONDS_PER_DAY));

      // Get results from batch call
      const [huntAmounts, endDays] = await mintpad.read.getClaimableHuntMultiple([
        alice.account.address,
        [TEST_TOKEN, TEST_TOKEN_2]
      ]);

      // Get results from individual calls
      const [hunt1, endDay1] = await mintpad.read.getClaimableHunt([alice.account.address, TEST_TOKEN]);
      const [hunt2, endDay2] = await mintpad.read.getClaimableHunt([alice.account.address, TEST_TOKEN_2]);

      // Results should match
      assert.equal(huntAmounts[0], hunt1);
      assert.equal(huntAmounts[1], hunt2);
      assert.equal(endDays[0], endDay1);
      assert.equal(endDays[1], endDay2);
    });

    it("should handle multiple days of voting", async function () {
      // Day 0: Alice votes
      await activatePoints(alice, 1000);
      await mintpad.write.vote([TEST_TOKEN, 400], { account: alice.account });
      await mintpad.write.vote([TEST_TOKEN_2, 200], { account: alice.account });

      // Move to Day 1: Alice votes again
      await time.increase(Number(SECONDS_PER_DAY));
      await activatePoints(alice, 800);
      await mintpad.write.vote([TEST_TOKEN, 300], { account: alice.account });

      // Move to Day 2 to query
      await time.increase(Number(SECONDS_PER_DAY));

      const [huntAmounts, endDays] = await mintpad.read.getClaimableHuntMultiple([
        alice.account.address,
        [TEST_TOKEN, TEST_TOKEN_2]
      ]);

      // Day 0: Total votes = 600
      //   TEST_TOKEN: 400/600 * 1000 ≈ 666.66 HUNT
      //   TEST_TOKEN_2: 200/600 * 1000 ≈ 333.33 HUNT
      // Day 1: Total votes = 300
      //   TEST_TOKEN: 300/300 * 1000 = 1000 HUNT
      //   TEST_TOKEN_2: 0/300 * 1000 = 0 HUNT
      const day0Token1 = (400n * DAILY_HUNT_REWARD) / 600n;
      const day0Token2 = (200n * DAILY_HUNT_REWARD) / 600n;
      const day1Token1 = (300n * DAILY_HUNT_REWARD) / 300n;

      assert.equal(huntAmounts[0], day0Token1 + day1Token1);
      assert.equal(huntAmounts[1], day0Token2);
      assert.equal(endDays[0], 1n);
      assert.equal(endDays[1], 1n);
    });
  }); // getClaimableHuntMultiple

  describe("getCurrentDay", function () {
    it("should return 0 on deployment day", async function () {
      const currentDay = await mintpad.read.getCurrentDay();
      assert.equal(currentDay, 0n);
    });

    it("should increment after 24 hours", async function () {
      await time.increase(Number(SECONDS_PER_DAY));
      const currentDay = await mintpad.read.getCurrentDay();
      assert.equal(currentDay, 1n);
    });

    it("should increment correctly after multiple days", async function () {
      await time.increase(Number(SECONDS_PER_DAY * 5n));
      const currentDay = await mintpad.read.getCurrentDay();
      assert.equal(currentDay, 5n);
    });

    it("should align day boundaries with UTC midnight", async function () {
      // Get current blockchain time and calculate a mid-day timestamp
      const currentTime = BigInt(await time.latest());

      // Calculate the next UTC midnight after current time
      const currentUtcDay = currentTime / SECONDS_PER_DAY;
      const nextMidnight = (currentUtcDay + 1n) * SECONDS_PER_DAY;

      // Set deployment time to 6 hours (21600 seconds) before next midnight
      const deploymentTimestamp = nextMidnight - 21600n;
      await time.setNextBlockTimestamp(Number(deploymentTimestamp));

      // @ts-ignore - Constructor signature updated
      const testMintpad = await viem.deployContract("Mintpad", [signer.account.address, DAILY_HUNT_REWARD]);

      // Should be day 0 immediately after deployment (deployed at 18:00 UTC)
      let currentDay = await testMintpad.read.getCurrentDay();
      assert.equal(currentDay, 0n);

      // Advance to 1 second before midnight - should still be day 0
      await time.increase(21600 - 1); // 6 hours minus 1 second
      currentDay = await testMintpad.read.getCurrentDay();
      assert.equal(currentDay, 0n, "Should still be day 0 one second before midnight");

      // Advance 1 more second to reach exactly midnight - should now be day 1
      await time.increase(1);
      currentDay = await testMintpad.read.getCurrentDay();
      assert.equal(currentDay, 1n, "Should be day 1 at UTC midnight");

      // Advance another full day (86400 seconds) - should be day 2
      await time.increase(Number(SECONDS_PER_DAY));
      currentDay = await testMintpad.read.getCurrentDay();
      assert.equal(currentDay, 2n, "Should be day 2 after another full UTC day");
    });
  }); // getCurrentDay
}); // Mintpad
