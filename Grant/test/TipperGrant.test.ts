import { loadFixture, impersonateAccount } from "@nomicfoundation/hardhat-toolbox-viem/network-helpers";
import { expect } from "chai";
import hre, { ignition } from "hardhat";
import { getAddress, parseEther, getContract } from "viem";
import { HUNT_BASE_ADDRESS } from "./utils";
import { abi as ERC20_ABI } from "@openzeppelin/contracts/build/contracts/ERC20.json";
import TipperGrantModule from "../ignition/modules/TipperGrant";
import { MerkleTree } from "merkletreejs";
import keccak256 from "keccak256";

// NOTE: hardhat-chai-matchers is not officially supported yet, so adding a custom npm package here
// REF: https://github.com/NomicFoundation/hardhat/issues/4874
require("hardhat-chai-matchers-viem");

const INITIAL_HUNT_BALANCE = parseEther("100000");

function bufferToHex(x: Buffer) {
  return `0x${x.toString("hex")}`;
}

async function setupMerkleTree(wallets: string[], amounts: bigint[]) {
  const leaves = wallets.map((wallet, index) =>
    // Take out '0x' prefix from address to match `abi.encodePacked` behavior
    keccak256(Buffer.concat([Buffer.from(wallet.slice(2), "hex"), Buffer.from(amounts[index].toString())]))
  );
  const merkleTree = new MerkleTree(leaves, keccak256, { sortPairs: true });

  return { merkleTree, merkleRoot: merkleTree.getRoot() };
}

function getProof(tree: MerkleTree, address: string, amount: bigint) {
  // Take out '0x' prefix from address to match `abi.encodePacked` behavior
  const leaf = keccak256(Buffer.concat([Buffer.from(address.slice(2), "hex"), Buffer.from(amount.toString())]));

  return tree.getProof(leaf).map((x) => bufferToHex(x.data));
}

