import * as process from "node:process";

import "@nomicfoundation/hardhat-chai-matchers";
import "@nomicfoundation/hardhat-toolbox";
import "@typechain/hardhat";

import "dotenv/config";
import "tsconfig-paths/register";
import { HardhatUserConfig } from "hardhat/config";

import { mochaRootHooks } from "test/hooks";

import "./tasks";

import { getHardhatForkingConfig, loadAccounts } from "./hardhat.helpers";

const RPC_URL: string = process.env.RPC_URL || "";

export const ZERO_PK = "0x0000000000000000000000000000000000000000000000000000000000000000";

const config: HardhatUserConfig = {
  defaultNetwork: "hardhat",
  networks: {
    "local": {
      url: process.env.LOCAL_RPC_URL || RPC_URL,
    },
    "local-devnet": {
      url: process.env.LOCAL_RPC_URL || RPC_URL,
      accounts: [process.env.LOCAL_DEVNET_PK || ZERO_PK],
    },
    "mainnet-fork": {
      url: process.env.MAINNET_RPC_URL || RPC_URL,
      timeout: 20 * 60 * 1000, // 20 minutes
    },
    "hardhat": {
      // setting base fee to 0 to avoid extra calculations doesn't work :(
      // minimal base fee is 1 for EIP-1559
      // gasPrice: 0,
      // initialBaseFeePerGas: 0,
      blockGasLimit: 30000000,
      allowUnlimitedContractSize: true,
      accounts: {
        // default hardhat's node mnemonic
        mnemonic: "test test test test test test test test test test test junk",
        count: 30,
        accountsBalance: "100000000000000000000000",
      },
      forking: getHardhatForkingConfig(),
    },
    "sepolia": {
      url: RPC_URL,
      chainId: 11155111,
      accounts: loadAccounts("sepolia"),
    },
    "sepolia-fork": {
      url: process.env.SEPOLIA_RPC_URL || RPC_URL,
      chainId: 11155111,
    },
  },
  etherscan: {
    customChains: [
      {
        network: "local-devnet",
        chainId: parseInt(process.env.LOCAL_DEVNET_CHAIN_ID ?? "32382", 10),
        urls: {
          apiURL: process.env.LOCAL_DEVNET_EXPLORER_API_URL ?? "",
          browserURL: process.env.LOCAL_DEVNET_EXPLORER_URL ?? "",
        },
      },
    ],
    apiKey: process.env.LOCAL_DEVNET_EXPLORER_API_URL
      ? {
          "local-devnet": "local-devnet",
        }
      : process.env.ETHERSCAN_API_KEY || "",
  },
  solidity: {
    compilers: [
      {
        version: "0.4.24",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          },
          evmVersion: "constantinople",
        },
      },
      {
        version: "0.6.11",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          },
          evmVersion: "istanbul",
        },
      },
      {
        version: "0.6.12",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          },
          evmVersion: "istanbul",
        },
      },
      {
        version: "0.8.4",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          },
          evmVersion: "istanbul",
        },
      },
      {
        version: "0.8.9",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          },
          evmVersion: "istanbul",
        },
      },
    ],
  },
  typechain: {
    outDir: "typechain-types",
    target: "ethers-v6",
    alwaysGenerateOverloads: false,
    externalArtifacts: ["externalArtifacts/*.json"],
    dontOverrideCompile: false,
  },
  mocha: {
    rootHooks: mochaRootHooks,
    timeout: 20 * 60 * 1000, // 20 minutes
  },
};

export default config;
