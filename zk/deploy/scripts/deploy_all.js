/**
 * deploy_all.js
 * Amach Health ZK — Phase 5
 *
 * Deploy CoverageVerifier + MerkleCommitment to zkSync Era Sepolia.
 * Uses zksync-ethers directly — no Hardhat deploy plugin needed.
 * Reads compiled zkEVM artifacts from artifacts-zk/ (built by setup_phase5.sh).
 *
 * Usage:
 *   DEPLOYER_KEY=<hex> node scripts/deploy_all.js
 *
 * Network: zkSync Era Sepolia (chainId 300)
 */

'use strict';

const { Provider, Wallet, ContractFactory } = require('zksync-ethers');
const { ethers } = require('ethers');
const fs   = require('fs');
const path = require('path');

const ZKSYNC_RPC     = 'https://sepolia.era.zksync.dev';
const ARTIFACTS_DIR  = path.join(__dirname, '../artifacts-zk/contracts');
const CONTRACTS_FILE = path.join(__dirname, '../../data/deployed_contracts.json');
const DATA_DIR       = path.join(__dirname, '../../data');

/**
 * Load a compiled zkEVM artifact by contract file name and contract name.
 * artifacts-zk/contracts/{FileName}.sol/{ContractName}.json
 */
function loadArtifact(fileName, contractName) {
  const artifactPath = path.join(ARTIFACTS_DIR, `${fileName}.sol`, `${contractName}.json`);
  if (!fs.existsSync(artifactPath)) {
    throw new Error(
      `Artifact not found: ${artifactPath}\n` +
      `Run setup_phase5.sh first to compile contracts.`
    );
  }
  return JSON.parse(fs.readFileSync(artifactPath, 'utf8'));
}

async function main() {
  const deployerKey = process.env.DEPLOYER_KEY;
  if (!deployerKey) {
    console.error('❌ DEPLOYER_KEY environment variable is required.');
    console.error('   Usage: DEPLOYER_KEY=<hex> node scripts/deploy_all.js');
    process.exit(1);
  }

  console.log('');
  console.log('════════════════════════════════════════════════');
  console.log('  AMACH HEALTH — Phase 5 Contract Deployment');
  console.log('════════════════════════════════════════════════');
  console.log(`  Network: zkSync Era Sepolia (chainId 300)`);
  console.log(`  RPC:     ${ZKSYNC_RPC}`);
  console.log('');

  // ─── Connect ──────────────────────────────────────────────────
  const provider = new Provider(ZKSYNC_RPC);
  const wallet   = new Wallet(`0x${deployerKey.replace(/^0x/, '')}`, provider);

  console.log(`  Deployer: ${wallet.address}`);

  const balance = await provider.getBalance(wallet.address);
  console.log(`  Balance:  ${ethers.formatEther(balance)} ETH`);
  console.log('');

  if (balance === 0n) {
    console.error('❌ Deployer wallet has zero balance on zkSync Era Sepolia.');
    console.error('   Get testnet ETH from:');
    console.error('     https://faucet.quicknode.com/zksync/sepolia');
    console.error('     https://learnweb3.io/faucets/zksync_sepolia');
    process.exit(1);
  }

  // ─── Deploy CoverageVerifier ───────────────────────────────────
  console.log('  ── Step 1: Deploy CoverageVerifier (Groth16Verifier) ──');

  const verifierArtifact = loadArtifact('CoverageVerifier', 'Groth16Verifier');
  const verifierFactory  = new ContractFactory(
    verifierArtifact.abi,
    verifierArtifact.bytecode,
    wallet
  );

  const verifier = await verifierFactory.deploy();
  await verifier.waitForDeployment();
  const verifierAddress = await verifier.getAddress();

  console.log(`  ✅ CoverageVerifier deployed: ${verifierAddress}`);
  console.log(`     https://explorer.sepolia.era.zksync.dev/address/${verifierAddress}`);
  console.log('');

  // ─── Deploy MerkleCommitment ───────────────────────────────────
  console.log('  ── Step 2: Deploy MerkleCommitment ──');

  const commitmentArtifact = loadArtifact('MerkleCommitment', 'MerkleCommitment');
  const commitmentFactory  = new ContractFactory(
    commitmentArtifact.abi,
    commitmentArtifact.bytecode,
    wallet
  );

  const commitment = await commitmentFactory.deploy(verifierAddress);
  await commitment.waitForDeployment();
  const commitmentAddress = await commitment.getAddress();

  console.log(`  ✅ MerkleCommitment deployed: ${commitmentAddress}`);
  console.log(`     https://explorer.sepolia.era.zksync.dev/address/${commitmentAddress}`);
  console.log('');

  // ─── Verify wiring ────────────────────────────────────────────
  const wiredVerifier = await commitment.coverageVerifier();
  const wiredOk = wiredVerifier.toLowerCase() === verifierAddress.toLowerCase();
  console.log(`  Verifier wired correctly: ${wiredOk ? '✅' : '❌'} (${wiredVerifier})`);
  console.log('');

  // ─── Save addresses ───────────────────────────────────────────
  fs.mkdirSync(DATA_DIR, { recursive: true });
  const existing = fs.existsSync(CONTRACTS_FILE)
    ? JSON.parse(fs.readFileSync(CONTRACTS_FILE, 'utf8'))
    : {};

  const record = {
    ...existing,
    coverageVerifier:             verifierAddress,
    merkleCommitment:             commitmentAddress,
    coverageVerifierDeployedAt:   new Date().toISOString(),
    merkleCommitmentDeployedAt:   new Date().toISOString(),
    deployer:                     wallet.address,
    network:                      'zkSyncSepolia',
    chainId:                      300
  };

  fs.writeFileSync(CONTRACTS_FILE, JSON.stringify(record, null, 2));
  console.log('  Addresses saved to data/deployed_contracts.json');

  // ─── Summary ──────────────────────────────────────────────────
  console.log('');
  console.log('════════════════════════════════════════════════');
  console.log('  Phase 5 deployment complete.');
  console.log('');
  console.log('  Next: run the genesis pipeline, then submit root.');
  console.log('');
  console.log('  node ../scripts/generate_genesis_root.js ../data/normalized_leaves.json');
  console.log(`  PRIVATE_KEY=<user-key> node scripts/submit_genesis_root.js`);
  console.log('════════════════════════════════════════════════');
  console.log('');
}

main().catch(err => {
  console.error('');
  console.error('❌ Deployment failed:', err.message);
  if (err.stack) console.error(err.stack);
  process.exit(1);
});
