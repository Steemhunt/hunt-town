const { loadFixture } = require('@nomicfoundation/hardhat-network-helpers');
const { expect } = require('chai');
const IERC20_SOURCE = '@openzeppelin/contracts/token/ERC20/IERC20.sol:IERC20';

const { AlphaRouter } = require('@uniswap/smart-order-router');
const { Token, CurrencyAmount, TradeType } = require('@uniswap/sdk-core');
const { encodeRouteToPath } = require('@uniswap/v3-sdk');
const { encodeMixedRouteToPath, MixedRouteSDK, Protocol } = require('@uniswap/router-sdk');

describe('TownHallZap - Convert', function () {
  let townHallZap, townHall, building, huntToken, usdcToken;
  let lockUpAmount;
  let alice, impersonatedSigner;

  // Impersonate a wallet with enough HUNT and USDC balance
  const TEST_WALLET = '0xe1aAF39DB1Cd7E16C4305410Fe72B13c7ADD17e6';

  const WETH_ADDRESS = '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2';
  const HUNT_ADDRESS = '0x9AAb071B4129B083B01cB5A0Cb513Ce7ecA26fa5';
  const USDC_ADDRESS = '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48';

  const MAX_USDC_PER_BUILDING = 250n * 10n ** 6n; // 250 USDC > 1000 HUNT on the forked block (16288578)
  const MAX_ETH_PER_BUILDING = 2n * 10n ** 17n; // 0.2 ETH = ~$266

  async function deployFixtures() {
    const Building = await ethers.getContractFactory('Building');
    const building = await Building.deploy();

    const huntToken = await hre.ethers.getContractAt(IERC20_SOURCE, HUNT_ADDRESS);
    const usdcToken = await hre.ethers.getContractAt(IERC20_SOURCE, USDC_ADDRESS);

    const TownHall = await ethers.getContractFactory('TownHall');
    const townHall = await TownHall.deploy(building.address, huntToken.address);
    await building.setTownHall(townHall.address);

    const TownHallZap = await ethers.getContractFactory('TownHallZap');
    const townHallZap = await TownHallZap.deploy(townHall.address, huntToken.address);

    return [townHallZap, townHall, building, huntToken, usdcToken];
  }

  async function getSwapPath(inputToken) {
    // Path: USDC -> WETH -> HUNT
    // Path should be reversed for an exactOutput swap, the first swap that occurs is the swap which returns the eventual desired token.
    // In this case, our desired output token is HUNT so that swap happens first, and is encoded in the path accordingly.

    if (inputToken === 'usdc') {
      return '0x9aab071b4129b083b01cb5a0cb513ce7eca26fa5000bb8c02aaa39b223fe8d0a0e5c4f27ead9083c756cc20001f4a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48';
    }

    if (inputToken === 'weth') {
      return '0x9aab071b4129b083b01cb5a0cb513ce7eca26fa5000bb8c02aaa39b223fe8d0a0e5c4f27ead9083c756cc2';
    }

    // Just return a fixture path calculated by following logic to save test time

    const swapTokens = {
      weth: new Token(1, WETH_ADDRESS, 18, 'WETH'),
      usdc: new Token(1, USDC_ADDRESS, 6, 'USDC'),
      hunt: new Token(1, HUNT_ADDRESS, 18, 'HUNT')
    };

    const router = new AlphaRouter({
      chainId: 1,
      provider: ethers.provider
    });

    const params = {
      amount: CurrencyAmount.fromRawAmount(swapTokens.hunt, lockUpAmount),
      quoteCurrency: swapTokens[inputToken],
      tradeType: TradeType.EXACT_OUTPUT
    };
    const route = await router.route(...Object.values(params));

    // show results
    const bestRoute = route.route[0].route;
    console.log(bestRoute);

    const path =
      bestRoute.protocol === Protocol.V3
        ? encodeRouteToPath(bestRoute, true) // quoteExactOutput: true - to generate reversed path
        : encodeMixedRouteToPath(
            bestRoute.protocol === Protocol.V2
              ? new MixedRouteSDK(bestRoute.pairs, bestRoute.input, bestRoute.output)
              : bestRoute
          );

    console.log(`Path: `, path);
    console.log(`Quote Exact In: ${route.quote.toFixed(6)}`);
    console.log(`Gas Adjusted Quote In: ${route.quoteGasAdjusted.toFixed(2)}`);
    console.log(`Gas Used USD: ${route.estimatedGasUsedUSD.toFixed(6)}`);

    return path;
  }

  beforeEach(async function () {
    [townHallZap, townHall, building, huntToken, usdcToken] = await loadFixture(deployFixtures);
    lockUpAmount = String(await townHall.LOCK_UP_AMOUNT());
    [, alice] = await ethers.getSigners();
    impersonatedSigner = await ethers.getImpersonatedSigner(TEST_WALLET);
  });

  describe('Parse Swap Path', function () {
    beforeEach(async function () {
      this.path = await getSwapPath('usdc');
    });

    it('Input token should be USDC', async function () {
      expect(await townHallZap.getInputToken(this.path)).to.equal(USDC_ADDRESS);
    });

    it('Output token should be HUNT', async function () {
      expect(await townHallZap.getOutputToken(this.path)).to.equal(HUNT_ADDRESS);
    });
  }); // Parse Swap Path

  describe('Convert and Mint', function () {
    describe('Normal Flow', function () {
      beforeEach(async function () {
        await usdcToken.connect(impersonatedSigner).approve(townHallZap.address, 9999999n * 10n ** 6n);
        this.originalUSDCBalance = BigInt(await usdcToken.balanceOf(impersonatedSigner.address));
        this.AMOUNT_TO_DEDUCT = 241805219n; // $241.80 USDC

        await townHallZap
          .connect(impersonatedSigner)
          .convertAndMint(await getSwapPath('usdc'), alice.address, 1, MAX_USDC_PER_BUILDING);
      });

      it('should convert USDC to HUNT and mint a Building NFT', async function () {
        expect(await building.balanceOf(alice.address)).to.equal(1);
      });

      it('should have no remaining HUNT on Zap contract', async function () {
        expect(await huntToken.balanceOf(townHallZap.address)).to.equal(0);
      });

      it('should have no remaining USDC on Zap contract', async function () {
        expect(await usdcToken.balanceOf(townHallZap.address)).to.equal(0);
      });

      it('should spent the exact amount of USDC from the caller', async function () {
        expect(await usdcToken.balanceOf(impersonatedSigner.address)).to.equal(
          this.originalUSDCBalance - this.AMOUNT_TO_DEDUCT
        );
      });
    });

    describe('Bulk Minting with Zap-in', function () {
      beforeEach(async function () {
        await usdcToken.connect(impersonatedSigner).approve(townHallZap.address, 9999999n * 10n ** 6n);
        this.originalUSDCBalance = BigInt(await usdcToken.balanceOf(impersonatedSigner.address));

        this.AMOUNT_TO_DEDUCT = 968625622n; // $968.62 USDC - for 4 NFTs

        await townHallZap
          .connect(impersonatedSigner)
          .convertAndMint(await getSwapPath('usdc'), alice.address, 4, MAX_USDC_PER_BUILDING * 4n);
      });

      it('should convert USDC to HUNT and mint 4 Building NFTs', async function () {
        expect(await building.balanceOf(alice.address)).to.equal(4);
      });

      it('should have no remaining HUNT on Zap contract', async function () {
        expect(await huntToken.balanceOf(townHallZap.address)).to.equal(0);
      });

      it('should have no remaining USDC on Zap contract', async function () {
        expect(await usdcToken.balanceOf(townHallZap.address)).to.equal(0);
      });

      it('should spent the exact amount of USDC from the caller', async function () {
        expect(await usdcToken.balanceOf(impersonatedSigner.address)).to.equal(
          this.originalUSDCBalance - this.AMOUNT_TO_DEDUCT
        );
      });
    });

    describe('Edge Cases', function () {
      it('should revert if the Swap Path starts with HUNT token', async function () {
        const path = '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc200003c9AAb071B4129B083B01cB5A0Cb513Ce7ecA26fa5';

        await expect(
          townHallZap.connect(impersonatedSigner).convertAndMint(path, alice.address, 1, MAX_USDC_PER_BUILDING)
        ).to.be.revertedWithCustomError(townHallZap, 'TownHallZap__InvalidInputToken');
      });

      it('should revert if the Swap Path does not end with HUNT token', async function () {
        const path = '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc200003c2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599';

        await expect(
          townHallZap.connect(impersonatedSigner).convertAndMint(path, alice.address, 1, MAX_USDC_PER_BUILDING)
        ).to.be.revertedWithCustomError(townHallZap, 'TownHallZap__InvalidOutputToken');
      });

      it('should revert if mintingCount is 0', async function () {
        await expect(
          townHallZap
            .connect(impersonatedSigner)
            .convertAndMint(await getSwapPath('usdc'), alice.address, 0, MAX_USDC_PER_BUILDING)
        ).to.be.revertedWithCustomError(townHallZap, 'TownHallZap__InvalidMintingCount');
      });

      it('should revert if mintingCount is over the maximum value', async function () {
        await expect(
          townHallZap
            .connect(impersonatedSigner)
            .convertAndMint(await getSwapPath('usdc'), alice.address, 201, MAX_USDC_PER_BUILDING)
        ).to.be.revertedWithCustomError(townHallZap, 'TownHallZap__InvalidMintingCount');
      });
    });
  }); // Edge Cases

  describe('Convert ETH and Mint', function () {
    describe('Normal Flow', function () {
      beforeEach(async function () {
        await townHallZap
          .connect(impersonatedSigner)
          .convertETHAndMint(await getSwapPath('weth'), alice.address, 1, MAX_ETH_PER_BUILDING, {
            value: MAX_ETH_PER_BUILDING
          });
      });

      it('should convert ETH to HUNT and mint a Building NFT', async function () {
        expect(await building.balanceOf(alice.address)).to.equal(1);
      });

      it('should have no remaining ETH on Zap contract', async function () {
        expect(await townHallZap.provider.getBalance(townHallZap.address)).to.equal(0);
      });

      it('should have no remaining HUNT on Zap contract', async function () {
        expect(await huntToken.balanceOf(townHallZap.address)).to.equal(0);
      });

      it('should spent the exact amount of ETH from the caller', async function () {
        const AMOUNT_TO_DEDUCT = 181156989672627786n; // 0.1811 ETH
        await expect(
          townHallZap
            .connect(impersonatedSigner)
            .convertETHAndMint(await getSwapPath('weth'), alice.address, 1, MAX_ETH_PER_BUILDING, {
              value: MAX_ETH_PER_BUILDING
            })
        ).to.changeEtherBalance(impersonatedSigner, -AMOUNT_TO_DEDUCT, {
          includeFee: false
        });
      });
    });

    describe('Bulk Minting with Zap-in', function () {
      beforeEach(async function () {
        await townHallZap
          .connect(impersonatedSigner)
          .convertETHAndMint(await getSwapPath('weth'), alice.address, 2, MAX_ETH_PER_BUILDING * 2n, {
            value: MAX_ETH_PER_BUILDING * 2n
          });
      });

      it('should convert ETH to HUNT and mint 4 Building NFTs', async function () {
        expect(await building.balanceOf(alice.address)).to.equal(2);
      });

      it('should have no remaining ETH on Zap contract', async function () {
        expect(await townHallZap.provider.getBalance(townHallZap.address)).to.equal(0);
      });

      it('should have no remaining HUNT on Zap contract', async function () {
        expect(await huntToken.balanceOf(townHallZap.address)).to.equal(0);
      });

      it('should spent the exact amount of ETH from the caller', async function () {
        const AMOUNT_TO_DEDUCT = 544523524478176326n; // 0.5445 ETH
        await expect(
          townHallZap
            .connect(impersonatedSigner)
            .convertETHAndMint(await getSwapPath('weth'), alice.address, 3, MAX_ETH_PER_BUILDING * 3n, {
              value: MAX_ETH_PER_BUILDING * 3n
            })
        ).to.changeEtherBalance(impersonatedSigner, -AMOUNT_TO_DEDUCT, {
          includeFee: false
        });
      });
    });

    describe('Edge Cases', function () {
      it('should revert if the Swap Path starts with other than WETH', async function () {
        await expect(
          townHallZap
            .connect(impersonatedSigner)
            .convertETHAndMint(await getSwapPath('usdc'), alice.address, 1, MAX_ETH_PER_BUILDING, {
              value: MAX_ETH_PER_BUILDING
            })
        ).to.be.revertedWithCustomError(townHallZap, 'TownHallZap__InvalidInputToken');
      });

      it('should revert if the Swap Path does not end with HUNT token', async function () {
        const path = '0xdAC17F958D2ee523a2206206994597C13D831ec700003cC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2';

        await expect(
          townHallZap
            .connect(impersonatedSigner)
            .convertETHAndMint(path, alice.address, 1, MAX_ETH_PER_BUILDING, { value: MAX_ETH_PER_BUILDING })
        ).to.be.revertedWithCustomError(townHallZap, 'TownHallZap__InvalidOutputToken');
      });

      it('should revert if mintingCount is 0', async function () {
        await expect(
          townHallZap
            .connect(impersonatedSigner)
            .convertETHAndMint(await getSwapPath('weth'), alice.address, 0, MAX_ETH_PER_BUILDING, {
              value: MAX_ETH_PER_BUILDING
            })
        ).to.be.revertedWithCustomError(townHallZap, 'TownHallZap__InvalidMintingCount');
      });

      it('should revert if mintingCount is over the maximum value', async function () {
        await expect(
          townHallZap
            .connect(impersonatedSigner)
            .convertETHAndMint(await getSwapPath('weth'), alice.address, 201, MAX_ETH_PER_BUILDING, {
              value: MAX_ETH_PER_BUILDING
            })
        ).to.be.revertedWithCustomError(townHallZap, 'TownHallZap__InvalidMintingCount');
      });

      it('should revert if msg.value does not match with the amountInMaximum', async function () {
        await expect(
          townHallZap
            .connect(impersonatedSigner)
            .convertETHAndMint(await getSwapPath('weth'), alice.address, 1, MAX_ETH_PER_BUILDING, {
              value: MAX_ETH_PER_BUILDING + 1n
            })
        ).to.be.revertedWithCustomError(townHallZap, 'TownHallZap__InvalidETHSent');
      });
    }); // Edge Cases
  });
});
