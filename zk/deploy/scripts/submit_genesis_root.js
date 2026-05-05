/**
 * submit_genesis_root.js
 * Amach Health ZK — Phase 5
 *
 * Submit the genesis Merkle root on-chain to the MerkleCommitment contract.
 * Reads genesis_tree.json (from Phase 3) and deployed_contracts.json (from Phase 5 deploy).
 *
 * Prerequisites:
 *   1. Contracts deployed:  PRIVATE_KEY=<hex> npx hardhat deploy --network zkSyncSepolia
 *   2. Genesis tree built:  node ../../scripts/generate_genesis_root.js ../../data/normalized_leaves.json
 *
 * Usage:
 *   PRIVATE_KEY=<hex> node scripts/submit_genesis_root.js
 *
 *   # Override contract address manually if needed:
 *   PRIVATE_KEY=<hex> CONTRACT_ADDRESS=<addr> node scripts/submit_genesis_root.js
 *
 * Network: ZKsync Era Sepolia (chainId 300)
 */

'use strict';

const { Provider, Wallet } = require('zksync-ethers');
const { ethers }           = require('ethers');
const fs   = require('fs');
const path = require('path');

const ZKSYNC_RPC      = 'https://sepolia.era.zksync.dev';
const DATA_DIR        = path.join(__dirname, '../../data');
const CONTRACTS_FILE  = path.join(DATA_DIR, 'deployed_contracts.json');
const TREE_FILE       = path.join(DATA_DIR, 'genesis_tree.json');

// MerkleCommitment ABI — only the functions we need
const MERKLE_COMMITMENT_ABI = [
  'function commitGenesisRoot(bytes32 root, bytes32 prevRoot, uint32 startDayId, uint32 endDayId, uint32 leafCount, uint8 rootType, uint8 syncType) external',
  'function getGenesisRoot(address wallet) external view returns (tuple(bytes32 root, bytes32 prevRoot, uint32 startDayId, uint32 endDayId, uint32 leafCount, uint8 rootType, uint8 syncType, uint256 committedAt))',
  'function hasGenesisRoot(address wallet) external view returns (bool)',
  'function coverageVerifier() external view returns (address)',
  'event GenesisRootCommitted(address indexed wallet, bytes32 root, uint32 startDayId, uint32 endDayId, uint32 leafCount, uint8 rootType, uint8 syncType, uint256 timestamp)'
];

