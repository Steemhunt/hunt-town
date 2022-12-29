const { time, loadFixture } = require("@nomicfoundation/hardhat-network-helpers");
const { expect } = require("chai");
const IERC20_SOURCE = "@openzeppelin/contracts/token/ERC20/IERC20.sol:IERC20";

describe("TownHallZap - Convert", function () {
  let townHallZap, townHall, building, huntToken, usdtToken;
  let owner, alice, impersonatedSigner;

  // Impersonate a wallet with enough HUNT and USDT balance
  const TEST_WALLET = "0xe1aAF39DB1Cd7E16C4305410Fe72B13c7ADD17e6";

  const USDT_ADDRESS = "0xdAC17F958D2ee523a2206206994597C13D831ec7";
  const HUNT_ADDRESS = "0x9AAb071B4129B083B01cB5A0Cb513Ce7ecA26fa5";
  const MAX_USDT_PER_BUILDING = 250n * 10n**6n; // 250 USDT > 1000 HUNT on the forked block (16288578)

  async function deployFixtures() {
    const Building = await ethers.getContractFactory("Building");
    const building = await Building.deploy();

    const huntToken = await hre.ethers.getContractAt(IERC20_SOURCE, HUNT_ADDRESS);
    const usdtToken = await hre.ethers.getContractAt(IERC20_SOURCE, USDT_ADDRESS);

    const TownHall = await ethers.getContractFactory("TownHall");
    const townHall = await TownHall.deploy(building.address, huntToken.address);
    await building.setTownHall(townHall.address);

    const TownHallZap = await ethers.getContractFactory("TownHallZap");
    const townHallZap = await TownHallZap.deploy(townHall.address, huntToken.address);

    return [ townHallZap, townHall, building, huntToken, usdtToken ];
  }

  beforeEach(async function() {
    [ townHallZap, townHall, building, huntToken, usdtToken ] = await loadFixture(deployFixtures);
    LOCK_UP_AMOUNT = (await townHall.LOCK_UP_AMOUNT()).toBigInt();
    [ owner, alice ] = await ethers.getSigners();
    impersonatedSigner = await ethers.getImpersonatedSigner(TEST_WALLET);
  });

  describe.only("Convert and Mint", function() {
    beforeEach(async function() {
      await usdtToken.connect(impersonatedSigner).approve(townHallZap.address, 9999999n * 10n**6n);
      await townHallZap.connect(impersonatedSigner).convertAndMint(USDT_ADDRESS, alice.address, MAX_USDT_PER_BUILDING);
    });

    it("should convert USDT to HUNT and mint the Building NFT", async function() {
      expect(await building.balanceOf(alice.address)).to.equal(1);
    });

    it("should have no remaining HUNT on Zap contract", async function() {
      expect(await huntToken.balanceOf(townHallZap.address)).to.equal(0);
    });

    // FIXME: This will fail without refund process on convertAndMint() function
    it("should have no remaining USDT on Zap contract", async function() {
      expect(await usdtToken.balanceOf(townHallZap.address)).to.equal(0);
    });

    // TODO: More test cases & edge cases
  });
});