describe("TipperGrant", function () {
  async function deployFixtures() {
    const [owner, alice, bob, carol] = await hre.viem.getWalletClients();
    const { tipperGrant } = await ignition.deploy(TipperGrantModule, {
      parameters: {
        TipperGrant: {
          huntToken: HUNT_BASE_ADDRESS
        }
      }
    });

    const impersonatedAddress = "0xCB3f3e0E992435390e686D7b638FCb8baBa6c5c7";
    await impersonateAccount(impersonatedAddress);
    const huntToken = getContract({
      address: HUNT_BASE_ADDRESS,
      abi: ERC20_ABI,
      client: owner
    });
    await huntToken.write.transfer([owner.account.address, INITIAL_HUNT_BALANCE], {
      account: impersonatedAddress
    });

    return { tipperGrant, huntToken, owner, alice, bob, carol };
  }

  let tipperGrant: any, huntToken: any, owner: any, alice: any, bob: any, carol: any;

  beforeEach(async function () {
    ({ tipperGrant, huntToken, owner, alice, bob, carol } = await loadFixture(deployFixtures));
  });

  async function approveAndDeposit(amount: bigint) {
    await huntToken.write.approve([tipperGrant.address, amount]);
    await tipperGrant.write.deposit([amount]);
  }

  describe("Deployment", function () {
    it("should set the lastSeason to 0", async function () {
      expect(await tipperGrant.read.lastSeason()).to.equal(0);
    });

    it("should set the HUNT token address correctly", async function () {
      expect(await tipperGrant.read.HUNT()).to.equal(HUNT_BASE_ADDRESS);
    });
  });

  describe("Deposit and withdraw", function () {
    const DEPOSIT_AMOUNT = parseEther("16000");

    beforeEach(async function () {
      await approveAndDeposit(DEPOSIT_AMOUNT);
    });

    it("should deposit the correct amount", async function () {
      expect(await huntToken.read.balanceOf([tipperGrant.address])).to.equal(DEPOSIT_AMOUNT);
    });

    it("should be able to emergency withdraw by owner", async function () {
      const originalBalance = await huntToken.read.balanceOf([owner.account.address]);
      await tipperGrant.write.emergencyWithdraw();
      expect(await huntToken.read.balanceOf([tipperGrant.address])).to.equal(0n);
      expect(await huntToken.read.balanceOf([owner.account.address])).to.equal(originalBalance + DEPOSIT_AMOUNT);
    });

    it("should not be able to emergency withdraw by non-owner", async function () {
      await expect(tipperGrant.write.emergencyWithdraw([], { account: alice.account })).to.be.rejectedWith(
        "OwnableUnauthorizedAccount"
      );
    });

    it("should emit Deposit event on deposit", async function () {
      await huntToken.write.approve([tipperGrant.address, DEPOSIT_AMOUNT]);
      await expect(tipperGrant.write.deposit([DEPOSIT_AMOUNT]))
        .to.emit(tipperGrant, "Deposit")
        .withArgs(getAddress(owner.account.address), DEPOSIT_AMOUNT);
    });

    it("should emit EmergencyWithdraw event on emergency withdraw", async function () {
      await expect(tipperGrant.write.emergencyWithdraw())
        .to.emit(tipperGrant, "EmergencyWithdraw")
        .withArgs(getAddress(owner.account.address), DEPOSIT_AMOUNT);
    });
  });

  describe("Grant Data and Claim", function () {
    const SEASON_ID = 1;
    let WALLETS: string[];
    const GRANT_AMOUNTS = [parseEther("10000"), parseEther("4000"), parseEther("2000")];
    const DEPOSIT_AMOUNT = GRANT_AMOUNTS.reduce((a, b) => a + b, 0n);
    async function setGrantData() {
      const { merkleTree, merkleRoot } = await setupMerkleTree(WALLETS, GRANT_AMOUNTS);
      await tipperGrant.write.setGrantData([SEASON_ID, GRANT_AMOUNTS.length, DEPOSIT_AMOUNT, bufferToHex(merkleRoot)]);

      return { merkleTree, merkleRoot };
    }

    beforeEach(async function () {
      WALLETS = [getAddress(alice.account.address), getAddress(bob.account.address), getAddress(carol.account.address)];
      await approveAndDeposit(DEPOSIT_AMOUNT);
    });

    describe("Set Grant Data", function () {
      it("should set grant data correctly", async function () {
        await setGrantData();
        const [walletCount, totalGrantClaimed, totalGrant] = await tipperGrant.read.getSeasonStats([SEASON_ID]);
        expect(walletCount).to.equal(GRANT_AMOUNTS.length);
        expect(totalGrantClaimed).to.equal(0);
        expect(totalGrant).to.equal(DEPOSIT_AMOUNT);
      });

      it("should emit SetGrantData event on setting grant data", async function () {
        const { merkleRoot } = await setupMerkleTree(WALLETS, GRANT_AMOUNTS);
        await expect(
          tipperGrant.write.setGrantData([SEASON_ID, GRANT_AMOUNTS.length, DEPOSIT_AMOUNT, bufferToHex(merkleRoot)])
        )
          .to.emit(tipperGrant, "SetGrantData")
          .withArgs(SEASON_ID, GRANT_AMOUNTS.length, bufferToHex(merkleRoot));
      });

      it("should not allow setting grant data for the same season twice", async function () {
        await setGrantData();
        await expect(setGrantData()).to.be.rejectedWith("SeasonDataAlreadyExists");
      });

      it("should not allow setting grant data with invalid season id", async function () {
        const { merkleRoot } = await setupMerkleTree(WALLETS, GRANT_AMOUNTS);
        await expect(
          tipperGrant.write.setGrantData([0, GRANT_AMOUNTS.length, DEPOSIT_AMOUNT, bufferToHex(merkleRoot)])
        ).to.be.rejectedWith("InvalidSeasonId");
      });

      it("should not allow setting grant data with insufficient balance", async function () {
        const { merkleRoot } = await setupMerkleTree(
          WALLETS,
          GRANT_AMOUNTS.map((amount) => amount * 10n)
        );
        await expect(
          tipperGrant.write.setGrantData([
            SEASON_ID,
            GRANT_AMOUNTS.length,
            DEPOSIT_AMOUNT * 10n,
            bufferToHex(merkleRoot)
          ])
        ).to.be.rejectedWith("NotEnoughGrantBalance");
      });

      describe("Claim", function () {
        beforeEach(async function () {
          const { merkleTree } = await setGrantData();
          this.merkleTree = merkleTree;
        });

        it.only("should allow claiming grant", async function () {
          const proof = getProof(this.merkleTree, getAddress(alice.account.address), GRANT_AMOUNTS[0]);
          await tipperGrant.write.claim([SEASON_ID, GRANT_AMOUNTS[0], proof], { account: alice.account });
          const claimedAmount = await tipperGrant.read.getClaimedAmount([SEASON_ID, alice.account.address]);
          const aliceBalance = await huntToken.read.balanceOf([alice.account.address]);

          expect(claimedAmount).to.equal(GRANT_AMOUNTS[0]);
          expect(aliceBalance).to.equal(GRANT_AMOUNTS[0]);
        });

        it("should emit Claim event on claiming", async function () {
          const leaf = keccak256(alice.account.address + GRANT_AMOUNTS[0].toString());
          const merkleTree = new MerkleTree([leaf], keccak256, { sortPairs: true });
          const proof = merkleTree.getHexProof(leaf);

          await expect(tipperGrant.write.claim([SEASON_ID, GRANT_AMOUNTS[0], proof], { account: alice.account }))
            .to.emit(tipperGrant, "Claim")
            .withArgs(getAddress(alice.account.address), SEASON_ID, GRANT_AMOUNTS[0]);
        });

        it("should not allow claiming twice", async function () {
          const leaf = keccak256(alice.account.address + GRANT_AMOUNTS[0].toString());
          const merkleTree = new MerkleTree([leaf], keccak256, { sortPairs: true });
          const proof = merkleTree.getHexProof(leaf);

          await tipperGrant.write.claim([SEASON_ID, GRANT_AMOUNTS[0], proof], { account: alice.account });
          await expect(
            tipperGrant.write.claim([SEASON_ID, GRANT_AMOUNTS[0], proof], { account: alice.account })
          ).to.be.rejectedWith("AlreadyClaimed");
        });

        it("should not allow claiming if not a winner", async function () {
          const leaf = keccak256(owner.account.address + GRANT_AMOUNTS[0].toString());
          const merkleTree = new MerkleTree([leaf], keccak256, { sortPairs: true });
          const proof = merkleTree.getHexProof(leaf);

          await expect(
            tipperGrant.write.claim([SEASON_ID, GRANT_AMOUNTS[0], proof], { account: owner.account })
          ).to.be.rejectedWith("InvalidMerkleProof");
        });
      }); // Claim
    }); // Set Grant Data
  });

  describe("Test the limit of grant data", function () {
    const SEASON_ID = 1;
    const WALLET_COUNT = 100;
    const WALLETS = Array.from({ length: WALLET_COUNT }, (_, i) => getAddress(`0x${i.toString(16).padStart(40, "0")}`));
    const GRANT_AMOUNTS = Array.from({ length: WALLET_COUNT }, () => parseEther("1"));
    const DEPOSIT_AMOUNT = GRANT_AMOUNTS.reduce((a, b) => a + b, 0n);

    beforeEach(async function () {
      await approveAndDeposit(DEPOSIT_AMOUNT);
    });

    it("should set grant data correctly", async function () {
      const { merkleRoot } = await setupMerkleTree(WALLETS, GRANT_AMOUNTS);
      await tipperGrant.write.setGrantData([SEASON_ID, WALLET_COUNT, DEPOSIT_AMOUNT, bufferToHex(merkleRoot)]);
    });
  });
});
