const hre = require("hardhat");

async function main() {
  const accounts = await hre.ethers.getSigners();
  const deployer = accounts[0].address;
  console.log(`Deploy from account: ${deployer}`);

  let huntAddress = "0x9AAb071B4129B083B01cB5A0Cb513Ce7ecA26fa5";
  if (hre.network.name === "goerli" || hre.network.name === "polygonmain") {
    const HuntTokenMock = await hre.ethers.getContractFactory('HuntTokenMock');
    const token = await HuntTokenMock.deploy();
    await token.deployed();

    huntAddress = token.address;
    console.log(` -> Test HUNT token contract deployed at ${huntAddress}`);

    // huntAddress = "0x9AAb071B4129B083B01cB5A0Cb513Ce7ecA26fa5"; // Use an existing one
  }

  console.log(`HUNT token address: ${huntAddress}`);

  const Building = await hre.ethers.getContractFactory('Building');
  const building = await Building.deploy();
  await building.deployed();
  console.log(` -> Building contract deployed at ${building.address}`);

  const TownHall = await hre.ethers.getContractFactory('TownHall');
  const townHall = await TownHall.deploy(building.address, huntAddress);
  await townHall.deployed();
  console.log(` -> TownHall contract deployed at ${townHall.address}`);

  console.log(`\n\nNetwork: ${hre.network.name}`);
  console.log('```');
  console.log(`- TownHall: ${townHall.address}`);
  console.log(`- Building: ${building.address}`);
  console.log(`- HUNT: ${huntAddress}`);
  console.log('```');

  console.log(`
    npx hardhat verify --network ${hre.network.name} ${building.address}
    npx hardhat verify --network ${hre.network.name} ${townHall.address} '${building.address}' '${huntAddress}'
  `);
};

main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });


/* Deploy script

npx hardhat compile && npx hardhat run --network polygonmain scripts/deploy.js

*/
