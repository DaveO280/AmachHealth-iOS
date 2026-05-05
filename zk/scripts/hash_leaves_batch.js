/**
 * hash_leaves_batch.js
 * Amach Health ZK — Phase 2/6
 *
 * Batch Poseidon hashing for the iOS LeafHashingService.
 * Called by LeafHashingService.swift.
 *
 * Input:  JSON file — Array of { dayId, serialized } where serialized is 90-byte hex
 * Output: JSON file — Array of { dayId, hash, hashHex }
 *
 * Usage:
 *   node scripts/hash_leaves_batch.js input.json output.json
 */

'use strict';

const { hashLeaf } = require('./hash_leaf');
const fs = require('fs');

const inputPath = process.argv[2];
const outputPath = process.argv[3];

if (!inputPath || !outputPath) {
  console.error('Usage: node hash_leaves_batch.js <input.json> <output.json>');
  process.exit(1);
}

if (!fs.existsSync(inputPath)) {
  console.error(`Input file not found: ${inputPath}`);
  process.exit(1);
}

const leaves = JSON.parse(fs.readFileSync(inputPath, 'utf8'));

if (!Array.isArray(leaves)) {
  console.error('Input must be a JSON array');
  process.exit(1);
}

const output = leaves.map((leaf, i) => {
  if (!leaf.serialized || leaf.serialized.length !== 180) {
    throw new Error(`Leaf ${i} (dayId=${leaf.dayId}): invalid serialized field (expected 180 hex chars, got ${leaf.serialized?.length})`);
  }

  const buf = Buffer.from(leaf.serialized, 'hex');
  const hash = hashLeaf(buf);

  return {
    dayId: leaf.dayId,
    hash: hash.toString(10),
    hashHex: '0x' + hash.toString(16).padStart(64, '0')
  };
});

fs.writeFileSync(outputPath, JSON.stringify(output, null, 2));
console.log(`Hashed ${output.length} leaves → ${outputPath}`);
