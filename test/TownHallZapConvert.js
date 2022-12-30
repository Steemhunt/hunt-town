const {
  time,
  loadFixture,
} = require("@nomicfoundation/hardhat-network-helpers");
const { expect } = require("chai");
const IERC20_SOURCE = "@openzeppelin/contracts/token/ERC20/IERC20.sol:IERC20";

describe("TownHallZap - Convert", function () {
  let townHallZap, townHall, building, huntToken, usdtToken, wethToken;
  let owner, alice, impersonatedSigner;

  // Impersonate a wallet with enough HUNT and USDT balance
  const TEST_WALLET = "0xe1aAF39DB1Cd7E16C4305410Fe72B13c7ADD17e6";

  const WETH_ADDRESS = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2";
  const USDT_ADDRESS = "0xdAC17F958D2ee523a2206206994597C13D831ec7";
  const HUNT_ADDRESS = "0x9AAb071B4129B083B01cB5A0Cb513Ce7ecA26fa5";
  const MAX_USDT_PER_BUILDING = 250n * 10n ** 6n; // 250 USDT > 1000 HUNT on the forked block (16288578)
  const MAX_ETH_PER_BUILDING = 2n * 10n ** 17n;

  async function deployFixtures() {
    const Building = await ethers.getContractFactory("Building");
    const building = await Building.deploy();

    const huntToken = await hre.ethers.getContractAt(
      IERC20_SOURCE,
      HUNT_ADDRESS
    );
    const usdtToken = await hre.ethers.getContractAt(
      IERC20_SOURCE,
      USDT_ADDRESS
    );
    const wethToken = await hre.ethers.getContractAt(
      IERC20_SOURCE,
      WETH_ADDRESS
    );

    const TownHall = await ethers.getContractFactory("TownHall");
    const townHall = await TownHall.deploy(building.address, huntToken.address);
    await building.setTownHall(townHall.address);

    const TownHallZap = await ethers.getContractFactory("TownHallZap");
    const townHallZap = await TownHallZap.deploy(
      townHall.address,
      huntToken.address
    );

    return [townHallZap, townHall, building, huntToken, usdtToken, wethToken];
  }

  beforeEach(async function () {
    [townHallZap, townHall, building, huntToken, usdtToken, wethToken] =
      await loadFixture(deployFixtures);
    LOCK_UP_AMOUNT = (await townHall.LOCK_UP_AMOUNT()).toBigInt();
    [owner, alice] = await ethers.getSigners();
    impersonatedSigner = await ethers.getImpersonatedSigner(TEST_WALLET);
  });

  describe("Estimate source token amount required for zap-in", function () {
    it("Should returns correct estimation for USDT", async function () {
      const usdtRequired = await townHallZap.callStatic.estimateAmountIn(
        usdtToken.address,
        1
      );
      expect(usdtRequired).to.equal(216034989n); // $216.03
    });

    it("Should returns correct estimation for WETH", async function () {
      const wethRequired = await townHallZap.callStatic.estimateAmountIn(
        wethToken.address,
        1
      );
      expect(wethRequired).to.equal(182848909798753181n); // 0.1828 ETH
    });
  }); // Estimate

  describe("Convert and Mint", function () {
    describe("Normal Flow", function () {
      beforeEach(async function () {
        await usdtToken
          .connect(impersonatedSigner)
          .approve(townHallZap.address, 9999999n * 10n ** 6n);
        this.originalUSDTBalance = BigInt(
          await usdtToken.balanceOf(impersonatedSigner.address)
        );
        this.estimatedAmount = BigInt(
          await townHallZap.callStatic.estimateAmountIn(usdtToken.address, 1)
        );

        await townHallZap
          .connect(impersonatedSigner)
          .convertAndMint(
            USDT_ADDRESS,
            alice.address,
            1,
            MAX_USDT_PER_BUILDING
          );
      });

      it("should convert USDT to HUNT and mint a Building NFT", async function () {
        expect(await building.balanceOf(alice.address)).to.equal(1);
      });

      it("should have no remaining HUNT on Zap contract", async function () {
        expect(await huntToken.balanceOf(townHallZap.address)).to.equal(0);
      });

      it("should refund remaining USDT to the caller, so the caller paid exact amount as estimated", async function () {
        expect(await usdtToken.balanceOf(impersonatedSigner.address)).to.equal(
          this.originalUSDTBalance - this.estimatedAmount
        );
      });
    });

    describe("Bulk Minting with Zap-in", function () {
      beforeEach(async function () {
        await usdtToken
          .connect(impersonatedSigner)
          .approve(townHallZap.address, 9999999n * 10n ** 6n);
        this.originalUSDTBalance = BigInt(
          await usdtToken.balanceOf(impersonatedSigner.address)
        );
        this.estimatedAmount = BigInt(
          await townHallZap.callStatic.estimateAmountIn(usdtToken.address, 10)
        );

        await townHallZap
          .connect(impersonatedSigner)
          .convertAndMint(
            USDT_ADDRESS,
            alice.address,
            10,
            MAX_USDT_PER_BUILDING * 10n
          );
      });

      it("should convert USDT to HUNT and mint 10 Building NFTs", async function () {
        expect(await building.balanceOf(alice.address)).to.equal(10);
      });

      // TODO: More test cases
    });

    // TODO: Revert & Error handling
    // TODO: Edge cases
  });

  describe("Convert ETH and Mint", function () {
    describe("Normal Flow", function () {
      beforeEach(async function () {
        this.originalETHBalance = BigInt(await impersonatedSigner.getBalance());
        this.estimatedAmount = BigInt(
          await townHallZap.callStatic.estimateAmountIn(wethToken.address, 1)
        );

        await townHallZap
          .connect(impersonatedSigner)
          .convertETHAndMint(alice.address, 1, MAX_ETH_PER_BUILDING, {
            value: MAX_ETH_PER_BUILDING,
          });
      });

      it("should convert ETH to HUNT and mint a Building NFT", async function () {
        expect(await building.balanceOf(alice.address)).to.equal(1);
      });

      it("should have no remaining ETH on Zap contract", async function () {
        expect(
          await townHallZap.provider.getBalance(townHallZap.address)
        ).to.equal(0);
      });

      it("should refund remaining ETH to the caller, so the caller paid exact amount as estimated", async function () {
        const newEstimation = BigInt(
          await townHallZap.callStatic.estimateAmountIn(wethToken.address, 1)
        );
        await expect(
          townHallZap
            .connect(impersonatedSigner)
            .convertETHAndMint(alice.address, 1, MAX_ETH_PER_BUILDING, {
              value: MAX_ETH_PER_BUILDING,
            })
        ).to.changeEtherBalance(impersonatedSigner, -newEstimation, {
          includeFee: false,
        });
      });
    });

    // TODO: Bulk minting with zap-in
    describe("Bulk Minting with Zap-in", function () {
      beforeEach(async function () {
        this.originalETHBalance = BigInt(await impersonatedSigner.getBalance());
        this.estimatedAmount = BigInt(
          await townHallZap.callStatic.estimateAmountIn(wethToken.address, 5)
        );

        await townHallZap
          .connect(impersonatedSigner)
          .convertETHAndMint(alice.address, 5, MAX_ETH_PER_BUILDING * 5n, {
            value: MAX_ETH_PER_BUILDING * 5n,
          });
      });

      it("should convert ETH to HUNT and mint 5 Building NFTs", async function () {
        expect(await building.balanceOf(alice.address)).to.equal(5);
      });
    });

    // TODO: Revert & Error handling
    // TODO: Edge cases
  });
});
