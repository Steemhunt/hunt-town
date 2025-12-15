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
        blockNumber: 39501366 // Dec-15-2025 09:47:59 AM +UTC
      },
      initialBaseFeePerGas: 100000 // Very low for fork tests
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
      accounts: [configVariable("MINTPAD_DEPLOYER")]
    }
  },
  verify: {
    etherscan: {
      apiKey: process.env.ETHERSCAN_API_KEY!
    }
  }
};

export default config;
