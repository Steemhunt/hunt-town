require('dotenv').config();
require('@nomicfoundation/hardhat-toolbox');

const ETH_MAINNET_RPC = process.env.ALCHEMY_ETH_API_KEY
  ? `https://eth-mainnet.alchemyapi.io/v2/${process.env.ALCHEMY_ETH_API_KEY}`
  : 'https://eth.llamarpc.com';
const ETH_GOERLI_RPC = process.env.ALCHEMY_GOERLI_API_KEY
  ? `https://eth-goerli.alchemyapi.io/v2/${process.env.ALCHEMY_GOERLI_API_KEY}`
  : 'https://goerli.infura.io/v3/9aa3d95b3bc440fa88ea12eaa4456161';

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    version: '0.8.17',
    settings: {
      optimizer: {
        enabled: true, // argv.enableGasReport || argv.compileMode === 'production',
        runs: 20000
      }
    }
  },
  networks: {
    hardhat: {
      forking: {
        url: ETH_MAINNET_RPC,
        blockNumber: 16288578
      }
    },
    goerli: {
      url: ETH_GOERLI_RPC,
      chainId: 5,
      accounts: [process.env.GOERLI_TEST_PRIVATE_KEY]
    },
    polygonmain: {
      url: `https://polygon-rpc.com`,
      chainId: 137,
      // gasPrice: 50000000000, // 50 GWei
      accounts: [process.env.GOERLI_TEST_PRIVATE_KEY]
    },
    ethmain: {
      url: ETH_MAINNET_RPC,
      chainId: 1,
      accounts: [process.env.ETH_PRIVATE_KEY]
    }
  },
  gasReporter: {
    enabled: true,
    currency: 'USD',
    gasPrice: 15,
    coinmarketcap: process.env.COIN_MARKET_CAP_API
  },
  etherscan: {
    // network list: https://github.com/NomicFoundation/hardhat/blob/master/packages/hardhat-etherscan/src/ChainConfig.ts
    apiKey: {
      goerli: process.env.ETHERSCAN_API_KEY,
      mainnet: process.env.ETHERSCAN_API_KEY,
      polygon: process.env.POLYGONSCAN_API_KEY
    }
  }
};
