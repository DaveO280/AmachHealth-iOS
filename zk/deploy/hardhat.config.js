/**
 * hardhat.config.js
 * Amach Health ZK — Phase 5
 *
 * Hardhat config for deploying ZK verifier contracts to zkSync Era Sepolia.
 *
 * Prerequisites:
 *   npm install (in this deploy/ directory)
 *   npx hardhat compile
 *
 * Deployment:
 *   PRIVATE_KEY=<hex> npx hardhat deploy --network zkSyncSepolia
 *
 * Faucet (get testnet ETH):
 *   https://faucet.quicknode.com/zksync/sepolia
 *   https://learnweb3.io/faucets/zksync_sepolia
 *
 * Explorer:
 *   https://explorer.sepolia.era.zksync.dev
 */

require('@matterlabs/hardhat-zksync-solc');
require('@matterlabs/hardhat-zksync-deploy');

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  // zksolc compiler — required for zkSync Era EVM bytecode
  zksolc: {
    version: '1.5.15',
    settings: {
      // evmla matches solc's default codegen — avoids the Yul divergence warning
      // and ensures bytecode behaviour matches what was tested on EVM
      codegen: 'evmla',
      optimizer: {
        enabled: true,
        runs: 200
      }
    }
  },

  // solc version — must satisfy both contract pragmas:
  //   CoverageVerifier.sol: >=0.7.0 <0.9.0
  //   MerkleCommitment.sol: ^0.8.24
  solidity: {
    version: '0.8.24'
  },

  defaultNetwork: 'zkSyncSepolia',

  networks: {
    // Local hardhat network (non-zksync) — useful for ABI checks
    hardhat: {
      zksync: false
    },

    // zkSync Era Sepolia testnet
    zkSyncSepolia: {
      url: 'https://sepolia.era.zksync.dev',
      ethNetwork: 'sepolia',
      zksync: true,
      chainId: 300,
      verifyURL: 'https://explorer.sepolia.era.zksync.dev/contract_verification',
      accounts: process.env.DEPLOYER_KEY
        ? [`0x${process.env.DEPLOYER_KEY.replace(/^0x/, '')}`]
        : []
    }
  },

  paths: {
    // Contracts copied here by setup_phase5.sh before each compile run
    // (copied from ../circuits/coverage/ so CoverageVerifier.sol stays fresh)
    sources:      './contracts',
    artifacts:    './artifacts-zk',   // hardhat-zksync-solc outputs here by default
    cache:        './cache-zk',
    deploy:       './scripts'
  }
};
