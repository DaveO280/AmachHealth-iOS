/**
 * 02_MerkleCommitment.js
 * Amach Health ZK — Phase 5
 *
 * Deploy MerkleCommitment.sol to zkSync Era Sepolia.
 * Requires 01_CoverageVerifier.js to have run first (reads verifier address
 * from deployed_contracts.json).
 *
 * Run:
 *   PRIVATE_KEY=<hex> npx hardhat deploy --script scripts/02_MerkleCommitment.js --network zkSyncSepolia
 *
 * Or deploy both in sequence:
 *   PRIVATE_KEY=<hex> npx hardhat deploy --network zkSyncSepolia
 */

'use strict';

const { Deployer } = require('@matterlabs/hardhat-zksync-deploy');
const { Wallet }   = require('zksync-ethers');
const fs   = require('fs');
const path = require('path');

const CONTRACTS_FILE = path.join(__dirname, '../../data/deployed_contracts.json');

module.exports = async function deploy(hre) {
  const privateKey = process.env.DEPLOYER_KEY;
  if (!privateKey) {
    throw new Error('DEPLOYER_KEY environment variable is required.');
  }

  // Read verifier address written by step 01
  if (!fs.existsSync(CONTRACTS_FILE)) {
    throw new Error(
      'data/deployed_contracts.json not found.\n' +
      'Run 01_CoverageVerifier.js first:\n' +
      '  PRIVATE_KEY=<hex> npx hardhat deploy --script scripts/01_CoverageVerifier.js'
    );
  }

  const contracts = JSON.parse(fs.readFileSync(CONTRACTS_FILE, 'utf8'));
  const verifierAddress = contracts.coverageVerifier;

  if (!verifierAddress) {
    throw new Error('coverageVerifier address not found in deployed_contracts.json. Run step 01 first.');
  }

  const wallet   = new Wallet(`0x${privateKey.replace(/^0x/, '')}`);
  const deployer = new Deployer(hre, wallet);

  console.log('');
  console.log('════════════════════════════════════════════════');
  console.log('  Deploying MerkleCommitment');
  console.log('════════════════════════════════════════════════');
  console.log(`  Network:          ${hre.network.name}`);
  console.log(`  Deployer:         ${wallet.address}`);
  console.log(`  CoverageVerifier: ${verifierAddress}`);
  console.log('');

  const artifact = await deployer.loadArtifact('MerkleCommitment');

  const deploymentFee = await deployer.estimateDeployFee(artifact, [verifierAddress]);
  console.log(`  Estimated deployment fee: ${hre.ethers.formatEther(deploymentFee)} ETH`);
  console.log('');

  console.log('  Deploying...');
  const commitment = await deployer.deploy(artifact, [verifierAddress]);
  await commitment.waitForDeployment();

  const address = await commitment.getAddress();
  console.log(`  ✅ MerkleCommitment deployed to: ${address}`);
  console.log(`     Explorer: https://explorer.sepolia.era.zksync.dev/address/${address}`);

  // Verify the verifier is wired correctly
  const wiredVerifier = await commitment.coverageVerifier();
  const wiredOk = wiredVerifier.toLowerCase() === verifierAddress.toLowerCase();
  console.log(`  Verifier wired: ${wiredOk ? '✅' : '❌'} (${wiredVerifier})`);

  // Save addresses
  fs.writeFileSync(CONTRACTS_FILE, JSON.stringify({
    ...contracts,
    merkleCommitment: address,
    merkleCommitmentDeployedAt: new Date().toISOString()
  }, null, 2));

  console.log('  Saved to data/deployed_contracts.json');
  console.log('');
  console.log('════════════════════════════════════════════════');
  console.log('  Phase 5 deployment complete.');
  console.log('  Next: run the genesis pipeline, then submit root.');
  console.log('');
  console.log('  node ../scripts/generate_genesis_root.js ../data/normalized_leaves.json');
  console.log('  node ../scripts/generate_proof.js 0 89 20');
  console.log(`  CONTRACT_ADDRESS=${address} PRIVATE_KEY=<key> node scripts/submit_genesis_root.js`);
  console.log('════════════════════════════════════════════════');
  console.log('');

  return address;
};

module.exports.tags       = ['MerkleCommitment'];
module.exports.dependencies = ['CoverageVerifier'];
