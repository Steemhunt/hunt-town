const hre = require('hardhat');

async function main() {
  const accounts = await hre.ethers.getSigners();
  const deployer = accounts[0].address;
  console.log(`Deploy from account: ${deployer}`);

  const latestBlock = await hre.ethers.provider.getBlock('latest');
  const nonce = await hre.ethers.provider.getTransactionCount(deployer, 'latest');
  console.log(`Latest Block: ${latestBlock.number} / Nonce: ${nonce}`);

  let huntAddress = '0x9AAb071B4129B083B01cB5A0Cb513Ce7ecA26fa5';
  let townHallAddress = '0xb09A1410cF4C49F92482F5cd2CbF19b638907193';

  // For testnet
  if (hre.network.name === 'goerli' || hre.network.name === 'polygonmain') {
    huntAddress = '0x4bF67e5C9baD43DD89dbe8fCAD3c213C868fe881';
    townHallAddress = '0x794B9BC9c7316487D9fb31B6eEB8b9b57d958c3D';
  }

  console.log(`HUNT token address: ${huntAddress}`);
  console.log(`TownHall address: ${townHallAddress}`);

  const TownHallZap = await hre.ethers.getContractFactory('TownHallZap');
  const zap = await TownHallZap.deploy(townHallAddress, huntAddress, { nonce: nonce });
  console.log(`  -> Deploying TownHallZap contract`);
  console.log(`     - hash: ${zap.deployTransaction.hash}`);
  console.log(`     - gasPrice: ${zap.deployTransaction.gasPrice / 1e9}`);
  console.log(`     - nonce: ${zap.deployTransaction.nonce}`);
  await zap.deployed();
  console.log(` -> Zap contract deployed at ${zap.address}`);

  console.log(`\n\nNetwork: ${hre.network.name}`);
  console.log('```');
  console.log(`- TownHallZap: ${zap.address}`);
  console.log('```');

  console.log(`
    npx hardhat verify --network ${hre.network.name} ${zap.address} '${townHallAddress}' '${huntAddress}'
  `);
}

main()
  // eslint-disable-next-line no-process-exit
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    throw new Error(error);
  });

/* Deploy script

npx hardhat compile && npx hardhat run --network polygonmain scripts/deploy-zap.js
npx hardhat compile && npx hardhat run --network ethmain scripts/deploy-zap.js

*/
