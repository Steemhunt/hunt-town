import assert from "node:assert/strict";
import { describe, it, beforeEach } from "node:test";
import { network } from "hardhat";
import { getContract, erc20Abi, parseEther, parseUnits } from "viem";

// ============ Constants ============
const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";

// Contract addresses (Base Mainnet)
const BOND_ADDRESS = "0xc5a076cad94176c2996B32d8466Be1cE757FAa27";
const BOND_PERIPHERY_ADDRESS = "0x492C412369Db76C9cdD9939e6C521579301473a3";

// Token addresses
const HUNT = "0x37f0c2915CeCC7e977183B8543Fc0864d03E064C";
const MT = "0xFf45161474C39cB00699070Dd49582e417b57a7E";
const USDC = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";
const CHILD_TOKEN = "0xDF2B673Ec06d210C8A8Be89441F8de60B5C679c9"; // SIGNET

// Whale address (has HUNT, MT, USDC, and ETH)
const WHALE = "0xCB3f3e0E992435390e686D7b638FCb8baBa6c5c7";

// Test amounts
const HUNT_AMOUNT = parseEther("100");
const MT_AMOUNT = parseEther("5000");
const USDC_AMOUNT = parseUnits("100", 6);
const ETH_AMOUNT = parseEther("0.01");
const CHILD_AMOUNT = parseEther("100");

// Uniswap V4 swap path (fromToken -> ... -> HUNT) for each payment token
const hop = (intermediateCurrency: string, fee: number, tickSpacing: number) => ({
  intermediateCurrency,
  fee,
  tickSpacing,
  hooks: ZERO_ADDRESS,
  hookData: "0x"
});
const ETH_HUNT_HOP = hop(HUNT, 10000, 200); // ETH/HUNT 1%
const PATHS: Record<string, ReturnType<typeof hop>[]> = {
  [ZERO_ADDRESS]: [ETH_HUNT_HOP],
  [USDC.toLowerCase()]: [hop(ZERO_ADDRESS, 500, 10), ETH_HUNT_HOP], // USDC -> ETH (0.05%) -> HUNT
  [MT.toLowerCase()]: [hop(HUNT, 3000, 60)] // HUNT/MT 0.3%
};
const pathFor = (fromToken: string) => PATHS[fromToken.toLowerCase()] ?? [];

