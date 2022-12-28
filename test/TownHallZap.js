const {
  time,
  loadFixture,
} = require("@nomicfoundation/hardhat-network-helpers");

const { expect } = require("chai");

describe("TownHallZap", function () {
  async function deployFixtures() {
    const Building = await ethers.getContractFactory("Building");
    const building = await Building.deploy();

    const HuntToken = await ethers.getContractFactory("HuntTokenMock");
    const huntToken = await HuntToken.deploy();

    const TownHall = await ethers.getContractFactory("TownHall");
    const townHall = await TownHall.deploy(building.address, huntToken.address);

    const UniswapRouter = await ethers.getContractFactory("uniswapV3Router");
    const uniswapRouter = await UniswapRouter.deploy();

    const TownHallZap = await ethers.getContractFactory("TownHallZap");
    const townHallZap = await TownHallZap.deploy(
      townHall.address,
      huntToken.address,
      uniswapV3Router.address
    );

    await building.setTownHall(townHall.address);

    return [townHall, building, huntToken, townHallZap];
  }

  let townHall, building, huntToken, townHallZap;
  let owner, alice, bob;
  let LOCK_UP_AMOUNT, LOCK_UP_DURATION;
  const INITIAL_ALICE_BALANCE = 4500n * 10n ** 18n;

  beforeEach(async function () {
    [townHall, building, huntToken, townHallZap] = await loadFixture(
      deployFixtures
    );
    LOCK_UP_AMOUNT = (await townHall.LOCK_UP_AMOUNT()).toBigInt();
    LOCK_UP_DURATION = (await townHall.LOCK_UP_DURATION()).toBigInt();
    [owner, alice, bob] = await ethers.getSigners();
    await huntToken.transfer(alice.address, INITIAL_ALICE_BALANCE);
  });
});
