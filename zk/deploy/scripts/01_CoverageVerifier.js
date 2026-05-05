/**
 * 01_CoverageVerifier.js
 * Amach Health ZK — Phase 5
 *
 * Deploy the snarkJS-generated Groth16 verifier contract to zkSync Era Sepolia.
 * This contract contains the hard-coded verification key from the trusted setup
 * and verifies proofs entirely on-chain.
 *
 * Run:
 *   PRIVATE_KEY=<hex> npx hardhat deploy --script scripts/01_CoverageVerifier.js --network zkSyncSepolia
 *
 * Output:
 *   Saves deployed address to ../data/deployed_contracts.json
 */

'use strict';

const { Deployer } = require('@matterlabs/hardhat-zksync-deploy');
const { Wallet }   = require('zksync-ethers');
const fs   = require('fs');
const path = require('path');

const DATA_DIR      = path.join(__dirname, '../../data');
const CONTRACTS_FILE = path.join(DATA_DIR, 'deployed_contracts.json');

module.exports = async function deploy(hre) {
  const privateKey = process.env.DEPLOYER_KEY;
  if (!privateKey) {
    throw new Error('DEPLOYER_KEY environment variable is required.\nUsage: DEPLOYER_KEY=<hex> npx hardhat deploy --script scripts/01_CoverageVerifier.js');
  }

  const wallet   = new Wallet(normalizeKey(privateKey));
  const deployer = new Deployer(hre, wallet);

  console.log('');
  console.log('════════════════════════════════════════════════');
  console.log('  Deploying CoverageVerifier (Groth16Verifier)');
  console.log('════════════════════════════════════════════════');
  console.log(`  Network:  ${hre.network.name}`);
  console.log(`  Deployer: ${wallet.address}`);
  console.log('');

  // The snarkJS-generated contract is named Groth16Verifier
  const artifact = await deployer.loadArtifact('Groth16Verifier');

  // Estimate deployment fee
  const deploymentFee = await deployer.estimateDeployFee(artifact, []);
  console.log(`  Estimated deployment fee: ${hre.ethers.formatEther(deploymentFee)} ETH`);
  console.log('');

  console.log('  Deploying...');
  const verifier = await deployer.deploy(artifact, []);
  await verifier.waitForDeployment();

  const address = await verifier.getAddress();
  console.log(`  ✅ CoverageVerifier deployed to: ${address}`);
  console.log(`     Explorer: https://explorer.sepolia.era.zksync.dev/address/${address}`);

  // Save for 02_MerkleCommitment.js
  fs.mkdirSync(DATA_DIR, { recursive: true });
  const existing = fs.existsSync(CONTRACTS_FILE)
    ? JSON.parse(fs.readFileSync(CONTRACTS_FILE, 'utf8'))
    : {};

  fs.writeFileSync(CONTRACTS_FILE, JSON.stringify({
    ...existing,
    coverageVerifier: address,
    coverageVerifierDeployedAt: new Date().toISOString(),
    network: hre.network.name,
    chainId: 300
  }, null, 2));

  console.log(`  Saved to data/deployed_contracts.json`);
  console.log('');

  return address;
};

module.exports.tags = ['CoverageVerifier'];

function normalizeKey(key) {
  const stripped = key.replace(/^0x/, '');
  return '0x' + stripped;
}
