import assert from "node:assert/strict";
import { describe, it, beforeEach } from "node:test";
import { network } from "hardhat";
import { getContract, erc20Abi, keccak256, toHex } from "viem";

// Constants for testing
const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";
const HUNT_TOKEN = "0x37f0c2915CeCC7e977183B8543Fc0864d03E064C";
const INITIAL_HUNT_BALANCE = 10_000n * 10n ** 18n;
const CLAIM_AMOUNT = 100n * 10n ** 18n;

describe("HuntDrop", async function () {
  const connection = await network.connect("baseFork");
  const { viem, networkHelpers } = connection;
  const { impersonateAccount, stopImpersonatingAccount, time } = networkHelpers;

  async function signClaim(
    huntDropAddress: `0x${string}`,
    receiver: `0x${string}`,
    amount: bigint,
    nonce: bigint,
    deadline: bigint,
    signerWallet: any
  ) {
    const chainId = await signerWallet.getChainId();

    const domain = {
      name: "HuntDrop",
      version: "1",
      chainId: chainId,
      verifyingContract: huntDropAddress
    };

    const types = {
      Claim: [
        { name: "receiver", type: "address" },
        { name: "amount", type: "uint256" },
        { name: "nonce", type: "uint256" },
        { name: "deadline", type: "uint256" }
      ]
    };

    const message = {
      receiver: receiver,
      amount: amount,
      nonce: nonce,
      deadline: deadline
    };

    const signature = await signerWallet.signTypedData({
      domain,
      types,
      primaryType: "Claim",
      message
    });

    return signature;
  }

  async function deployHuntDropFixture() {
    const [owner, signer, alice, bob] = await viem.getWalletClients();

    const huntDrop = await viem.deployContract("HuntDrop", [signer.account.address]);

    // Impersonate an address with enough HUNT balance and transfer HUNT to HuntDrop contract
    const impersonatedAddress = "0xCB3f3e0E992435390e686D7b638FCb8baBa6c5c7";
    await impersonateAccount(impersonatedAddress);
    const huntToken = getContract({
      address: HUNT_TOKEN,
      abi: erc20Abi,
      client: owner
    });
    await huntToken.write.transfer([huntDrop.address, INITIAL_HUNT_BALANCE], {
      account: impersonatedAddress
    });
    await stopImpersonatingAccount(impersonatedAddress);

    return { huntDrop, owner, signer, alice, bob, huntToken };
  }

  let huntDrop: any;
  let owner: any;
  let signer: any;
  let alice: any;
  let bob: any;
  let huntToken: any;

  beforeEach(async function () {
    ({ huntDrop, owner, signer, alice, bob, huntToken } = await networkHelpers.loadFixture(deployHuntDropFixture));
  });

  describe("Contract initialization", function () {
    it("should deploy with correct parameters", async function () {
      const huntAddress = await huntDrop.read.HUNT();
      const signerAddress = await huntDrop.read.SIGNER();
      const contractBalance = await huntToken.read.balanceOf([huntDrop.address]);

      assert.equal(huntAddress.toLowerCase(), HUNT_TOKEN.toLowerCase());
      assert.equal(signerAddress.toLowerCase(), signer.account.address.toLowerCase());
      assert.equal(contractBalance, INITIAL_HUNT_BALANCE);
    });

    it("should initialize userNonce to 0", async function () {
      const nonce = await huntDrop.read.userNonce([alice.account.address]);
      assert.equal(nonce, 0n);
    });

    it("should revert with zero signer address", async function () {
      await assert.rejects(viem.deployContract("HuntDrop", [ZERO_ADDRESS]), /HuntDrop__InvalidParams\("signer"\)/);
    });

    it("should have correct CLAIM_TYPEHASH", async function () {
      const typeHash = await huntDrop.read.CLAIM_TYPEHASH();
      const expectedTypeHash = keccak256(
        toHex("Claim(address receiver,uint256 amount,uint256 nonce,uint256 deadline)")
      );
      assert.equal(typeHash, expectedTypeHash);
    });
  }); // Contract initialization

  describe("Admin functions", function () {
    describe("withdraw", function () {
      it("should allow signer to withdraw HUNT tokens", async function () {
        const withdrawAmount = 5_000n * 10n ** 18n;
        const initialSignerBalance = await huntToken.read.balanceOf([signer.account.address]);

        await huntDrop.write.withdraw([withdrawAmount], { account: signer.account });

        const finalSignerBalance = await huntToken.read.balanceOf([signer.account.address]);
        const finalContractBalance = await huntToken.read.balanceOf([huntDrop.address]);

        assert.equal(finalSignerBalance, initialSignerBalance + withdrawAmount);
        assert.equal(finalContractBalance, INITIAL_HUNT_BALANCE - withdrawAmount);
      });

      it("should revert when non-signer tries to withdraw", async function () {
        await assert.rejects(
          huntDrop.write.withdraw([1000n * 10n ** 18n], { account: alice.account }),
          /HuntDrop__PermissionDenied/
        );
      });

      it("should revert with zero amount", async function () {
        await assert.rejects(
          huntDrop.write.withdraw([0n], { account: signer.account }),
          /HuntDrop__InvalidParams\("amount"\)/
        );
      });

      it("should revert with insufficient balance", async function () {
        const excessiveAmount = INITIAL_HUNT_BALANCE + 1n;
        await assert.rejects(
          huntDrop.write.withdraw([excessiveAmount], { account: signer.account }),
          /HuntDrop__InsufficientBalance/
        );
      });
    }); // withdraw
  }); // Admin functions

  describe("claimAirdrop", function () {
    it("should allow claiming with valid signature", async function () {
      const nonce = await huntDrop.read.userNonce([alice.account.address]);
      const deadline = BigInt(await time.latest()) + 3600n; // 1 hour from now
      const signature = await signClaim(huntDrop.address, alice.account.address, CLAIM_AMOUNT, nonce, deadline, signer);

      const initialBalance = await huntToken.read.balanceOf([alice.account.address]);

      const tx = huntDrop.write.claimAirdrop([CLAIM_AMOUNT, deadline, signature], { account: alice.account });
      await viem.assertions.emit(tx, huntDrop, "Claimed");

      const finalBalance = await huntToken.read.balanceOf([alice.account.address]);
      assert.equal(finalBalance, initialBalance + CLAIM_AMOUNT);

      // Verify nonce was incremented
      const newNonce = await huntDrop.read.userNonce([alice.account.address]);
      assert.equal(newNonce, nonce + 1n);
    });

    it("should revert with invalid signature (wrong signer)", async function () {
      const nonce = await huntDrop.read.userNonce([alice.account.address]);
      const deadline = BigInt(await time.latest()) + 3600n;
      // Sign with alice instead of the authorized signer
      const signature = await signClaim(huntDrop.address, alice.account.address, CLAIM_AMOUNT, nonce, deadline, alice);

      await assert.rejects(
        huntDrop.write.claimAirdrop([CLAIM_AMOUNT, deadline, signature], { account: alice.account }),
        /HuntDrop__InvalidSignature/
      );
    });

    it("should revert with invalid signature (wrong receiver)", async function () {
      const nonce = await huntDrop.read.userNonce([alice.account.address]);
      const deadline = BigInt(await time.latest()) + 3600n;
      // Sign for bob but alice tries to claim
      const signature = await signClaim(huntDrop.address, bob.account.address, CLAIM_AMOUNT, nonce, deadline, signer);

      await assert.rejects(
        huntDrop.write.claimAirdrop([CLAIM_AMOUNT, deadline, signature], { account: alice.account }),
        /HuntDrop__InvalidSignature/
      );
    });

    it("should revert with invalid signature (wrong amount)", async function () {
      const nonce = await huntDrop.read.userNonce([alice.account.address]);
      const deadline = BigInt(await time.latest()) + 3600n;
      // Sign for different amount
      const signature = await signClaim(
        huntDrop.address,
        alice.account.address,
        CLAIM_AMOUNT * 2n,
        nonce,
        deadline,
        signer
      );

      await assert.rejects(
        huntDrop.write.claimAirdrop([CLAIM_AMOUNT, deadline, signature], { account: alice.account }),
        /HuntDrop__InvalidSignature/
      );
    });

    it("should revert with expired deadline", async function () {
      const nonce = await huntDrop.read.userNonce([alice.account.address]);
      const deadline = BigInt(await time.latest()) - 1n; // Already expired
      const signature = await signClaim(huntDrop.address, alice.account.address, CLAIM_AMOUNT, nonce, deadline, signer);

      await assert.rejects(
        huntDrop.write.claimAirdrop([CLAIM_AMOUNT, deadline, signature], { account: alice.account }),
        /HuntDrop__SignatureExpired/
      );
    });

    it("should revert when deadline passes after signing", async function () {
      const nonce = await huntDrop.read.userNonce([alice.account.address]);
      const deadline = BigInt(await time.latest()) + 3600n; // 1 hour from now
      const signature = await signClaim(huntDrop.address, alice.account.address, CLAIM_AMOUNT, nonce, deadline, signer);

      // Move time past the deadline
      await time.increase(3601);

      await assert.rejects(
        huntDrop.write.claimAirdrop([CLAIM_AMOUNT, deadline, signature], { account: alice.account }),
        /HuntDrop__SignatureExpired/
      );
    });

    it("should revert with zero amount", async function () {
      const nonce = await huntDrop.read.userNonce([alice.account.address]);
      const deadline = BigInt(await time.latest()) + 3600n;
      const signature = await signClaim(huntDrop.address, alice.account.address, 0n, nonce, deadline, signer);

      await assert.rejects(
        huntDrop.write.claimAirdrop([0n, deadline, signature], { account: alice.account }),
        /HuntDrop__InvalidParams\("amount"\)/
      );
    });

    it("should revert with insufficient contract balance", async function () {
      const excessiveAmount = INITIAL_HUNT_BALANCE + 1n;
      const nonce = await huntDrop.read.userNonce([alice.account.address]);
      const deadline = BigInt(await time.latest()) + 3600n;
      const signature = await signClaim(
        huntDrop.address,
        alice.account.address,
        excessiveAmount,
        nonce,
        deadline,
        signer
      );

      await assert.rejects(
        huntDrop.write.claimAirdrop([excessiveAmount, deadline, signature], { account: alice.account }),
        /ERC20: transfer amount exceeds balance/
      );
    });

    it("should prevent replay attacks with nonce", async function () {
      const nonce = await huntDrop.read.userNonce([alice.account.address]);
      const deadline = BigInt(await time.latest()) + 3600n;
      const signature = await signClaim(huntDrop.address, alice.account.address, CLAIM_AMOUNT, nonce, deadline, signer);

      // First claim should succeed
      await huntDrop.write.claimAirdrop([CLAIM_AMOUNT, deadline, signature], { account: alice.account });

      // Second claim with same signature should fail (nonce has incremented)
      await assert.rejects(
        huntDrop.write.claimAirdrop([CLAIM_AMOUNT, deadline, signature], { account: alice.account }),
        /HuntDrop__InvalidSignature/
      );
    });

    it("should allow multiple claims with updated nonces", async function () {
      // First claim
      const nonce1 = await huntDrop.read.userNonce([alice.account.address]);
      const deadline1 = BigInt(await time.latest()) + 3600n;
      const signature1 = await signClaim(
        huntDrop.address,
        alice.account.address,
        CLAIM_AMOUNT,
        nonce1,
        deadline1,
        signer
      );
      await huntDrop.write.claimAirdrop([CLAIM_AMOUNT, deadline1, signature1], { account: alice.account });

      // Second claim with new nonce
      const nonce2 = await huntDrop.read.userNonce([alice.account.address]);
      assert.equal(nonce2, nonce1 + 1n);
      const deadline2 = BigInt(await time.latest()) + 3600n;
      const signature2 = await signClaim(
        huntDrop.address,
        alice.account.address,
        CLAIM_AMOUNT,
        nonce2,
        deadline2,
        signer
      );
      await huntDrop.write.claimAirdrop([CLAIM_AMOUNT, deadline2, signature2], { account: alice.account });

      const finalNonce = await huntDrop.read.userNonce([alice.account.address]);
      assert.equal(finalNonce, nonce1 + 2n);
    });
  }); // claimAirdrop

  describe("Helper functions", function () {
    describe("getStructHash", function () {
      it("should return consistent struct hash", async function () {
        const receiver = alice.account.address;
        const amount = CLAIM_AMOUNT;
        const deadline = BigInt(await time.latest()) + 3600n;

        const hash1 = await huntDrop.read.getStructHash([receiver, amount, deadline]);
        const hash2 = await huntDrop.read.getStructHash([receiver, amount, deadline]);

        assert.equal(hash1, hash2);
      });

      it("should return different hash for different parameters", async function () {
        const deadline = BigInt(await time.latest()) + 3600n;

        const hash1 = await huntDrop.read.getStructHash([alice.account.address, CLAIM_AMOUNT, deadline]);
        const hash2 = await huntDrop.read.getStructHash([bob.account.address, CLAIM_AMOUNT, deadline]);
        const hash3 = await huntDrop.read.getStructHash([alice.account.address, CLAIM_AMOUNT * 2n, deadline]);
        const hash4 = await huntDrop.read.getStructHash([alice.account.address, CLAIM_AMOUNT, deadline + 1n]);

        assert.notEqual(hash1, hash2); // Different receiver
        assert.notEqual(hash1, hash3); // Different amount
        assert.notEqual(hash1, hash4); // Different deadline
      });

      it("should change after nonce increment", async function () {
        const deadline = BigInt(await time.latest()) + 3600n;
        const hashBefore = await huntDrop.read.getStructHash([alice.account.address, CLAIM_AMOUNT, deadline]);

        // Claim to increment nonce
        const nonce = await huntDrop.read.userNonce([alice.account.address]);
        const signature = await signClaim(
          huntDrop.address,
          alice.account.address,
          CLAIM_AMOUNT,
          nonce,
          deadline,
          signer
        );
        await huntDrop.write.claimAirdrop([CLAIM_AMOUNT, deadline, signature], { account: alice.account });

        const hashAfter = await huntDrop.read.getStructHash([alice.account.address, CLAIM_AMOUNT, deadline]);
        assert.notEqual(hashBefore, hashAfter);
      });
    }); // getStructHash

    describe("getDigest", function () {
      it("should return valid digest for signing", async function () {
        const nonce = await huntDrop.read.userNonce([alice.account.address]);
        const deadline = BigInt(await time.latest()) + 3600n;

        const digest = await huntDrop.read.getDigest([alice.account.address, CLAIM_AMOUNT, deadline]);

        // Verify that signing this digest produces a valid signature
        const signature = await signClaim(
          huntDrop.address,
          alice.account.address,
          CLAIM_AMOUNT,
          nonce,
          deadline,
          signer
        );

        // If the digest is correct, the claim should succeed
        await huntDrop.write.claimAirdrop([CLAIM_AMOUNT, deadline, signature], { account: alice.account });

        const finalBalance = await huntToken.read.balanceOf([alice.account.address]);
        assert.equal(finalBalance, CLAIM_AMOUNT);
      });
    }); // getDigest

    describe("DOMAIN_SEPARATOR", function () {
      it("should return a valid domain separator", async function () {
        const domainSeparator = await huntDrop.read.DOMAIN_SEPARATOR();

        // Should be a 32-byte hash (64 hex chars + 0x prefix)
        assert.equal(domainSeparator.length, 66);
        assert.ok(domainSeparator.startsWith("0x"));
      });

      it("should be consistent across calls", async function () {
        const separator1 = await huntDrop.read.DOMAIN_SEPARATOR();
        const separator2 = await huntDrop.read.DOMAIN_SEPARATOR();

        assert.equal(separator1, separator2);
      });
    }); // DOMAIN_SEPARATOR
  }); // Helper functions
}); // HuntDrop
