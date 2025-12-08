import assert from "node:assert/strict";
import { describe, it, beforeEach } from "node:test";
import { network } from "hardhat";
import { getContract, erc20Abi } from "viem";

// Constants for testing
const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";
const DEAD_ADDRESS = "0x000000000000000000000000000000000000dEaD";
const BOND_ADDRESS = "0xc5a076cad94176c2996B32d8466Be1cE757FAa27";
const HUNT_TOKEN = "0x37f0c2915CeCC7e977183B8543Fc0864d03E064C";
const TEST_TOKEN = "0xDF2B673Ec06d210C8A8Be89441F8de60B5C679c9"; // SIGNET
const TEST_TOKEN_2 = "0xFf45161474C39cB00699070Dd49582e417b57a7E"; // MT
const PRICE_PER_UPDATE = 10n * 10n ** 18n; // 10 HUNT
const HUNT_WHALE = "0xCB3f3e0E992435390e686D7b638FCb8baBa6c5c7";

describe("ProjectUpdates", async function () {
  const connection = await network.connect("baseFork");
  const { viem, networkHelpers } = connection;
  const { impersonateAccount, stopImpersonatingAccount } = networkHelpers;

  async function getTokenCreator(token: `0x${string}`) {
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
    const [creator] = await bondContract.read.tokenBond([token]);
    return creator;
  }

  async function deployProjectUpdatesFixture() {
    const [owner, alice, bob] = await viem.getWalletClients();

    const projectUpdates = await viem.deployContract("ProjectUpdates", [PRICE_PER_UPDATE]);

    // Get the creator of TEST_TOKEN from the BOND contract
    const tokenCreator = await getTokenCreator(TEST_TOKEN);
    const tokenCreator2 = await getTokenCreator(TEST_TOKEN_2);

    // Setup HUNT token contract
    const huntToken = getContract({
      address: HUNT_TOKEN,
      abi: erc20Abi,
      client: owner
    });

    // Fund the token creator with HUNT for testing
    await impersonateAccount(HUNT_WHALE);
    await huntToken.write.transfer([tokenCreator, 1000n * 10n ** 18n], {
      account: HUNT_WHALE
    });
    await huntToken.write.transfer([tokenCreator2, 1000n * 10n ** 18n], {
      account: HUNT_WHALE
    });
    await stopImpersonatingAccount(HUNT_WHALE);

    // Approve ProjectUpdates contract to spend HUNT on behalf of token creators
    await impersonateAccount(tokenCreator);
    await huntToken.write.approve([projectUpdates.address, 1000n * 10n ** 18n], {
      account: tokenCreator
    });
    await stopImpersonatingAccount(tokenCreator);

    await impersonateAccount(tokenCreator2);
    await huntToken.write.approve([projectUpdates.address, 1000n * 10n ** 18n], {
      account: tokenCreator2
    });
    await stopImpersonatingAccount(tokenCreator2);

    return { projectUpdates, owner, alice, bob, huntToken, tokenCreator, tokenCreator2 };
  }

  let projectUpdates: any;
  let owner: any;
  let alice: any;
  let bob: any;
  let huntToken: any;
  let tokenCreator: `0x${string}`;
  let tokenCreator2: `0x${string}`;

  beforeEach(async function () {
    ({ projectUpdates, owner, alice, bob, huntToken, tokenCreator, tokenCreator2 } = await networkHelpers.loadFixture(
      deployProjectUpdatesFixture
    ));
  });

  describe("Contract initialization", function () {
    it("should deploy with correct parameters", async function () {
      const bondAddress = await projectUpdates.read.BOND();
      const price = await projectUpdates.read.pricePerUpdate();
      const count = await projectUpdates.read.getProjectUpdatesCount();

      assert.equal(bondAddress.toLowerCase(), BOND_ADDRESS.toLowerCase());
      assert.equal(price, PRICE_PER_UPDATE);
      assert.equal(count, 0n);
    });

    it("should set deployer as owner", async function () {
      const contractOwner = await projectUpdates.read.owner();
      assert.equal(contractOwner.toLowerCase(), owner.account.address.toLowerCase());
    });

    it("should allow deployment with zero pricePerUpdate for free updates", async function () {
      const freeContract = await viem.deployContract("ProjectUpdates", [0n]);
      const price = await freeContract.read.pricePerUpdate();
      assert.equal(price, 0n);
    });
  }); // Contract initialization

  describe("Admin functions", function () {
    describe("setPricePerUpdate", function () {
      it("should allow owner to set price per update", async function () {
        const newPrice = 20n * 10n ** 18n;

        const tx = projectUpdates.write.setPricePerUpdate([newPrice], { account: owner.account });
        await viem.assertions.emit(tx, projectUpdates, "PricePerUpdateChanged");

        const updatedPrice = await projectUpdates.read.pricePerUpdate();
        assert.equal(updatedPrice, newPrice);
      });

      it("should revert when non-owner tries to update", async function () {
        await assert.rejects(
          projectUpdates.write.setPricePerUpdate([20n * 10n ** 18n], { account: alice.account }),
          /OwnableUnauthorizedAccount/
        );
      });

      it("should allow setting zero for free updates", async function () {
        const tx = projectUpdates.write.setPricePerUpdate([0n], { account: owner.account });
        await viem.assertions.emit(tx, projectUpdates, "PricePerUpdateChanged");

        const updatedPrice = await projectUpdates.read.pricePerUpdate();
        assert.equal(updatedPrice, 0n);
      });
    }); // setPricePerUpdate
  }); // Admin functions

  describe("Free updates (price = 0)", function () {
    it("should allow posting without HUNT transfer when price is zero", async function () {
      // Set price to zero
      await projectUpdates.write.setPricePerUpdate([0n], { account: owner.account });

      const creatorBalanceBefore = await huntToken.read.balanceOf([tokenCreator]);
      const deadBalanceBefore = await huntToken.read.balanceOf([DEAD_ADDRESS]);

      await impersonateAccount(tokenCreator);
      await projectUpdates.write.postUpdate([TEST_TOKEN, "https://example.com/free-update"], { account: tokenCreator });
      await stopImpersonatingAccount(tokenCreator);

      const creatorBalanceAfter = await huntToken.read.balanceOf([tokenCreator]);
      const deadBalanceAfter = await huntToken.read.balanceOf([DEAD_ADDRESS]);

      // No HUNT should be transferred
      assert.equal(creatorBalanceBefore, creatorBalanceAfter);
      assert.equal(deadBalanceBefore, deadBalanceAfter);

      // Update should still be recorded
      const count = await projectUpdates.read.getProjectUpdatesCount();
      assert.equal(count, 1n);
    });

    it("should allow posting without HUNT approval when price is zero", async function () {
      // Deploy a new contract with zero price
      const freeContract = await viem.deployContract("ProjectUpdates", [0n]);

      // Note: tokenCreator has NOT approved this new contract
      // This should still work because no transfer happens
      await impersonateAccount(tokenCreator);
      await freeContract.write.postUpdate([TEST_TOKEN, "https://example.com/free-update"], { account: tokenCreator });
      await stopImpersonatingAccount(tokenCreator);

      const count = await freeContract.read.getProjectUpdatesCount();
      assert.equal(count, 1n);
    });

    it("should resume charging after price is set back from zero", async function () {
      // Set price to zero
      await projectUpdates.write.setPricePerUpdate([0n], { account: owner.account });

      // Post free update
      await impersonateAccount(tokenCreator);
      await projectUpdates.write.postUpdate([TEST_TOKEN, "https://example.com/free-update"], { account: tokenCreator });
      await stopImpersonatingAccount(tokenCreator);

      // Set price back to 10 HUNT
      await projectUpdates.write.setPricePerUpdate([PRICE_PER_UPDATE], { account: owner.account });

      const creatorBalanceBefore = await huntToken.read.balanceOf([tokenCreator]);

      // Post paid update
      await impersonateAccount(tokenCreator);
      await projectUpdates.write.postUpdate([TEST_TOKEN, "https://example.com/paid-update"], { account: tokenCreator });
      await stopImpersonatingAccount(tokenCreator);

      const creatorBalanceAfter = await huntToken.read.balanceOf([tokenCreator]);

      // HUNT should be charged again
      assert.equal(creatorBalanceBefore - creatorBalanceAfter, PRICE_PER_UPDATE);

      const count = await projectUpdates.read.getProjectUpdatesCount();
      assert.equal(count, 2n);
    });
  }); // Free updates (price = 0)

  describe("postUpdate", function () {
    it("should allow token creator to post update", async function () {
      const link = "https://example.com/update1";

      await impersonateAccount(tokenCreator);
      const tx = projectUpdates.write.postUpdate([TEST_TOKEN, link], { account: tokenCreator });
      await viem.assertions.emit(tx, projectUpdates, "ProjectUpdatePosted");
      await stopImpersonatingAccount(tokenCreator);

      const count = await projectUpdates.read.getProjectUpdatesCount();
      const tokenCount = await projectUpdates.read.getTokenProjectUpdatesCount([TEST_TOKEN]);

      assert.equal(count, 1n);
      assert.equal(tokenCount, 1n);

      const update = await projectUpdates.read.projectUpdates([0n]);
      assert.equal(update[0].toLowerCase(), TEST_TOKEN.toLowerCase());
      assert.equal(update[1], link);
    });

    it("should burn HUNT tokens on post", async function () {
      const link = "https://example.com/update1";

      const creatorBalanceBefore = await huntToken.read.balanceOf([tokenCreator]);
      const deadBalanceBefore = await huntToken.read.balanceOf([DEAD_ADDRESS]);

      await impersonateAccount(tokenCreator);
      await projectUpdates.write.postUpdate([TEST_TOKEN, link], { account: tokenCreator });
      await stopImpersonatingAccount(tokenCreator);

      const creatorBalanceAfter = await huntToken.read.balanceOf([tokenCreator]);
      const deadBalanceAfter = await huntToken.read.balanceOf([DEAD_ADDRESS]);

      assert.equal(creatorBalanceBefore - creatorBalanceAfter, PRICE_PER_UPDATE);
      assert.equal(deadBalanceAfter - deadBalanceBefore, PRICE_PER_UPDATE);
    });

    it("should allow multiple updates from same creator", async function () {
      await impersonateAccount(tokenCreator);
      await projectUpdates.write.postUpdate([TEST_TOKEN, "https://example.com/update1"], { account: tokenCreator });
      await projectUpdates.write.postUpdate([TEST_TOKEN, "https://example.com/update2"], { account: tokenCreator });
      await projectUpdates.write.postUpdate([TEST_TOKEN, "https://example.com/update3"], { account: tokenCreator });
      await stopImpersonatingAccount(tokenCreator);

      const count = await projectUpdates.read.getProjectUpdatesCount();
      const tokenCount = await projectUpdates.read.getTokenProjectUpdatesCount([TEST_TOKEN]);

      assert.equal(count, 3n);
      assert.equal(tokenCount, 3n);
    });

    it("should track updates for different tokens separately", async function () {
      await impersonateAccount(tokenCreator);
      await projectUpdates.write.postUpdate([TEST_TOKEN, "https://example.com/token1-update1"], {
        account: tokenCreator
      });
      await stopImpersonatingAccount(tokenCreator);

      await impersonateAccount(tokenCreator2);
      await projectUpdates.write.postUpdate([TEST_TOKEN_2, "https://example.com/token2-update1"], {
        account: tokenCreator2
      });
      await projectUpdates.write.postUpdate([TEST_TOKEN_2, "https://example.com/token2-update2"], {
        account: tokenCreator2
      });
      await stopImpersonatingAccount(tokenCreator2);

      const totalCount = await projectUpdates.read.getProjectUpdatesCount();
      const token1Count = await projectUpdates.read.getTokenProjectUpdatesCount([TEST_TOKEN]);
      const token2Count = await projectUpdates.read.getTokenProjectUpdatesCount([TEST_TOKEN_2]);

      assert.equal(totalCount, 3n);
      assert.equal(token1Count, 1n);
      assert.equal(token2Count, 2n);
    });

    it("should revert with zero token address", async function () {
      await impersonateAccount(tokenCreator);
      await assert.rejects(
        projectUpdates.write.postUpdate([ZERO_ADDRESS, "https://example.com/update"], { account: tokenCreator }),
        /ProjectUpdates__InvalidParams\("zero address"\)/
      );
      await stopImpersonatingAccount(tokenCreator);
    });

    it("should revert with empty link", async function () {
      await impersonateAccount(tokenCreator);
      await assert.rejects(
        projectUpdates.write.postUpdate([TEST_TOKEN, ""], { account: tokenCreator }),
        /ProjectUpdates__InvalidParams\("empty link"\)/
      );
      await stopImpersonatingAccount(tokenCreator);
    });

    it("should revert when non-creator tries to post", async function () {
      await assert.rejects(
        projectUpdates.write.postUpdate([TEST_TOKEN, "https://example.com/update"], { account: alice.account }),
        /ProjectUpdates__NotTokenCreator/
      );
    });

    it("should revert when creator tries to post for different token", async function () {
      // tokenCreator is creator of TEST_TOKEN, not TEST_TOKEN_2
      await impersonateAccount(tokenCreator);
      await assert.rejects(
        projectUpdates.write.postUpdate([TEST_TOKEN_2, "https://example.com/update"], { account: tokenCreator }),
        /ProjectUpdates__NotTokenCreator/
      );
      await stopImpersonatingAccount(tokenCreator);
    });

    it("should revert with insufficient HUNT balance", async function () {
      // Create a new wallet with no HUNT
      const [, , , newWallet] = await viem.getWalletClients();

      // This will fail because newWallet is not the token creator
      // but even if they were, they wouldn't have HUNT
      await assert.rejects(
        projectUpdates.write.postUpdate([TEST_TOKEN, "https://example.com/update"], { account: newWallet.account }),
        /ProjectUpdates__NotTokenCreator/
      );
    });
  }); // postUpdate

  describe("getLatestUpdates", function () {
    async function setupMultipleUpdates() {
      // Post 5 updates
      await impersonateAccount(tokenCreator);
      for (let i = 1; i <= 5; i++) {
        await projectUpdates.write.postUpdate([TEST_TOKEN, `https://example.com/update${i}`], {
          account: tokenCreator
        });
      }
      await stopImpersonatingAccount(tokenCreator);
    }

    it("should return empty array when no updates exist", async function () {
      const updates = await projectUpdates.read.getLatestUpdates([0n, 10n]);
      assert.equal(updates.length, 0);
    });

    it("should return updates in reverse chronological order", async function () {
      await setupMultipleUpdates();

      const updates = await projectUpdates.read.getLatestUpdates([0n, 5n]);

      assert.equal(updates.length, 5);
      assert.equal(updates[0].link, "https://example.com/update5"); // newest first
      assert.equal(updates[1].link, "https://example.com/update4");
      assert.equal(updates[2].link, "https://example.com/update3");
      assert.equal(updates[3].link, "https://example.com/update2");
      assert.equal(updates[4].link, "https://example.com/update1"); // oldest last
    });

    it("should respect limit parameter", async function () {
      await setupMultipleUpdates();

      const updates = await projectUpdates.read.getLatestUpdates([0n, 3n]);

      assert.equal(updates.length, 3);
      assert.equal(updates[0].link, "https://example.com/update5");
      assert.equal(updates[1].link, "https://example.com/update4");
      assert.equal(updates[2].link, "https://example.com/update3");
    });

    it("should respect offset parameter", async function () {
      await setupMultipleUpdates();

      const updates = await projectUpdates.read.getLatestUpdates([2n, 10n]);

      assert.equal(updates.length, 3);
      assert.equal(updates[0].link, "https://example.com/update3"); // skipped 5 and 4
      assert.equal(updates[1].link, "https://example.com/update2");
      assert.equal(updates[2].link, "https://example.com/update1");
    });

    it("should handle offset and limit together", async function () {
      await setupMultipleUpdates();

      const updates = await projectUpdates.read.getLatestUpdates([1n, 2n]);

      assert.equal(updates.length, 2);
      assert.equal(updates[0].link, "https://example.com/update4"); // skipped 5
      assert.equal(updates[1].link, "https://example.com/update3");
    });

    it("should return empty array when offset >= length", async function () {
      await setupMultipleUpdates();

      const updates = await projectUpdates.read.getLatestUpdates([5n, 10n]);
      assert.equal(updates.length, 0);

      const updates2 = await projectUpdates.read.getLatestUpdates([100n, 10n]);
      assert.equal(updates2.length, 0);
    });

    it("should handle limit larger than available items", async function () {
      await setupMultipleUpdates();

      const updates = await projectUpdates.read.getLatestUpdates([0n, 100n]);
      assert.equal(updates.length, 5);
    });
  }); // getLatestUpdates

  describe("getLatestProjectUpdates", function () {
    async function setupMixedUpdates() {
      // Post updates for TEST_TOKEN
      await impersonateAccount(tokenCreator);
      await projectUpdates.write.postUpdate([TEST_TOKEN, "https://example.com/token1-update1"], {
        account: tokenCreator
      });
      await stopImpersonatingAccount(tokenCreator);

      // Post updates for TEST_TOKEN_2
      await impersonateAccount(tokenCreator2);
      await projectUpdates.write.postUpdate([TEST_TOKEN_2, "https://example.com/token2-update1"], {
        account: tokenCreator2
      });
      await stopImpersonatingAccount(tokenCreator2);

      // More updates for TEST_TOKEN
      await impersonateAccount(tokenCreator);
      await projectUpdates.write.postUpdate([TEST_TOKEN, "https://example.com/token1-update2"], {
        account: tokenCreator
      });
      await projectUpdates.write.postUpdate([TEST_TOKEN, "https://example.com/token1-update3"], {
        account: tokenCreator
      });
      await stopImpersonatingAccount(tokenCreator);

      // More updates for TEST_TOKEN_2
      await impersonateAccount(tokenCreator2);
      await projectUpdates.write.postUpdate([TEST_TOKEN_2, "https://example.com/token2-update2"], {
        account: tokenCreator2
      });
      await stopImpersonatingAccount(tokenCreator2);
    }

    it("should return empty array for token with no updates", async function () {
      const updates = await projectUpdates.read.getLatestProjectUpdates([TEST_TOKEN, 0n, 10n]);
      assert.equal(updates.length, 0);
    });

    it("should return only updates for specified token", async function () {
      await setupMixedUpdates();

      const token1Updates = await projectUpdates.read.getLatestProjectUpdates([TEST_TOKEN, 0n, 10n]);
      const token2Updates = await projectUpdates.read.getLatestProjectUpdates([TEST_TOKEN_2, 0n, 10n]);

      assert.equal(token1Updates.length, 3);
      assert.equal(token2Updates.length, 2);

      // Verify all updates belong to correct token
      for (const update of token1Updates) {
        assert.equal(update.tokenAddress.toLowerCase(), TEST_TOKEN.toLowerCase());
      }
      for (const update of token2Updates) {
        assert.equal(update.tokenAddress.toLowerCase(), TEST_TOKEN_2.toLowerCase());
      }
    });

    it("should return token updates in reverse chronological order", async function () {
      await setupMixedUpdates();

      const updates = await projectUpdates.read.getLatestProjectUpdates([TEST_TOKEN, 0n, 10n]);

      assert.equal(updates.length, 3);
      assert.equal(updates[0].link, "https://example.com/token1-update3"); // newest
      assert.equal(updates[1].link, "https://example.com/token1-update2");
      assert.equal(updates[2].link, "https://example.com/token1-update1"); // oldest
    });

    it("should respect limit parameter", async function () {
      await setupMixedUpdates();

      const updates = await projectUpdates.read.getLatestProjectUpdates([TEST_TOKEN, 0n, 2n]);

      assert.equal(updates.length, 2);
      assert.equal(updates[0].link, "https://example.com/token1-update3");
      assert.equal(updates[1].link, "https://example.com/token1-update2");
    });

    it("should respect offset parameter", async function () {
      await setupMixedUpdates();

      const updates = await projectUpdates.read.getLatestProjectUpdates([TEST_TOKEN, 1n, 10n]);

      assert.equal(updates.length, 2);
      assert.equal(updates[0].link, "https://example.com/token1-update2"); // skipped update3
      assert.equal(updates[1].link, "https://example.com/token1-update1");
    });

    it("should handle offset and limit together", async function () {
      await setupMixedUpdates();

      const updates = await projectUpdates.read.getLatestProjectUpdates([TEST_TOKEN, 1n, 1n]);

      assert.equal(updates.length, 1);
      assert.equal(updates[0].link, "https://example.com/token1-update2");
    });

    it("should return empty array when offset >= token update count", async function () {
      await setupMixedUpdates();

      const updates = await projectUpdates.read.getLatestProjectUpdates([TEST_TOKEN, 3n, 10n]);
      assert.equal(updates.length, 0);

      const updates2 = await projectUpdates.read.getLatestProjectUpdates([TEST_TOKEN, 100n, 10n]);
      assert.equal(updates2.length, 0);
    });

    it("should handle limit larger than available items", async function () {
      await setupMixedUpdates();

      const updates = await projectUpdates.read.getLatestProjectUpdates([TEST_TOKEN, 0n, 100n]);
      assert.equal(updates.length, 3);
    });
  }); // getLatestProjectUpdates

  describe("Count functions", function () {
    it("should return correct total count", async function () {
      assert.equal(await projectUpdates.read.getProjectUpdatesCount(), 0n);

      await impersonateAccount(tokenCreator);
      await projectUpdates.write.postUpdate([TEST_TOKEN, "https://example.com/update1"], { account: tokenCreator });
      await stopImpersonatingAccount(tokenCreator);

      assert.equal(await projectUpdates.read.getProjectUpdatesCount(), 1n);

      await impersonateAccount(tokenCreator2);
      await projectUpdates.write.postUpdate([TEST_TOKEN_2, "https://example.com/update2"], { account: tokenCreator2 });
      await stopImpersonatingAccount(tokenCreator2);

      assert.equal(await projectUpdates.read.getProjectUpdatesCount(), 2n);
    });

    it("should return correct count per token", async function () {
      assert.equal(await projectUpdates.read.getTokenProjectUpdatesCount([TEST_TOKEN]), 0n);
      assert.equal(await projectUpdates.read.getTokenProjectUpdatesCount([TEST_TOKEN_2]), 0n);

      await impersonateAccount(tokenCreator);
      await projectUpdates.write.postUpdate([TEST_TOKEN, "https://example.com/update1"], { account: tokenCreator });
      await projectUpdates.write.postUpdate([TEST_TOKEN, "https://example.com/update2"], { account: tokenCreator });
      await stopImpersonatingAccount(tokenCreator);

      await impersonateAccount(tokenCreator2);
      await projectUpdates.write.postUpdate([TEST_TOKEN_2, "https://example.com/update3"], { account: tokenCreator2 });
      await stopImpersonatingAccount(tokenCreator2);

      assert.equal(await projectUpdates.read.getTokenProjectUpdatesCount([TEST_TOKEN]), 2n);
      assert.equal(await projectUpdates.read.getTokenProjectUpdatesCount([TEST_TOKEN_2]), 1n);
    });

    it("should return zero for unknown token", async function () {
      const unknownToken = "0x1234567890123456789012345678901234567890";
      assert.equal(await projectUpdates.read.getTokenProjectUpdatesCount([unknownToken]), 0n);
    });
  }); // Count functions

  describe("projectUpdates public getter", function () {
    it("should allow direct access to updates by index", async function () {
      await impersonateAccount(tokenCreator);
      await projectUpdates.write.postUpdate([TEST_TOKEN, "https://example.com/update1"], { account: tokenCreator });
      await stopImpersonatingAccount(tokenCreator);

      const update = await projectUpdates.read.projectUpdates([0n]);

      assert.equal(update[0].toLowerCase(), TEST_TOKEN.toLowerCase());
      assert.equal(update[1], "https://example.com/update1");
    });
  }); // projectUpdates public getter
}); // ProjectUpdates
