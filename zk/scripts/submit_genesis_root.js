/**
 * submit_genesis_root.js
 * Amach Health ZK — Phase 5
 *
 * Submit the genesis Merkle root on-chain to the Amach attestation contract.
 * Reads the genesis_tree.json output from Phase 3.
 *
 * Prerequisites:
 *   - PRIVATE_KEY env var: wallet private key (hex, no 0x)
 *   - CONTRACT_ADDRESS env var: deployed AmachAttestation contract address
 *   - data/genesis_tree.json: from generate_genesis_root.js
 *
 * Usage:
 *   PRIVATE_KEY=<key> CONTRACT_ADDRESS=<addr> node scripts/submit_genesis_root.js
 *
 * Or with hardhat:
 *   npx hardhat run scripts/submit_genesis_root.js --network zkSyncTestnet
 *
 * Network: ZKsync Era Sepolia testnet
 *   RPC: https://sepolia.era.zksync.dev
 *   Chain ID: 300
 */

'use strict';

const fs = require('fs');
const path = require('path');
const https = require('https');

const BASE = path.join(__dirname, '..');
const ZKSYNC_RPC = 'https://sepolia.era.zksync.dev';
const CHAIN_ID = 300;

// ABI-encoded function selector for commitGenesisRoot(bytes32,bytes32,uint32,uint32,uint32,uint8,uint8)
// keccak256("commitGenesisRoot(bytes32,bytes32,uint32,uint32,uint32,uint8,uint8)") → first 4 bytes
// Recompute if contract signature changes.
const COMMIT_GENESIS_SELECTOR = 'a3b4c5d6'; // TODO: replace with actual keccak256 of ABI signature

/**
 * Left-pad a hex string to `bytes` bytes (2*bytes hex chars).
 */
function padLeft(hex, bytes) {
  const target = bytes * 2;
  const stripped = hex.replace(/^0x/, '');
  return stripped.padStart(target, '0').slice(-target);
}

/**
 * ABI-encode commitGenesisRoot call.
 * All fixed-size params → each padded to 32 bytes after 4-byte selector.
 */
function encodeCommitGenesisRoot({ root, prevRoot, startDayId, endDayId, leafCount, rootType, syncType }) {
  const rootHex        = padLeft(root.replace(/^0x/, ''), 32);
  const prevRootHex    = padLeft((prevRoot || '0').replace(/^0x/, ''), 32);
  const startDayIdHex  = padLeft(startDayId.toString(16), 32);
  const endDayIdHex    = padLeft(endDayId.toString(16), 32);
  const leafCountHex   = padLeft(leafCount.toString(16), 32);
  const rootTypeHex    = padLeft((rootType || 0).toString(16), 32);
  const syncTypeHex    = padLeft((syncType || 0).toString(16), 32);

  return '0x' + COMMIT_GENESIS_SELECTOR
    + rootHex + prevRootHex + startDayIdHex + endDayIdHex
    + leafCountHex + rootTypeHex + syncTypeHex;
}

/**
 * Send a JSON-RPC request to the zkSync Era Sepolia node.
 */
function rpcCall(method, params) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({ jsonrpc: '2.0', id: 1, method, params });
    const url = new URL(ZKSYNC_RPC);

    const req = https.request({
      hostname: url.hostname,
      path: url.pathname,
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(body)
      }
    }, res => {
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => {
        try {
          const json = JSON.parse(data);
          if (json.error) reject(new Error(`RPC error: ${json.error.message}`));
          else resolve(json.result);
        } catch (e) {
          reject(new Error(`Invalid JSON response: ${data}`));
        }
      });
    });

    req.on('error', reject);
    req.write(body);
    req.end();
  });
}