async function main() {
  console.log('');
  console.log('════════════════════════════════════════════════');
  console.log('  AMACH HEALTH — Submit Genesis Root On-Chain');
  console.log('════════════════════════════════════════════════');
  console.log('');

  // ─── Load inputs ──────────────────────────────────────────────

  if (!fs.existsSync(TREE_FILE)) {
    console.error('❌ data/genesis_tree.json not found.');
    console.error('   Run: node scripts/generate_genesis_root.js data/normalized_leaves.json');
    process.exit(1);
  }

  const tree = JSON.parse(fs.readFileSync(TREE_FILE, 'utf8'));
  const rootHex = tree.rootPadded || tree.root;

  // Resolve contract address: env override, then deployed_contracts.json
  let contractAddress = process.env.CONTRACT_ADDRESS;
  if (!contractAddress) {
    if (!fs.existsSync(CONTRACTS_FILE)) {
      console.error('❌ data/deployed_contracts.json not found and CONTRACT_ADDRESS not set.');
      console.error('   Deploy contracts first: PRIVATE_KEY=<hex> npx hardhat deploy --network zkSyncSepolia');
      process.exit(1);
    }
    const deployed = JSON.parse(fs.readFileSync(CONTRACTS_FILE, 'utf8'));
    contractAddress = deployed.merkleCommitment;
    if (!contractAddress) {
      console.error('❌ merkleCommitment address not found in deployed_contracts.json.');
      console.error('   Run step 02 of deployment first.');
      process.exit(1);
    }
  }

  // ─── Show what will be submitted ─────────────────────────────

  console.log('  Genesis tree:');
  console.log(`    Root:       ${rootHex}`);
  console.log(`    Leaf count: ${tree.leafCount}`);
  console.log(`    Depth:      ${tree.depth}`);
  console.log(`    Start day:  ${tree.startDayId}`);
  console.log(`    End day:    ${tree.endDayId}`);
  console.log('');
  console.log(`  Contract:   ${contractAddress}`);
  console.log(`  Network:    zkSync Era Sepolia (chainId 300)`);
  console.log('');

  // ─── Dry run if no private key ─────────────────────────────────

  const privateKey = process.env.PRIVATE_KEY;
  if (!privateKey) {
    console.log('  ─── DRY RUN (no PRIVATE_KEY set) ───');
    console.log('  calldata that would be sent:');

    const iface = new ethers.Interface(MERKLE_COMMITMENT_ABI);
    const calldata = iface.encodeFunctionData('commitGenesisRoot', [
      padRoot(rootHex),
      ethers.ZeroHash,          // prevRoot = zero for genesis
      tree.startDayId,
      tree.endDayId,
      tree.leafCount,
      0,                        // rootType = genesis
      0                         // syncType = live
    ]);
    console.log(' ', calldata.slice(0, 90) + '...');
    console.log('');
    console.log('  To submit on-chain:');
    console.log(`  PRIVATE_KEY=<hex> node scripts/submit_genesis_root.js`);
    console.log('');
    return;
  }

  // ─── Connect to zkSync Era Sepolia ─────────────────────────────

  const provider = new Provider(ZKSYNC_RPC);
  const wallet   = new Wallet(`0x${privateKey.replace(/^0x/, '')}`, provider);

  console.log(`  Wallet: ${wallet.address}`);

  const balance = await provider.getBalance(wallet.address);
  console.log(`  Balance: ${ethers.formatEther(balance)} ETH`);
  console.log('');

  if (balance === 0n) {
    console.error('❌ Wallet has zero balance on zkSync Era Sepolia.');
    console.error('   Get testnet ETH from:');
    console.error('     https://faucet.quicknode.com/zksync/sepolia');
    console.error('     https://learnweb3.io/faucets/zksync_sepolia');
    process.exit(1);
  }

  // ─── Connect to contract ───────────────────────────────────────

  const contract = new ethers.Contract(contractAddress, MERKLE_COMMITMENT_ABI, wallet);

  // Check if genesis root already committed for this wallet
  const alreadyCommitted = await contract.hasGenesisRoot(wallet.address);
  if (alreadyCommitted) {
    console.log('⚠️  Genesis root already committed for this wallet.');
    const existing = await contract.getGenesisRoot(wallet.address);
    console.log(`   Existing root: 0x${BigInt(existing.root).toString(16).padStart(64, '0')}`);
    console.log(`   Committed at:  ${new Date(Number(existing.committedAt) * 1000).toISOString()}`);
    console.log('');
    console.log('  Genesis root commitment is one-time per wallet (immutable).');
    console.log('  To update health data, use the updateRoot() function (Phase 6).');
    return;
  }

  // ─── Submit genesis root ───────────────────────────────────────

  console.log('  Submitting genesis root...');

  const tx = await contract.commitGenesisRoot(
    padRoot(rootHex),
    ethers.ZeroHash,    // prevRoot = zero (this is the genesis commitment)
    tree.startDayId,
    tree.endDayId,
    tree.leafCount,
    0,                  // rootType = 0 (genesis)
    0                   // syncType = 0 (live sync)
  );

  console.log(`  Transaction sent: ${tx.hash}`);
  console.log(`  Explorer: https://explorer.sepolia.era.zksync.dev/tx/${tx.hash}`);
  console.log('  Waiting for confirmation...');

  const receipt = await tx.wait();
  const confirmed = receipt.status === 1;

  console.log('');
  if (confirmed) {
    console.log('  ✅ Genesis root committed on-chain!');
    console.log(`     Block:  ${receipt.blockNumber}`);
    console.log(`     Gas:    ${receipt.gasUsed.toString()}`);
  } else {
    console.log('  ❌ Transaction reverted.');
    console.log(`     Receipt: ${JSON.stringify(receipt, null, 2)}`);
    process.exit(1);
  }

  // ─── Verify the commitment was stored ─────────────────────────

  const stored = await contract.getGenesisRoot(wallet.address);
  const storedRoot = '0x' + BigInt(stored.root).toString(16).padStart(64, '0');
  const rootMatch  = storedRoot.toLowerCase() === padRoot(rootHex).toLowerCase();

  console.log('');
  console.log('  On-chain verification:');
  console.log(`    Root matches: ${rootMatch ? '✅' : '❌'}`);
  console.log(`    Start day:    ${stored.startDayId}`);
  console.log(`    End day:      ${stored.endDayId}`);
  console.log(`    Leaf count:   ${stored.leafCount}`);

  // ─── Save submission record ────────────────────────────────────

  const record = {
    txHash:      tx.hash,
    blockNumber: receipt.blockNumber,
    wallet:      wallet.address,
    contract:    contractAddress,
    root:        padRoot(rootHex),
    leafCount:   tree.leafCount,
    startDayId:  tree.startDayId,
    endDayId:    tree.endDayId,
    rootType:    0,
    syncType:    0,
    network:     'zkSyncSepolia (chainId 300)',
    submittedAt: new Date().toISOString()
  };

  fs.writeFileSync(
    path.join(DATA_DIR, 'genesis_submission.json'),
    JSON.stringify(record, null, 2)
  );

  console.log('');
  console.log('  Submission record saved to data/genesis_submission.json');
  console.log('');
  console.log('════════════════════════════════════════════════');
  console.log('  Genesis root is on-chain. Phase 5 complete.');
  console.log('  Next: Phase 6 — generate and submit coverage proof.');
  console.log('════════════════════════════════════════════════');
  console.log('');
}

/**
 * Ensure root is a 0x-prefixed 32-byte hex string.
 * Accepts either decimal BigInt string or hex with/without 0x.
 */
function padRoot(root) {
  let hex;
  if (root.startsWith('0x')) {
    hex = root.slice(2);
  } else if (/^\d+$/.test(root)) {
    hex = BigInt(root).toString(16);
  } else {
    hex = root;
  }
  return '0x' + hex.padStart(64, '0');
}

main().catch(err => {
  console.error('');
  console.error('❌ Fatal error:', err.message);
  console.error('');
  process.exit(1);
});
