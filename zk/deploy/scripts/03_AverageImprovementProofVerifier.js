/**
 * 03_AverageImprovementProofVerifier.js
 * Amach Health ZK — Spring Push Verification Layer 2
 *
 * Deploy the snarkJS-generated Groth16 verifier for AverageImprovementProof
 * to zkSync Era Sepolia. Mirrors the workflow used by
 * `01_CoverageVerifier.js` so operators can deploy both via the same
 * hardhat-zksync-deploy plumbing.
 *
 * Run:
 *   DEPLOYER_KEY=<hex> npx hardhat deploy \
 *     --script scripts/03_AverageImprovementProofVerifier.js \
 *     --network zkSyncSepolia
 *
 * Output:
 *   Saves deployed address to ../data/deployed_contracts.json under the
 *   key `improvementVerifier` (next to `coverageVerifier`).
 */

'use strict';

const { Deployer } = require('@matterlabs/hardhat-zksync-deploy');
const { Wallet }   = require('zksync-ethers');
const fs   = require('fs');
const path = require('path');

const DATA_DIR       = path.join(__dirname, '../../data');
const CONTRACTS_FILE = path.join(DATA_DIR, 'deployed_contracts.json');

module.exports = async function deploy(hre) {
  const privateKey = process.env.DEPLOYER_KEY;
  if (!privateKey) {
    throw new Error(
      'DEPLOYER_KEY environment variable is required.\n' +
      'Usage: DEPLOYER_KEY=<hex> npx hardhat deploy --script scripts/03_AverageImprovementProofVerifier.js --network zkSyncSepolia'
    );
  }

  const wallet   = new Wallet(normalizeKey(privateKey));
  const deployer = new Deployer(hre, wallet);

  console.log('');
  console.log('════════════════════════════════════════════════');
  console.log('  Deploying AverageImprovementProofV1Verifier');
  console.log('  (Groth16Verifier emitted by snarkJS)');
  console.log('════════════════════════════════════════════════');
  console.log(`  Network:  ${hre.network.name}`);
  console.log(`  Deployer: ${wallet.address}`);
  console.log('');

  // The improvement verifier contract is also called `Groth16Verifier` by
  // snarkJS. Hardhat artifact resolution by contract name would collide
  // with `01_CoverageVerifier.js`'s identical name, so we resolve by the
  // fully-qualified `<file>:<contract>` form.
  const artifact = await deployer.loadArtifact(
    'contracts/AverageImprovementProofV1Verifier.sol:Groth16Verifier'
  );

  const deploymentFee = await deployer.estimateDeployFee(artifact, []);
  console.log(`  Estimated deployment fee: ${hre.ethers.formatEther(deploymentFee)} ETH`);
  console.log('');

  console.log('  Deploying...');
  const verifier = await deployer.deploy(artifact, []);
  await verifier.waitForDeployment();

  const address = await verifier.getAddress();
  console.log(`  ✅ AverageImprovementProofV1Verifier deployed to: ${address}`);
  console.log(`     Explorer: https://explorer.sepolia.era.zksync.dev/address/${address}`);

  fs.mkdirSync(DATA_DIR, { recursive: true });
  const existing = fs.existsSync(CONTRACTS_FILE)
    ? JSON.parse(fs.readFileSync(CONTRACTS_FILE, 'utf8'))
    : {};

  fs.writeFileSync(CONTRACTS_FILE, JSON.stringify({
    ...existing,
    improvementVerifier: address,
    improvementVerifierDeployedAt: new Date().toISOString(),
    improvementVerifierMetric: 'vo2max',
    improvementVerifierMetricPointer: 64,
    improvementVerifierN: 2,
    improvementVerifierM: 2,
    improvementVerifierTreeDepth: 7,
    network: hre.network.name,
    chainId: 300
  }, null, 2));

  console.log(`  Saved to data/deployed_contracts.json`);
  console.log('');

  return address;
};

module.exports.tags = ['ImprovementVerifier'];

function normalizeKey(key) {
  const stripped = key.replace(/^0x/, '');
  return '0x' + stripped;
}
