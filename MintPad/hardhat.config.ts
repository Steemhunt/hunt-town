import type { HardhatUserConfig } from "hardhat/config";
import hardhatVerify from "@nomicfoundation/hardhat-verify";
import hardhatToolboxViemPlugin from "@nomicfoundation/hardhat-toolbox-viem";
import { configVariable } from "hardhat/config";
import "dotenv/config";

const config: HardhatUserConfig = {
  plugins: [hardhatToolboxViemPlugin, hardhatVerify],
  solidity: {
    profiles: {
      default: {
        version: "0.8.30"
      },
      production: {
        version: "0.8.30",
        settings: {
          optimizer: {
            enabled: true,
            runs: 20000
          }
        }
      }
    }
  },
  networks: {
    baseFork: {
      type: "edr-simulated",
      forking: {
        url: process.env.RPC_BASE!,
        blockNumber: 37720000 // 2025-11-04 13:09:07 KST
      },
      initialBaseFeePerGas: 1000000 // 1 gwei - low enough for tests
    },
    hardhatMainnet: {
      type: "edr-simulated",
      chainType: "l1"
    },
    hardhatOp: {
      type: "edr-simulated",
      chainType: "op"
    },
    base: {
      type: "http",
      chainType: "l1",
      url: process.env.RPC_BASE!,
      accounts: [configVariable("MINTPAD_TEST_DEPLOYER")]
    }
  },
  verify: {
    etherscan: {
      apiKey: process.env.ETHERSCAN_API_KEY!
    }
  }
};

export default config;