async function main() {
  const privateKey = process.env.PRIVATE_KEY;
  const contractAddress = process.env.CONTRACT_ADDRESS;

  if (!privateKey || !contractAddress) {
    console.log('Usage:');
    console.log('  PRIVATE_KEY=<hex> CONTRACT_ADDRESS=<addr> node scripts/submit_genesis_root.js');
    console.log('');
    console.log('Or via Hardhat:');
    console.log('  npx hardhat run scripts/submit_genesis_root.js --network zkSyncTestnet');

    // Dry run mode — show what would be submitted
    const treePath = path.join(BASE, 'data/genesis_tree.json');
    if (fs.existsSync(treePath)) {
      const tree = JSON.parse(fs.readFileSync(treePath, 'utf8'));
      console.log('');
      console.log('═══════════════════════════════════════════════');
      console.log('  DRY RUN — Genesis Root Ready for Submission');
      console.log('═══════════════════════════════════════════════');
      console.log(`  Root:       ${tree.rootPadded || tree.root}`);
      console.log(`  Leaf count: ${tree.leafCount}`);
      console.log(`  Depth:      ${tree.depth}`);
      console.log(`  Start day:  ${tree.startDayId}`);
      console.log(`  End day:    ${tree.endDayId}`);
      console.log(`  Root type:  0 (genesis)`);
      console.log(`  Sync type:  0 (live)`);
      console.log('');
      console.log('  calldata:');
      const calldata = encodeCommitGenesisRoot({
        root: tree.rootPadded || tree.root,
        prevRoot: '0x0000000000000000000000000000000000000000000000000000000000000000',
        startDayId: tree.startDayId,
        endDayId: tree.endDayId,
        leafCount: tree.leafCount,
        rootType: 0,
        syncType: 0
      });
      console.log(' ', calldata.slice(0, 80) + '...');
      console.log('');
      console.log('  Provide PRIVATE_KEY and CONTRACT_ADDRESS to submit on-chain.');
    }
    return;
  }

  // Load genesis tree
  const treePath = path.join(BASE, 'data/genesis_tree.json');
  if (!fs.existsSync(treePath)) {
    console.error('❌ data/genesis_tree.json not found. Run generate_genesis_root.js first.');
    process.exit(1);
  }

  const tree = JSON.parse(fs.readFileSync(treePath, 'utf8'));

  console.log('');
  console.log('═══════════════════════════════════════════════');
  console.log('  SUBMITTING GENESIS ROOT ON-CHAIN');
  console.log('═══════════════════════════════════════════════');
  console.log(`  Network:  ZKsync Era Sepolia (chainId ${CHAIN_ID})`);
  console.log(`  Contract: ${contractAddress}`);
  console.log(`  Root:     ${tree.rootPadded || tree.root}`);
  console.log('');

  // Get nonce
  // Note: In production use ethers.js / zksync-ethers with a proper signer.
  // This is a minimal raw RPC implementation for testing.
  console.log('⚠️  For production use, integrate with zksync-ethers:');
  console.log('   npm install zksync-ethers ethers');
  console.log('   See: https://docs.zksync.io/sdk/ethers/v6/getting-started');
  console.log('');
  console.log('Genesis root is ready. Use the calldata from the dry run');
  console.log('and submit via your Hardhat deploy script or ethers.js integration.');

  // Save submission record
  const submissionData = {
    root: tree.rootPadded || tree.root,
    leafCount: tree.leafCount,
    startDayId: tree.startDayId,
    endDayId: tree.endDayId,
    rootType: 0,
    syncType: 0,
    network: `zkSyncTestnet (chainId ${CHAIN_ID})`,
    contract: contractAddress || 'not set',
    preparedAt: Date.now()
  };

  const dataDir = path.join(BASE, 'data');
  fs.writeFileSync(
    path.join(dataDir, 'genesis_submission.json'),
    JSON.stringify(submissionData, null, 2)
  );
  console.log('Submission data saved to data/genesis_submission.json');
}

main().catch(err => {
  console.error('❌ Error:', err.message);
  process.exit(1);
});
