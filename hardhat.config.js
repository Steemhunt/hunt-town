require('dotenv').config();

require("@nomicfoundation/hardhat-toolbox");

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    version: '0.8.17',
    settings: {
      optimizer: {
        enabled: true, // argv.enableGasReport || argv.compileMode === 'production',
        runs: 20000,
      },
    },
  },
  networks: {
    goerli: {
      url: `https://eth-goerli.alchemyapi.io/v2/${process.env.ALCHEMY_GOERLI_API_KEY}`,
      chainId: 5,
      accounts: [process.env.GOERLI_TEST_PRIVATE_KEY]
    },
    polygonmain: {
      url: `https://polygon-rpc.com/`,
      chainId: 137,
      accounts: [process.env.GOERLI_TEST_PRIVATE_KEY]
    },
    ethmain: {
      url: `https://eth-mainnet.alchemyapi.io/v2/${process.env.ALCHEMY_ETH_API_KEY}`,
      chainId: 1,
      accounts: [process.env.ETH_PRIVATE_KEY]
    }
  },
  gasReporter: {
    enabled: true,
    currency: 'USD',
    gasPrice: 20,
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
