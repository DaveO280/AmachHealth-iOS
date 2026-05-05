/**
 * hardhat.test.config.js
 * Test-only Hardhat config for the AverageImprovementProofV1Verifier
 * EVM unit tests.
 *
 * Why split from hardhat.config.js?
 *   The deployment config loads `hardhat-zksync-solc`, which replaces the
 *   default solc with zksolc. zksolc emits zkEVM bytecode that does NOT
 *   run under the local hardhat EVM, so unit tests against
 *   `verifyProof(...)` need the standard solc toolchain.
 *
 * Run:
 *   cd zk/deploy && npx hardhat --config hardhat.test.config.js test
 */

require('@nomicfoundation/hardhat-toolbox');

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    compilers: [
      // The verifier's pragma is `>=0.7.0 <0.9.0`. We pin 0.8.24 to match
      // the zksolc deployment build (avoids drift between EVM-test and
      // zkSync-deployed bytecode).
      {
        version: '0.8.24',
        settings: {
          optimizer: { enabled: true, runs: 200 }
        }
      }
    ]
  },

  paths: {
    sources:    './contracts',
    artifacts:  './artifacts-evm',
    cache:      './cache-evm',
    tests:      './test'
  },

  networks: {
    hardhat: {
      // Standard EVM (NOT zkSync). Plenty of gas for a Groth16 verifier.
      blockGasLimit: 30_000_000
    }
  }
};
