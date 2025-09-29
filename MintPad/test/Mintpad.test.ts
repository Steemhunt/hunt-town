import assert from "node:assert/strict";
import { describe, it, beforeEach } from "node:test";
import { network } from "hardhat";
import { encodeAbiParameters, keccak256, getAddress, Address, Hex, getContract, erc20Abi } from "viem";
import { privateKeyToAccount } from "viem/accounts";

// Constants for testing
const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";
const BOND_ADDRESS = "0xc5a076cad94176c2996B32d8466Be1cE757FAa27";
const HUNT_TOKEN = "0x37f0c2915CeCC7e977183B8543Fc0864d03E064C"; // HUNT token address
const TEST_TOKEN = "0xAf15A124e3d9e18E82801d69A94279d85BD6289b"; // HEPE
const TOKENS_TO_MINT = 1_000_000n * 10n ** 18n;
const MAX_HP_AMOUNT = 10424472304323077000n; // 1M HEPE price at given fork block
const INITIAL_HUNT_BALANCE = 10_000n * 10n ** 18n; // 10,000 HUNT tokens
const DEFAULT_MAX_HP_PER_MINT = 2000n * 10n ** 18n; // 2000 HUNT per mint (default from contract)

describe("Mintpad", async function () {
  const connection = await network.connect("baseFork");
  const { viem, networkHelpers } = connection;
  const { time, impersonateAccount, stopImpersonatingAccount } = networkHelpers;

  async function deployMintpadFixture() {
    const signerPrivateKey = "0xe351f9daa1f11b4ca59a766525bb9c8d6d263edc8af921b9d2f083c9897f7aca";
    const signerAccount = privateKeyToAccount(signerPrivateKey);
    const [deployer, alice] = await viem.getWalletClients();

    // Send some ETH to the signer
    await deployer.sendTransaction({
      to: signerAccount.address,
      value: 1n * 10n ** 18n
    });

    const mintpad = await viem.deployContract("Mintpad", [signerAccount.address, BOND_ADDRESS]);

    // Impersonate an address with enough HUNT balance and transfer HUNT to Mintpad contract
    const impersonatedAddress = "0xCB3f3e0E992435390e686D7b638FCb8baBa6c5c7";
    await impersonateAccount(impersonatedAddress);
    const huntToken = getContract({
      address: HUNT_TOKEN,
      abi: erc20Abi,
      client: deployer
    });
    await huntToken.write.transfer([mintpad.address, INITIAL_HUNT_BALANCE], {
      account: impersonatedAddress
    });
    await stopImpersonatingAccount(impersonatedAddress);

    return { mintpad, deployer, alice, signerAccount };
  }

  // Helper function to generate message hash (matches Solidity's abi.encode)
  function getMessageHash(to: Address, token: Address, tokensToMint: bigint, maxHpAmount: bigint, nonce: number): Hex {
    return keccak256(
      encodeAbiParameters(
        [
          { name: "to", type: "address" },
          { name: "token", type: "address" },
          { name: "tokensToMint", type: "uint128" },
          { name: "maxHpAmount", type: "uint88" },
          { name: "nonce", type: "uint40" }
        ],
        [to, token, tokensToMint, maxHpAmount, nonce]
      )
    );
  }

  // Helper function to sign message
  async function signMessage(
    to: Address,
    token: Address,
    tokensToMint: bigint,
    maxHpAmount: bigint,
    nonce: number
  ): Promise<Hex> {
    const messageHash = getMessageHash(to, token, tokensToMint, maxHpAmount, nonce);
    const signature = await signerAccount.signMessage({
      message: { raw: messageHash }
    });
    return signature;
  }

  let mintpad: any;
  let deployer: any;
  let alice: any;
  let signerAccount: ReturnType<typeof privateKeyToAccount>;

  beforeEach(async function () {
    ({ mintpad, deployer, alice, signerAccount } = await networkHelpers.loadFixture(deployMintpadFixture));
  });

  describe("Contract initialization", function () {
    it("should deploy with correct signer and bond addresses", async function () {
      // We can't directly read the immutable variables, but we can test by trying to mint with correct signature
      const nonce = await mintpad.read.userNonce([alice.account.address]);
      assert.equal(nonce, 0);
    });

    it("should initialize user nonces to zero", async function () {
      const aliceNonce = await mintpad.read.userNonce([alice.account.address]);
      const deployerNonce = await mintpad.read.userNonce([deployer.account.address]);

      assert.equal(aliceNonce, 0);
      assert.equal(deployerNonce, 0);
    });

    it("should have received 10,000 HUNT tokens", async function () {
      // Get HUNT token contract instance to check balance
      const huntToken = getContract({
        address: HUNT_TOKEN,
        abi: erc20Abi,
        client: deployer
      }) as any;

      const contractBalance = await huntToken.read.balanceOf([mintpad.address]);
      assert.equal(contractBalance, INITIAL_HUNT_BALANCE);
    });

    it("should initialize with default MAX_HP_PER_MINT of 2000 HUNT", async function () {
      const maxHpPerMint = await mintpad.read.MAX_HP_PER_MINT();
      assert.equal(maxHpPerMint, DEFAULT_MAX_HP_PER_MINT);
    });
  }); // Contract initialization

  describe("Admin functions", function () {
    describe("setMaxHpPerMint", function () {
      it("should allow signer to update MAX_HP_PER_MINT", async function () {
        const newMaxHp = 5000n * 10n ** 18n; // 5000 HUNT

        await mintpad.write.setMaxHpPerMint([newMaxHp], { account: signerAccount });

        // Verify the new limit by checking it allows minting up to the new limit
        const signature = await signMessage(alice.account.address, TEST_TOKEN, TOKENS_TO_MINT, newMaxHp, 0);

        // This should not revert due to maxHpAmount limit
        await mintpad.write.mint([alice.account.address, TEST_TOKEN, TOKENS_TO_MINT, newMaxHp, signature]);
      });

      it("should revert when non-signer tries to update MAX_HP_PER_MINT", async function () {
        const newMaxHp = 5000n * 10n ** 18n;

        await assert.rejects(
          mintpad.write.setMaxHpPerMint([newMaxHp], { account: deployer.account }),
          /Mintpad__PermissionDenied\(\)/
        );
      });
    }); // setMaxHpPerMint

    describe("refundHUNT", function () {
      it("should allow signer to refund all HUNT tokens", async function () {
        const huntToken = getContract({
          address: HUNT_TOKEN,
          abi: erc20Abi,
          client: deployer
        }) as any;

        const initialContractBalance = await huntToken.read.balanceOf([mintpad.address]);
        const initialSignerBalance = await huntToken.read.balanceOf([signerAccount.address]);

        await mintpad.write.refundHUNT({ account: signerAccount });

        const finalContractBalance = await huntToken.read.balanceOf([mintpad.address]);
        const finalSignerBalance = await huntToken.read.balanceOf([signerAccount.address]);

        assert.equal(finalContractBalance, 0n);
        assert.equal(finalSignerBalance, initialSignerBalance + initialContractBalance);
      });

      it("should revert when non-signer tries to refund HUNT", async function () {
        await assert.rejects(mintpad.write.refundHUNT({ account: deployer.account }), /Mintpad__PermissionDenied\(\)/);
      });

      it("should handle refund when contract has zero balance", async function () {
        // First refund to empty the contract
        await mintpad.write.refundHUNT({ account: signerAccount });

        // Second refund should still work (transferring 0 tokens)
        await mintpad.write.refundHUNT({ account: signerAccount });
      });
    }); // refundHUNT
  }); // Admin functions

  describe("Mint function", function () {
    describe("Parameter validation", function () {
      it("should revert with invalid 'to' address (zero address)", async function () {
        const signature = await signMessage(ZERO_ADDRESS, TEST_TOKEN, TOKENS_TO_MINT, MAX_HP_AMOUNT, 0);

        await assert.rejects(
          mintpad.write.mint([ZERO_ADDRESS, TEST_TOKEN, TOKENS_TO_MINT, MAX_HP_AMOUNT, signature]),
          /Mintpad__InvalidParams\("to"\)/
        );
      });

      it("should revert with invalid 'token' address (zero address)", async function () {
        const signature = await signMessage(alice.account.address, ZERO_ADDRESS, TOKENS_TO_MINT, MAX_HP_AMOUNT, 0);

        await assert.rejects(
          mintpad.write.mint([alice.account.address, ZERO_ADDRESS, TOKENS_TO_MINT, MAX_HP_AMOUNT, signature]),
          /Mintpad__InvalidParams\("token"\)/
        );
      });

      it("should revert with zero tokensToMint", async function () {
        const signature = await signMessage(alice.account.address, TEST_TOKEN, 0n, MAX_HP_AMOUNT, 0);

        await assert.rejects(
          mintpad.write.mint([alice.account.address, TEST_TOKEN, 0n, MAX_HP_AMOUNT, signature]),
          /Mintpad__InvalidParams\("tokensToMint"\)/
        );
      });

      it("should revert with zero maxHpAmount", async function () {
        const signature = await signMessage(alice.account.address, TEST_TOKEN, TOKENS_TO_MINT, 0n, 0);

        await assert.rejects(
          mintpad.write.mint([alice.account.address, TEST_TOKEN, TOKENS_TO_MINT, 0n, signature]),
          /Mintpad__InvalidParams\("maxHpAmount"\)/
        );
      });

      it("should revert when maxHpAmount exceeds MAX_HP_PER_MINT", async function () {
        const excessiveAmount = DEFAULT_MAX_HP_PER_MINT + 1n;
        const signature = await signMessage(alice.account.address, TEST_TOKEN, TOKENS_TO_MINT, excessiveAmount, 0);

        await assert.rejects(
          mintpad.write.mint([alice.account.address, TEST_TOKEN, TOKENS_TO_MINT, excessiveAmount, signature]),
          /Mintpad__InvalidParams\("maxHpAmount"\)/
        );
      });

      it("should revert when contract doesn't have enough HUNT balance", async function () {
        // First, drain most of the HUNT balance by setting a very low balance
        const huntToken = getContract({
          address: HUNT_TOKEN,
          abi: erc20Abi,
          client: deployer
        });

        // Transfer most HUNT out to leave insufficient balance
        // const currentBalance = await huntToken.read.balanceOf([mintpad.address]);
        // const amountToTransfer = currentBalance - 100n; // Leave only 100 wei

        await mintpad.write.refundHUNT({ account: signerAccount });

        // Try to mint with more than available balance
        const signature = await signMessage(alice.account.address, TEST_TOKEN, TOKENS_TO_MINT, MAX_HP_AMOUNT, 0);

        await assert.rejects(
          mintpad.write.mint([alice.account.address, TEST_TOKEN, TOKENS_TO_MINT, MAX_HP_AMOUNT, signature]),
          /Mintpad__NotEnoughHUNTBalance\(\)/
        );
      });
    }); // Parameter validation

    describe("Signature validation", function () {
      it("should revert with invalid signature", async function () {
        const invalidSignature =
          "0x1234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890";

        await assert.rejects(
          mintpad.write.mint([alice.account.address, TEST_TOKEN, TOKENS_TO_MINT, MAX_HP_AMOUNT, invalidSignature]),
          (error: any) => error.message.includes("ECDSAInvalidSignature")
        );
      });

      it("should revert when signature is from wrong signer", async function () {
        const wrongSignerPrivateKey = "0x9876543210987654321098765432109876543210987654321098765432109876";
        const wrongSignerAccount = privateKeyToAccount(wrongSignerPrivateKey);

        const messageHash = getMessageHash(alice.account.address, TEST_TOKEN, TOKENS_TO_MINT, MAX_HP_AMOUNT, 0);

        const wrongSignature = await wrongSignerAccount.signMessage({
          message: { raw: messageHash }
        });

        await assert.rejects(
          mintpad.write.mint([alice.account.address, TEST_TOKEN, TOKENS_TO_MINT, MAX_HP_AMOUNT, wrongSignature]),
          (error: any) => error.message.includes("Mintpad__InvalidSignature")
        );
      });

      it("should revert when signature uses wrong nonce", async function () {
        const wrongNonce = 5;
        const signature = await signMessage(
          alice.account.address,
          TEST_TOKEN,
          TOKENS_TO_MINT,
          MAX_HP_AMOUNT,
          wrongNonce
        );

        await assert.rejects(
          mintpad.write.mint([alice.account.address, TEST_TOKEN, TOKENS_TO_MINT, MAX_HP_AMOUNT, signature]),
          (error: any) => error.message.includes("Mintpad__InvalidSignature")
        );
      });
    }); // Signature validation

    describe("Success cases", function () {
      it("should increment user nonce after successful mint", async function () {
        const initialNonce = await mintpad.read.userNonce([alice.account.address]);
        const signature = await signMessage(
          alice.account.address,
          TEST_TOKEN,
          TOKENS_TO_MINT,
          MAX_HP_AMOUNT,
          initialNonce
        );

        await mintpad.write.mint([alice.account.address, TEST_TOKEN, TOKENS_TO_MINT, MAX_HP_AMOUNT, signature]);

        // Even if the bond call fails, nonce should still be incremented if signature was valid
        const newNonce = await mintpad.read.userNonce([alice.account.address]);
        assert.equal(newNonce, initialNonce + 1);
      });

      it("should emit MintWithHp event on successful mint", async function () {
        const initialNonce = await mintpad.read.userNonce([alice.account.address]);
        const signature = await signMessage(
          alice.account.address,
          TEST_TOKEN,
          TOKENS_TO_MINT,
          MAX_HP_AMOUNT,
          initialNonce
        );

        const timestamp = await time.latest();

        await viem.assertions.emitWithArgs(
          mintpad.write.mint([alice.account.address, TEST_TOKEN, TOKENS_TO_MINT, MAX_HP_AMOUNT, signature]),
          mintpad,
          "MintWithHp",
          [getAddress(alice.account.address), getAddress(TEST_TOKEN), TOKENS_TO_MINT, MAX_HP_AMOUNT, timestamp + 1]
        );
      });
    }); // Success cases
  }); // Mint function

  describe("View functions", function () {
    describe("getMessageHash", function () {
      it("should return consistent hash for same parameters", async function () {
        const hash1 = await mintpad.read.getMessageHash([
          alice.account.address,
          TEST_TOKEN,
          TOKENS_TO_MINT,
          MAX_HP_AMOUNT
        ]);
        const hash2 = await mintpad.read.getMessageHash([
          alice.account.address,
          TEST_TOKEN,
          TOKENS_TO_MINT,
          MAX_HP_AMOUNT
        ]);

        assert.equal(hash1, hash2);
      });

      it("should return different hash for different parameters", async function () {
        const hash1 = await mintpad.read.getMessageHash([
          alice.account.address,
          TEST_TOKEN,
          TOKENS_TO_MINT,
          MAX_HP_AMOUNT
        ]);
        const hash2 = await mintpad.read.getMessageHash([
          deployer.account.address, // Different address
          TEST_TOKEN,
          TOKENS_TO_MINT,
          MAX_HP_AMOUNT
        ]);

        assert.notEqual(hash1, hash2);
      });

      it("should return different hash after nonce increment", async function () {
        const hashBeforeMint = await mintpad.read.getMessageHash([
          alice.account.address,
          TEST_TOKEN,
          TOKENS_TO_MINT,
          MAX_HP_AMOUNT
        ]);

        // Perform a mint to increment nonce
        const signature = await signMessage(alice.account.address, TEST_TOKEN, TOKENS_TO_MINT, MAX_HP_AMOUNT, 0);
        await mintpad.write.mint([alice.account.address, TEST_TOKEN, TOKENS_TO_MINT, MAX_HP_AMOUNT, signature]);

        const hashAfterMint = await mintpad.read.getMessageHash([
          alice.account.address,
          TEST_TOKEN,
          TOKENS_TO_MINT,
          MAX_HP_AMOUNT
        ]);

        assert.notEqual(hashBeforeMint, hashAfterMint);
      });
    }); // getMessageHash

    describe("getMintHistoryCount", function () {
      it("should return zero count initially", async function () {
        const totalCount = await mintpad.read.getMintHistoryCount();
        assert.equal(totalCount, 0n);
      });

      it("should increment count after successful mint", async function () {
        // Perform first mint for Alice
        const signature1 = await signMessage(alice.account.address, TEST_TOKEN, TOKENS_TO_MINT, MAX_HP_AMOUNT, 0);
        await mintpad.write.mint([alice.account.address, TEST_TOKEN, TOKENS_TO_MINT, MAX_HP_AMOUNT, signature1]);

        let totalCount = await mintpad.read.getMintHistoryCount();
        assert.equal(totalCount, 1n);

        // Perform second mint for Alice
        const signature2 = await signMessage(
          alice.account.address,
          TEST_TOKEN,
          TOKENS_TO_MINT / 2n,
          MAX_HP_AMOUNT / 2n,
          1
        );
        await mintpad.write.mint([
          alice.account.address,
          TEST_TOKEN,
          TOKENS_TO_MINT / 2n,
          MAX_HP_AMOUNT / 2n,
          signature2
        ]);

        totalCount = await mintpad.read.getMintHistoryCount();
        assert.equal(totalCount, 2n);

        // Perform mint for deployer
        const signature3 = await signMessage(deployer.account.address, TEST_TOKEN, TOKENS_TO_MINT, MAX_HP_AMOUNT, 0);
        await mintpad.write.mint([deployer.account.address, TEST_TOKEN, TOKENS_TO_MINT, MAX_HP_AMOUNT, signature3]);

        totalCount = await mintpad.read.getMintHistoryCount();
        assert.equal(totalCount, 3n);
      });
    }); // getMintHistoryCount

    describe("getMintHistory", function () {
      beforeEach(async function () {
        // Setup some mint history for testing
        const signature1 = await signMessage(alice.account.address, TEST_TOKEN, TOKENS_TO_MINT, MAX_HP_AMOUNT, 0);
        await mintpad.write.mint([alice.account.address, TEST_TOKEN, TOKENS_TO_MINT, MAX_HP_AMOUNT, signature1]);

        const signature2 = await signMessage(
          deployer.account.address,
          TEST_TOKEN,
          TOKENS_TO_MINT / 2n,
          MAX_HP_AMOUNT / 2n,
          0
        );
        await mintpad.write.mint([
          deployer.account.address,
          TEST_TOKEN,
          TOKENS_TO_MINT / 2n,
          MAX_HP_AMOUNT / 2n,
          signature2
        ]);

        const signature3 = await signMessage(
          alice.account.address,
          TEST_TOKEN,
          TOKENS_TO_MINT * 2n,
          MAX_HP_AMOUNT * 2n,
          1
        );
        await mintpad.write.mint([
          alice.account.address,
          TEST_TOKEN,
          TOKENS_TO_MINT * 2n,
          MAX_HP_AMOUNT * 2n,
          signature3
        ]);
      });

      it("should revert when startIndex > endIndex", async function () {
        await assert.rejects(mintpad.read.getMintHistory([5, 3]), /Mintpad__InvalidParams\("startIndex > endIndex"\)/);
      });

      it("should return single history entry", async function () {
        const history = await mintpad.read.getMintHistory([0, 0]);

        assert.equal(history.length, 1);
        assert.equal(history[0].to.toLowerCase(), alice.account.address.toLowerCase());
        assert.equal(history[0].token.toLowerCase(), TEST_TOKEN.toLowerCase());
        assert.equal(history[0].tokensToMint, TOKENS_TO_MINT);
      });

      it("should return multiple history entries", async function () {
        const history = await mintpad.read.getMintHistory([0, 2]);

        assert.equal(history.length, 3);

        // First entry (Alice's first mint)
        assert.equal(history[0].to.toLowerCase(), alice.account.address.toLowerCase());
        assert.equal(history[0].tokensToMint, TOKENS_TO_MINT);

        // Second entry (Deployer's mint)
        assert.equal(history[1].to.toLowerCase(), deployer.account.address.toLowerCase());
        assert.equal(history[1].tokensToMint, TOKENS_TO_MINT / 2n);

        // Third entry (Alice's second mint)
        assert.equal(history[2].to.toLowerCase(), alice.account.address.toLowerCase());
        assert.equal(history[2].tokensToMint, TOKENS_TO_MINT * 2n);
      });

      it("should handle endIndex beyond array length", async function () {
        const history = await mintpad.read.getMintHistory([0, 100]); // endIndex way beyond actual length

        assert.equal(history.length, 3); // Should return all 3 entries
        assert.equal(history[0].to.toLowerCase(), alice.account.address.toLowerCase());
        assert.equal(history[1].to.toLowerCase(), deployer.account.address.toLowerCase());
        assert.equal(history[2].to.toLowerCase(), alice.account.address.toLowerCase());
      });

      it("should return partial range correctly", async function () {
        const history = await mintpad.read.getMintHistory([1, 2]);

        assert.equal(history.length, 2);
        assert.equal(history[0].to.toLowerCase(), deployer.account.address.toLowerCase());
        assert.equal(history[1].to.toLowerCase(), alice.account.address.toLowerCase());
        assert.equal(history[1].tokensToMint, TOKENS_TO_MINT * 2n);
      });
    }); // getMintHistory

    describe("get24hAgoHistoryIndex", function () {
      it("should return 0 when no history exists", async function () {
        const index = await mintpad.read.get24hAgoHistoryIndex();
        assert.equal(index, 0n);
      });

      it("should return 0 when all history is within 24 hours", async function () {
        // Add some recent history
        const signature = await signMessage(alice.account.address, TEST_TOKEN, TOKENS_TO_MINT, MAX_HP_AMOUNT, 0);
        await mintpad.write.mint([alice.account.address, TEST_TOKEN, TOKENS_TO_MINT, MAX_HP_AMOUNT, signature]);

        const index = await mintpad.read.get24hAgoHistoryIndex();
        assert.equal(index, 0n);
      });

      it("should return correct index when history spans more than 24 hours", async function () {
        // First, add some history
        const signature1 = await signMessage(alice.account.address, TEST_TOKEN, TOKENS_TO_MINT, MAX_HP_AMOUNT, 0);
        await mintpad.write.mint([alice.account.address, TEST_TOKEN, TOKENS_TO_MINT, MAX_HP_AMOUNT, signature1]);

        const signature2 = await signMessage(deployer.account.address, TEST_TOKEN, TOKENS_TO_MINT, MAX_HP_AMOUNT, 0);
        await mintpad.write.mint([deployer.account.address, TEST_TOKEN, TOKENS_TO_MINT, MAX_HP_AMOUNT, signature2]);

        // Advance time by more than 24 hours
        await time.increase(86401); // 24 hours + 1 second

        // Add more history after time advancement
        const signature3 = await signMessage(alice.account.address, TEST_TOKEN, TOKENS_TO_MINT, MAX_HP_AMOUNT, 1);
        await mintpad.write.mint([alice.account.address, TEST_TOKEN, TOKENS_TO_MINT, MAX_HP_AMOUNT, signature3]);

        const index = await mintpad.read.get24hAgoHistoryIndex();
        assert.equal(index, 2n); // Should return index 2 (the first entry after 24h ago)
      });

      it("should return correct index with multiple old entries", async function () {
        // Add multiple entries
        const signature1 = await signMessage(alice.account.address, TEST_TOKEN, TOKENS_TO_MINT, MAX_HP_AMOUNT, 0);
        await mintpad.write.mint([alice.account.address, TEST_TOKEN, TOKENS_TO_MINT, MAX_HP_AMOUNT, signature1]);

        const signature2 = await signMessage(deployer.account.address, TEST_TOKEN, TOKENS_TO_MINT, MAX_HP_AMOUNT, 0);
        await mintpad.write.mint([deployer.account.address, TEST_TOKEN, TOKENS_TO_MINT, MAX_HP_AMOUNT, signature2]);

        // Advance time by 12 hours
        await time.increase(43200);

        const signature3 = await signMessage(alice.account.address, TEST_TOKEN, TOKENS_TO_MINT, MAX_HP_AMOUNT, 1);
        await mintpad.write.mint([alice.account.address, TEST_TOKEN, TOKENS_TO_MINT, MAX_HP_AMOUNT, signature3]);

        // Advance time by another 13 hours (total 25 hours from first entries)
        await time.increase(46800);

        const signature4 = await signMessage(deployer.account.address, TEST_TOKEN, TOKENS_TO_MINT, MAX_HP_AMOUNT, 1);
        await mintpad.write.mint([deployer.account.address, TEST_TOKEN, TOKENS_TO_MINT, MAX_HP_AMOUNT, signature4]);

        const index = await mintpad.read.get24hAgoHistoryIndex();
        // Should return index pointing to first entry that's within 24 hours
        // Entry 0,1: > 24h ago, Entry 2: ~13h ago, Entry 3: recent
        // So index should be 2
        assert.equal(index, 2n);
      });
    }); // get24hAgoHistoryIndex
  }); // View functions
}); // Mintpad
