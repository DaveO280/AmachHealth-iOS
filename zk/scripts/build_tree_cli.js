/**
 * build_tree_cli.js
 * Amach Health ZK — Phase 3/6
 *
 * CLI wrapper for the Merkle tree builder. Called by MerkleTreeBuilder.swift.
 *
 * Input:  JSON file — Array of { dayId, serialized, hash } objects
 *         (output from hash_leaves_batch.js)
 *
 * Output: JSON file — Full genesis tree structure
 *         { root, rootPadded, tree[][], leafHashes[], leafCount, treeSize, depth, startDayId, endDayId }
 *
 * Usage:
 *   node scripts/build_tree_cli.js input.json output.json
 */

'use strict';

const { buildMerkleTree, serializeTree } = require('./build_tree');
const { hashLeaf, V1_LEAF_BYTES, V2_LEAF_BYTES } = require('./hash_leaf');
const fs = require('fs');

const V1_HEX_LEN = V1_LEAF_BYTES * 2; // 180
const V2_HEX_LEN = V2_LEAF_BYTES * 2; // 248

const inputPath = process.argv[2];
const outputPath = process.argv[3];

if (!inputPath || !outputPath) {
  console.error('Usage: node build_tree_cli.js <input.json> <output.json>');
  process.exit(1);
}

if (!fs.existsSync(inputPath)) {
  console.error(`Input file not found: ${inputPath}`);
  process.exit(1);
}

const leaves = JSON.parse(fs.readFileSync(inputPath, 'utf8'));

if (!Array.isArray(leaves) || leaves.length === 0) {
  console.error('Input must be a non-empty JSON array');
  process.exit(1);
}

// Validate sort order
for (let i = 1; i < leaves.length; i++) {
  if (leaves[i].dayId <= leaves[i - 1].dayId) {
    console.error(`Leaves must be sorted ascending by dayId. dayId[${i-1}]=${leaves[i-1].dayId} >= dayId[${i}]=${leaves[i].dayId}`);
    process.exit(1);
  }
}

// Convert to leaf Buffers. Accept either v1 (90 bytes / 180 hex) or v2
// (124 bytes / 248 hex) — buildMerkleTree dispatches on length.
const leafBuffers = leaves.map((leaf, i) => {
  if (!leaf.serialized) {
    throw new Error(`Leaf ${i} (dayId=${leaf.dayId}): missing serialized field`);
  }
  if (leaf.serialized.length !== V1_HEX_LEN && leaf.serialized.length !== V2_HEX_LEN) {
    throw new Error(
      `Leaf ${i} (dayId=${leaf.dayId}): unsupported serialized length ` +
      `${leaf.serialized.length} hex chars. Expected ${V1_HEX_LEN} (v1) or ${V2_HEX_LEN} (v2).`
    );
  }
  return Buffer.from(leaf.serialized, 'hex');
});

// Build tree
const startDayId = leaves[0].dayId;
const endDayId = leaves[leaves.length - 1].dayId;

const treeResult = buildMerkleTree(leafBuffers);

const output = {
  ...serializeTree(treeResult),
  startDayId,
  endDayId,
  rootPadded: '0x' + treeResult.root.toString(16).padStart(64, '0')
};

// Convert to format expected by MerkleTreeBuilder.swift parseTreeOutput()
// tree[][] needs to be string arrays
const swiftOutput = {
  root: treeResult.root.toString(16),
  rootPadded: output.rootPadded,
  leafCount: treeResult.leafCount,
  treeSize: treeResult.treeSize,
  depth: treeResult.depth,
  tree: treeResult.tree.map(level => level.map(n => n.toString(16))),
  leafHashes: treeResult.leafHashes.map(n => n.toString(16)),
  startDayId,
  endDayId,
  generatedAt: Date.now()
};

fs.writeFileSync(outputPath, JSON.stringify(swiftOutput, null, 2));

console.log(`Genesis tree built:`);
console.log(`  Leaves: ${treeResult.leafCount}`);
console.log(`  Depth:  ${treeResult.depth}`);
console.log(`  Root:   0x${treeResult.root.toString(16).slice(0, 32)}...`);
console.log(`Output → ${outputPath}`);
