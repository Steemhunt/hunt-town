import type { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox-viem";
require("dotenv").config();

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.26",
    settings: {
      optimizer: {
        enabled: true,
        runs: 20000
      }
    }
  },
  networks: {
    hardhat: {
      forking: {
        url: `https://base-mainnet.g.alchemy.com/v2/${process.env.ALCHEMY_API_KEY}`,
        blockNumber: 17162466
      }
    },
    base: {
      url: `https://base-mainnet.g.alchemy.com/v2/${process.env.ALCHEMY_API_KEY}`,
      chainId: 8453,
      accounts: [process.env.PKEY!]
    }
  },
  gasReporter: {
    // FIXME: not working properly with viem?
    enabled: true,
    currency: "USD",
    gasPrice: 15,
    coinmarketcap: undefined
  },
  etherscan: {
    // network list: npx hardhat verify --list-networks
    apiKey: {
      base: process.env.BASESCAN_API_KEY!
    }
  }
};

export default config;
