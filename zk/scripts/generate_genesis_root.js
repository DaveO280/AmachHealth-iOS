/**
 * generate_genesis_root.js
 * Amach Health ZK — Phase 3
 *
 * Full pipeline: normalized_leaves.json → genesis_root.json
 *
 * Input:  normalized_leaves.json
 *         Array of { dayId, serialized } objects where `serialized` is
 *         the hex-encoded 90-byte leaf (output from iOS MerkleNormalizationService)
 *
 * Output: genesis_tree.json
 *         Full Merkle tree + root for Storj storage
 *
 * Usage:
 *   node scripts/generate_genesis_root.js [path/to/normalized_leaves.json]
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { buildMerkleTree, serializeTree } = require('./build_tree');

async function main() {
  const inputPath = process.argv[2] || path.join(__dirname, '../data/normalized_leaves.json');
  const outputDir = path.join(__dirname, '../data');
  const outputPath = path.join(outputDir, 'genesis_tree.json');

  if (!fs.existsSync(inputPath)) {
    console.error(`❌ Input file not found: ${inputPath}`);
    console.error('');
    console.error('Expected format: JSON array of { dayId, serialized } objects');
    console.error('  dayId:      uint32 — days since 2024-01-01');
    console.error('  serialized: string — 90-byte leaf as hex (no 0x prefix)');
    console.error('');
    console.error('Generate this file by running the iOS normalization pipeline and');
    console.error('exporting leaves via MerkleNormalizationService.');
    process.exit(1);
  }

  // Load normalized leaves
  const rawJson = fs.readFileSync(inputPath, 'utf8');
  const normalizedLeaves = JSON.parse(rawJson);

  if (!Array.isArray(normalizedLeaves) || normalizedLeaves.length === 0) {
    console.error('❌ Input must be a non-empty JSON array');
    process.exit(1);
  }

  console.log(`📥 Loaded ${normalizedLeaves.length} normalized leaves from ${inputPath}`);

  // Validate and convert to Buffers
  const leafBuffers = normalizedLeaves.map((leaf, i) => {
    if (typeof leaf.serialized !== 'string' || leaf.serialized.length !== 180) {
      throw new Error(`Leaf ${i} (dayId=${leaf.dayId}): invalid serialized field — expected 180 hex chars`);
    }
    const buf = Buffer.from(leaf.serialized, 'hex');
    if (buf.length !== 90) {
      throw new Error(`Leaf ${i}: buffer is ${buf.length} bytes, expected 90`);
    }
    return buf;
  });

  // Verify leaves are sorted by dayId
  for (let i = 1; i < normalizedLeaves.length; i++) {
    if (normalizedLeaves[i].dayId <= normalizedLeaves[i - 1].dayId) {
      throw new Error(
        `Leaves must be sorted ascending by dayId. ` +
        `dayId[${i - 1}]=${normalizedLeaves[i - 1].dayId} >= dayId[${i}]=${normalizedLeaves[i].dayId}`
      );
    }
  }

  console.log(`🌳 Building Merkle tree...`);

  const startMs = Date.now();
  const treeResult = buildMerkleTree(leafBuffers);
  const elapsed = Date.now() - startMs;

  const startDayId = normalizedLeaves[0].dayId;
  const endDayId = normalizedLeaves[normalizedLeaves.length - 1].dayId;

  console.log('');
  console.log('═══════════════════════════════════════════════');
  console.log('  GENESIS MERKLE ROOT');
  console.log('═══════════════════════════════════════════════');
  console.log(`  Root:         0x${treeResult.root.toString(16).padStart(64, '0')}`);
  console.log(`  Leaf count:   ${treeResult.leafCount}`);
  console.log(`  Tree depth:   ${treeResult.depth}`);
  console.log(`  Tree size:    ${treeResult.treeSize} (padded to power of 2)`);
  console.log(`  Day range:    ${startDayId} – ${endDayId}`);
  console.log(`  Build time:   ${elapsed}ms`);
  console.log('═══════════════════════════════════════════════');
  console.log('');

  // Save genesis tree to output file
  if (!fs.existsSync(outputDir)) {
    fs.mkdirSync(outputDir, { recursive: true });
  }

  const output = {
    ...serializeTree(treeResult),
    startDayId,
    endDayId,
    rootPadded: '0x' + treeResult.root.toString(16).padStart(64, '0')
  };

  fs.writeFileSync(outputPath, JSON.stringify(output, null, 2));
  console.log(`💾 Genesis tree saved to: ${outputPath}`);
  console.log('');
  console.log('Next steps:');
  console.log('  1. Run Phase 4: generate a coverage proof against this root');
  console.log('  2. Run Phase 5: submit this root on-chain');
  console.log(`  3. Contract call: commitGenesisRoot("${output.rootPadded}", ...)`);

  return output;
}

main().catch(err => {
  console.error('❌ Fatal error:', err.message);
  process.exit(1);
});