describe("ZapUniV4MCV2", async function () {
  const connection = await network.connect("baseForkLatest");
  const { viem, networkHelpers } = connection;
  const { impersonateAccount, stopImpersonatingAccount, setBalance } = networkHelpers;

  const bondAbi = [
    {
      name: "getReserveForToken",
      type: "function",
      stateMutability: "view",
      inputs: [
        { name: "token", type: "address" },
        { name: "tokensToMint", type: "uint256" }
      ],
      outputs: [
        { name: "reserveAmount", type: "uint256" },
        { name: "royalty", type: "uint256" }
      ]
    }
  ] as const;

  const bondPeripheryAbi = [
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
  ] as const;

  async function deployZapFixture() {
    const [, alice] = await viem.getWalletClients();
    const publicClient = await viem.getPublicClient();

    const zap = await viem.deployContract("ZapUniV4MCV2");

    const erc20 = (address: `0x${string}`) => getContract({ address, abi: erc20Abi, client: alice });
    const huntToken = erc20(HUNT);
    const mtToken = erc20(MT);
    const usdcToken = erc20(USDC);
    const childToken = erc20(CHILD_TOKEN);

    const bond = getContract({ address: BOND_ADDRESS, abi: bondAbi, client: publicClient });
    const bondPeriphery = getContract({ address: BOND_PERIPHERY_ADDRESS, abi: bondPeripheryAbi, client: publicClient });

    // Fund alice
    await impersonateAccount(WHALE);
    await huntToken.write.transfer([alice.account.address, HUNT_AMOUNT * 10n], { account: WHALE });
    await mtToken.write.transfer([alice.account.address, MT_AMOUNT * 2n], { account: WHALE });
    await usdcToken.write.transfer([alice.account.address, USDC_AMOUNT * 10n], { account: WHALE });
    await stopImpersonatingAccount(WHALE);
    await setBalance(alice.account.address, parseEther("10"));

    // Approve max amounts to zap contract upfront
    const MAX_UINT256 = 2n ** 256n - 1n;
    await huntToken.write.approve([zap.address, MAX_UINT256], { account: alice.account });
    await mtToken.write.approve([zap.address, MAX_UINT256], { account: alice.account });
    await usdcToken.write.approve([zap.address, MAX_UINT256], { account: alice.account });

    return { zap, alice, huntToken, childToken, bond, bondPeriphery };
  }

  // Helper: get total HUNT required for minting childAmount
  // Note: getReserveForToken returns (reserveAmount, royalty) where reserveAmount ALREADY includes royalty
  async function getHuntRequired(bond: any, childAmount: bigint) {
    const [reserveAmount] = await bond.read.getReserveForToken([CHILD_TOKEN, childAmount]);
    return reserveAmount;
  }

  // Helper: mint with assertions
  async function mintAndAssert(
    zap: any,
    childToken: any,
    alice: any,
    fromToken: `0x${string}`,
    childAmount: bigint,
    maxAmount: bigint,
    ethValue?: bigint
  ) {
    const before = await childToken.read.balanceOf([alice.account.address]);
    await zap.write.mint([fromToken, CHILD_TOKEN, childAmount, maxAmount, pathFor(fromToken)], {
      account: alice.account,
      value: ethValue
    });
    const after = await childToken.read.balanceOf([alice.account.address]);
    assert.equal(after - before, childAmount);
  }

  let zap: any;
  let alice: any;
  let huntToken: any;
  let childToken: any;
  let bond: any;
  let bondPeriphery: any;

  beforeEach(async function () {
    ({ zap, alice, huntToken, childToken, bond, bondPeriphery } = await networkHelpers.loadFixture(deployZapFixture));
  });

  describe("mint()", function () {
    it("should mint with HUNT directly", async function () {
      const huntRequired = await getHuntRequired(bond, CHILD_AMOUNT);
      await mintAndAssert(zap, childToken, alice, HUNT, CHILD_AMOUNT, huntRequired);
    });

    it("should mint with ETH swap", async function () {
      const ethToUse = ETH_AMOUNT * 5n;
      await mintAndAssert(zap, childToken, alice, ZERO_ADDRESS as `0x${string}`, CHILD_AMOUNT, ethToUse, ethToUse);
    });

    it("should mint with MT swap", async function () {
      await mintAndAssert(zap, childToken, alice, MT, CHILD_AMOUNT, MT_AMOUNT);
    });

    it("should mint with USDC swap", async function () {
      await mintAndAssert(zap, childToken, alice, USDC, CHILD_AMOUNT, USDC_AMOUNT);
    });

    it("should revert if HUNT slippage exceeded", async function () {
      const huntRequired = await getHuntRequired(bond, CHILD_AMOUNT);
      await assert.rejects(
        zap.write.mint([HUNT, CHILD_TOKEN, CHILD_AMOUNT, huntRequired - 1n, pathFor(HUNT)], { account: alice.account }),
        /ZapUniV4MCV2__SlippageExceeded/
      );
    });

    it("should revert if ETH amount mismatch", async function () {
      await assert.rejects(
        zap.write.mint([ZERO_ADDRESS, CHILD_TOKEN, CHILD_AMOUNT, ETH_AMOUNT, pathFor(ZERO_ADDRESS)], {
          account: alice.account,
          value: ETH_AMOUNT + 1n
        }),
        /ZapUniV4MCV2__InvalidETHAmount/
      );
    });

    it("should revert with zero amount", async function () {
      await assert.rejects(
        zap.write.mint([HUNT, CHILD_TOKEN, 0n, HUNT_AMOUNT, pathFor(HUNT)], { account: alice.account }),
        /ZapUniV4MCV2__InvalidAmount/
      );
    });

    it("should revert with unsupported token", async function () {
      await assert.rejects(
        zap.write.mint(["0x1234567890123456789012345678901234567890", CHILD_TOKEN, CHILD_AMOUNT, HUNT_AMOUNT, []], {
          account: alice.account
        }),
        /ZapUniV4MCV2__UnsupportedToken/
      );
    });

    it("should revert if ETH sent with HUNT payment", async function () {
      const huntRequired = await getHuntRequired(bond, CHILD_AMOUNT);
      await assert.rejects(
        zap.write.mint([HUNT, CHILD_TOKEN, CHILD_AMOUNT, huntRequired, pathFor(HUNT)], {
          account: alice.account,
          value: 1n // Accidental ETH
        }),
        /ZapUniV4MCV2__InvalidETHAmount/
      );
    });

    it("should revert if ETH sent with ERC20 payment", async function () {
      await assert.rejects(
        zap.write.mint([MT, CHILD_TOKEN, CHILD_AMOUNT, MT_AMOUNT, pathFor(MT)], {
          account: alice.account,
          value: 1n // Accidental ETH
        }),
        /ZapUniV4MCV2__InvalidETHAmount/
      );
    });
  });

  describe("mintReverse()", function () {
    it("should mint with exact HUNT input", async function () {
      const [estimated] = await bondPeriphery.read.getTokensForReserve([CHILD_TOKEN, HUNT_AMOUNT, true]);
      const before = await childToken.read.balanceOf([alice.account.address]);
      await zap.write.mintReverse([HUNT, CHILD_TOKEN, HUNT_AMOUNT, 0n, pathFor(HUNT)], { account: alice.account });
      const received = (await childToken.read.balanceOf([alice.account.address])) - before;

      assert.ok(received > 0n);
      assert.ok(received >= estimated - estimated / 100n);
    });

    it("should mint with ETH swap", async function () {
      const before = await childToken.read.balanceOf([alice.account.address]);
      await zap.write.mintReverse([ZERO_ADDRESS, CHILD_TOKEN, ETH_AMOUNT, 0n, pathFor(ZERO_ADDRESS)], {
        account: alice.account,
        value: ETH_AMOUNT
      });
      assert.ok((await childToken.read.balanceOf([alice.account.address])) > before);
    });

    it("should mint with MT swap", async function () {
      const before = await childToken.read.balanceOf([alice.account.address]);
      await zap.write.mintReverse([MT, CHILD_TOKEN, MT_AMOUNT, 0n, pathFor(MT)], { account: alice.account });
      assert.ok((await childToken.read.balanceOf([alice.account.address])) > before);
    });

    it("should mint with USDC swap", async function () {
      const before = await childToken.read.balanceOf([alice.account.address]);
      await zap.write.mintReverse([USDC, CHILD_TOKEN, USDC_AMOUNT, 0n, pathFor(USDC)], { account: alice.account });
      assert.ok((await childToken.read.balanceOf([alice.account.address])) > before);
    });

    it("should revert if minHuntChildAmount not met", async function () {
      const [estimated] = await bondPeriphery.read.getTokensForReserve([CHILD_TOKEN, HUNT_AMOUNT, true]);
      await assert.rejects(
        zap.write.mintReverse([HUNT, CHILD_TOKEN, HUNT_AMOUNT, estimated * 2n, pathFor(HUNT)], { account: alice.account }),
        /ZapUniV4MCV2__SlippageExceeded/
      );
    });

    it("should revert with zero amount", async function () {
      await assert.rejects(
        zap.write.mintReverse([HUNT, CHILD_TOKEN, 0n, 0n, pathFor(HUNT)], { account: alice.account }),
        /ZapUniV4MCV2__InvalidAmount/
      );
    });

    it("should revert if ETH sent with HUNT payment", async function () {
      await assert.rejects(
        zap.write.mintReverse([HUNT, CHILD_TOKEN, HUNT_AMOUNT, 0n, pathFor(HUNT)], {
          account: alice.account,
          value: 1n // Accidental ETH
        }),
        /ZapUniV4MCV2__InvalidETHAmount/
      );
    });

    it("should revert if ETH sent with ERC20 payment", async function () {
      await assert.rejects(
        zap.write.mintReverse([MT, CHILD_TOKEN, MT_AMOUNT, 0n, pathFor(MT)], {
          account: alice.account,
          value: 1n // Accidental ETH
        }),
        /ZapUniV4MCV2__InvalidETHAmount/
      );
    });
  });

  describe("Token refunds", function () {
    it("should refund excess MT after mint (exactOutput swap)", async function () {
      const publicClient = await viem.getPublicClient();
      const mtToken = getContract({ address: MT, abi: erc20Abi, client: publicClient });

      // Estimate how much MT is actually needed
      const { result } = await publicClient.simulateContract({
        address: zap.address,
        abi: zap.abi,
        functionName: "estimateMint",
        args: [MT, CHILD_TOKEN, CHILD_AMOUNT, pathFor(MT)]
      });
      const [estimatedMT] = result;

      // Send 2x what's needed
      const mtToSend = estimatedMT * 2n;
      const mtBefore = await mtToken.read.balanceOf([alice.account.address]);

      await zap.write.mint([MT, CHILD_TOKEN, CHILD_AMOUNT, mtToSend, pathFor(MT)], { account: alice.account });

      const mtAfter = await mtToken.read.balanceOf([alice.account.address]);
      const mtUsed = mtBefore - mtAfter;

      // Should use approximately the estimated amount, not the full mtToSend
      assert.ok(mtUsed < mtToSend, "Should not use entire max amount");
      assert.ok(mtUsed <= (estimatedMT * 105n) / 100n, "Should use roughly the estimated amount (within 5%)");
    });

    it("should refund excess ETH after mint (exactOutput swap)", async function () {
      const publicClient = await viem.getPublicClient();

      // Estimate how much ETH is actually needed
      const { result } = await publicClient.simulateContract({
        address: zap.address,
        abi: zap.abi,
        functionName: "estimateMint",
        args: [ZERO_ADDRESS, CHILD_TOKEN, CHILD_AMOUNT, pathFor(ZERO_ADDRESS)]
      });
      const [estimatedETH] = result;

      // Send 2x what's needed
      const ethToSend = estimatedETH * 2n;
      const ethBefore = await publicClient.getBalance({ address: alice.account.address });

      await zap.write.mint([ZERO_ADDRESS, CHILD_TOKEN, CHILD_AMOUNT, ethToSend, pathFor(ZERO_ADDRESS)], {
        account: alice.account,
        value: ethToSend
      });

      const ethAfter = await publicClient.getBalance({ address: alice.account.address });
      const ethUsed = ethBefore - ethAfter;

      // ethUsed includes gas, so check that it's significantly less than ethToSend + reasonable gas
      assert.ok(ethUsed < ethToSend, "Should refund excess ETH");
    });
  });

  describe("Swap path", function () {
    it("should mint through the direct HUNT/USDC pool with a single-hop path", async function () {
      const before = await childToken.read.balanceOf([alice.account.address]);
      await zap.write.mintReverse([USDC, CHILD_TOKEN, USDC_AMOUNT, 0n, [hop(HUNT, 10000, 100)]], {
        account: alice.account
      });
      assert.ok((await childToken.read.balanceOf([alice.account.address])) > before);
    });

    it("multi-hop estimateMint should match the actual mint", async function () {
      const publicClient = await viem.getPublicClient();
      const usdcToken = getContract({ address: USDC, abi: erc20Abi, client: publicClient });

      const { result } = await publicClient.simulateContract({
        address: zap.address,
        abi: zap.abi,
        functionName: "estimateMint",
        args: [USDC, CHILD_TOKEN, CHILD_AMOUNT, pathFor(USDC)]
      });
      const [estimatedUSDC] = result;
      const maxUSDC = (estimatedUSDC * 101n) / 100n;

      const usdcBefore = await usdcToken.read.balanceOf([alice.account.address]);
      await mintAndAssert(zap, childToken, alice, USDC, CHILD_AMOUNT, maxUSDC);
      const usdcUsed = usdcBefore - (await usdcToken.read.balanceOf([alice.account.address]));

      assert.ok(usdcUsed <= maxUSDC, "Should not exceed max");
      assert.ok(usdcUsed >= (estimatedUSDC * 99n) / 100n, "Should use roughly the estimated amount");
    });

    it("should revert with an empty path", async function () {
      await assert.rejects(
        zap.write.mintReverse([USDC, CHILD_TOKEN, USDC_AMOUNT, 0n, []], { account: alice.account }),
        /ZapUniV4MCV2__InvalidPath/
      );
    });

    it("should revert if the path does not end with HUNT", async function () {
      await assert.rejects(
        zap.write.mint([USDC, CHILD_TOKEN, CHILD_AMOUNT, USDC_AMOUNT, [hop(ZERO_ADDRESS, 500, 10)]], {
          account: alice.account
        }),
        /ZapUniV4MCV2__InvalidPath/
      );
    });

    it("should reject estimates with an invalid path", async function () {
      const publicClient = await viem.getPublicClient();
      await assert.rejects(
        publicClient.simulateContract({
          address: zap.address,
          abi: zap.abi,
          functionName: "estimateMintReverse",
          args: [USDC, CHILD_TOKEN, USDC_AMOUNT, []]
        }),
        /ZapUniV4MCV2__InvalidPath/
      );
    });
  });

  describe("Events", function () {
    it("should emit Minted event", async function () {
      const huntRequired = await getHuntRequired(bond, CHILD_AMOUNT);
      const tx = zap.write.mint([HUNT, CHILD_TOKEN, CHILD_AMOUNT, huntRequired, pathFor(HUNT)], { account: alice.account });
      await viem.assertions.emit(tx, zap, "Minted");
    });

    it("should emit MintedReverse event", async function () {
      const tx = zap.write.mintReverse([HUNT, CHILD_TOKEN, HUNT_AMOUNT, 0n, pathFor(HUNT)], { account: alice.account });
      await viem.assertions.emit(tx, zap, "MintedReverse");
    });
  });

  describe("estimateMint()", function () {
    it("should estimate HUNT amount correctly for HUNT input", async function () {
      const publicClient = await viem.getPublicClient();
      const huntRequired = await getHuntRequired(bond, CHILD_AMOUNT);

      const { result } = await publicClient.simulateContract({
        address: zap.address,
        abi: zap.abi,
        functionName: "estimateMint",
        args: [HUNT, CHILD_TOKEN, CHILD_AMOUNT, pathFor(HUNT)]
      });

      const [fromTokenAmount, totalHuntRequired] = result;
      assert.equal(fromTokenAmount, huntRequired);
      assert.equal(totalHuntRequired, huntRequired);
    });

    it("should estimate MT amount for swap", async function () {
      const publicClient = await viem.getPublicClient();

      const { result } = await publicClient.simulateContract({
        address: zap.address,
        abi: zap.abi,
        functionName: "estimateMint",
        args: [MT, CHILD_TOKEN, CHILD_AMOUNT, pathFor(MT)]
      });

      const [fromTokenAmount, totalHuntRequired] = result;
      assert.ok(fromTokenAmount > 0n, "Should estimate MT amount");
      assert.ok(totalHuntRequired > 0n, "Should return HUNT required");
    });

    it("should estimate USDC amount for swap", async function () {
      const publicClient = await viem.getPublicClient();

      const { result } = await publicClient.simulateContract({
        address: zap.address,
        abi: zap.abi,
        functionName: "estimateMint",
        args: [USDC, CHILD_TOKEN, CHILD_AMOUNT, pathFor(USDC)]
      });

      const [fromTokenAmount, totalHuntRequired] = result;
      assert.ok(fromTokenAmount > 0n, "Should estimate USDC amount");
      assert.ok(totalHuntRequired > 0n, "Should return HUNT required");
    });

    it("should estimate ETH amount for swap", async function () {
      const publicClient = await viem.getPublicClient();

      const { result } = await publicClient.simulateContract({
        address: zap.address,
        abi: zap.abi,
        functionName: "estimateMint",
        args: [ZERO_ADDRESS, CHILD_TOKEN, CHILD_AMOUNT, pathFor(ZERO_ADDRESS)]
      });

      const [fromTokenAmount, totalHuntRequired] = result;
      assert.ok(fromTokenAmount > 0n, "Should estimate ETH amount");
      assert.ok(totalHuntRequired > 0n, "Should return HUNT required");
    });

    it("estimate should be usable for actual mint with slippage", async function () {
      const publicClient = await viem.getPublicClient();

      const { result } = await publicClient.simulateContract({
        address: zap.address,
        abi: zap.abi,
        functionName: "estimateMint",
        args: [HUNT, CHILD_TOKEN, CHILD_AMOUNT, pathFor(HUNT)]
      });

      const [estimatedAmount] = result;
      // Add 1% slippage buffer
      const maxAmount = (estimatedAmount * 101n) / 100n;

      const before = await childToken.read.balanceOf([alice.account.address]);
      await zap.write.mint([HUNT, CHILD_TOKEN, CHILD_AMOUNT, maxAmount, pathFor(HUNT)], { account: alice.account });
      const after = await childToken.read.balanceOf([alice.account.address]);

      assert.equal(after - before, CHILD_AMOUNT);
    });
  });

  describe("estimateMintReverse()", function () {
    it("should estimate child tokens for HUNT input", async function () {
      const publicClient = await viem.getPublicClient();
      const [expectedTokens] = await bondPeriphery.read.getTokensForReserve([CHILD_TOKEN, HUNT_AMOUNT, false]);

      const { result } = await publicClient.simulateContract({
        address: zap.address,
        abi: zap.abi,
        functionName: "estimateMintReverse",
        args: [HUNT, CHILD_TOKEN, HUNT_AMOUNT, pathFor(HUNT)]
      });

      const [huntChildAmount, huntAmount] = result;
      assert.equal(huntChildAmount, expectedTokens);
      assert.equal(huntAmount, HUNT_AMOUNT);
    });

    it("should estimate child tokens for MT swap", async function () {
      const publicClient = await viem.getPublicClient();

      const { result } = await publicClient.simulateContract({
        address: zap.address,
        abi: zap.abi,
        functionName: "estimateMintReverse",
        args: [MT, CHILD_TOKEN, MT_AMOUNT, pathFor(MT)]
      });

      const [huntChildAmount, huntAmount] = result;
      assert.ok(huntChildAmount > 0n, "Should estimate child tokens");
      assert.ok(huntAmount > 0n, "Should estimate HUNT received from swap");
    });

    it("should estimate child tokens for USDC swap", async function () {
      const publicClient = await viem.getPublicClient();

      const { result } = await publicClient.simulateContract({
        address: zap.address,
        abi: zap.abi,
        functionName: "estimateMintReverse",
        args: [USDC, CHILD_TOKEN, USDC_AMOUNT, pathFor(USDC)]
      });

      const [huntChildAmount, huntAmount] = result;
      assert.ok(huntChildAmount > 0n, "Should estimate child tokens");
      assert.ok(huntAmount > 0n, "Should estimate HUNT received from swap");
    });

    it("should estimate child tokens for ETH swap", async function () {
      const publicClient = await viem.getPublicClient();

      const { result } = await publicClient.simulateContract({
        address: zap.address,
        abi: zap.abi,
        functionName: "estimateMintReverse",
        args: [ZERO_ADDRESS, CHILD_TOKEN, ETH_AMOUNT, pathFor(ZERO_ADDRESS)]
      });

      const [huntChildAmount, huntAmount] = result;
      assert.ok(huntChildAmount > 0n, "Should estimate child tokens");
      assert.ok(huntAmount > 0n, "Should estimate HUNT received from swap");
    });

    it("estimate should be usable for actual mintReverse with slippage", async function () {
      const publicClient = await viem.getPublicClient();

      const { result } = await publicClient.simulateContract({
        address: zap.address,
        abi: zap.abi,
        functionName: "estimateMintReverse",
        args: [HUNT, CHILD_TOKEN, HUNT_AMOUNT, pathFor(HUNT)]
      });

      const [estimatedChildAmount] = result;
      // Apply 1% slippage (minAmount = estimated - 1%)
      const minChildAmount = (estimatedChildAmount * 99n) / 100n;

      const before = await childToken.read.balanceOf([alice.account.address]);
      await zap.write.mintReverse([HUNT, CHILD_TOKEN, HUNT_AMOUNT, minChildAmount, pathFor(HUNT)], { account: alice.account });
      const received = (await childToken.read.balanceOf([alice.account.address])) - before;

      assert.ok(received >= minChildAmount, "Should receive at least minChildAmount");
    });
  });
});
