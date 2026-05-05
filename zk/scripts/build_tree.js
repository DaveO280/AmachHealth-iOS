/**
 * build_tree.js
 * Amach Health ZK — Phase 3
 *
 * Binary Merkle tree builder using Poseidon hashing.
 *
 * Protocol spec:
 *   - Leaves sorted ascending by day_id (already sorted by normalization service)
 *   - Internal node hash: Poseidon([leftChild, rightChild])
 *   - Tree padded to next power of 2 with zero-value leaves
 *   - Standard left-right ordering
 *   - Root is the single element at the top of the tree
 */

'use strict';

const { poseidon2 } = require('poseidon-lite');
const {
  hashLeaf,
  buildTestLeaf,
  V1_LEAF_BYTES,
  V2_LEAF_BYTES
} = require('./hash_leaf');

// Zero value used for padding leaves (0n = the additive identity in the field)
const ZERO_LEAF = 0n;

/**
 * Build a binary Merkle tree from an array of serialized leaf Buffers.
 * Each leaf may be v1 (90 bytes, Poseidon3) or v2 (124 bytes, Poseidon4);
 * `hashLeaf` dispatches on length. A single tree may mix versions in
 * principle, but the iOS pipeline commits homogeneous trees.
 *
 * Tree is padded to the next power of 2. For the coverage circuit (depth=10),
 * this supports up to 1024 leaves (~3 years of daily health data).
 *
 * @param {Buffer[]} leaves - Array of serialized leaves, sorted by day_id
 * @returns {{
 *   root: BigInt,
 *   tree: BigInt[][],
 *   leafHashes: BigInt[],
 *   leafCount: number,
 *   treeSize: number,
 *   depth: number
 * }}
 */
function buildMerkleTree(leaves) {
  if (!Array.isArray(leaves) || leaves.length === 0) {
    throw new Error('buildMerkleTree requires a non-empty array of leaf Buffers');
  }

  // Hash all real leaves. hashLeaf auto-dispatches on length.
  const leafHashes = leaves.map((leaf, i) => {
    if (!Buffer.isBuffer(leaf)) {
      throw new Error(`Leaf ${i} is not a Buffer`);
    }
    if (leaf.length !== V1_LEAF_BYTES && leaf.length !== V2_LEAF_BYTES) {
      throw new Error(
        `Leaf ${i}: unsupported length ${leaf.length}. ` +
        `Expected ${V1_LEAF_BYTES} (v1) or ${V2_LEAF_BYTES} (v2).`
      );
    }
    return hashLeaf(leaf);
  });

  const leafCount = leafHashes.length;

  // Pad to next power of 2 with zero leaves
  const treeSize = nextPowerOf2(leafCount);
  let level = [...leafHashes];
  while (level.length < treeSize) {
    level.push(ZERO_LEAF);
  }

  // Store all tree levels (level[0] = leaves, level[depth] = root)
  const tree = [level];

  // Build up the tree level by level
  while (level.length > 1) {
    const nextLevel = [];
    for (let i = 0; i < level.length; i += 2) {
      nextLevel.push(poseidon2([level[i], level[i + 1]]));
    }
    tree.push(nextLevel);
    level = nextLevel;
  }

  const root = level[0];
  const depth = tree.length - 1;

  return {
    root,
    tree,       // tree[0] = leaf hashes (padded), tree[depth] = [root]
    leafHashes, // only real leaf hashes (not padded)
    leafCount,
    treeSize,
    depth
  };
}

/**
 * Generate a Merkle proof (path) for a leaf at a given index.
 *
 * @param {BigInt[][]} tree - Full tree from buildMerkleTree
 * @param {number} leafIndex - Index into the leaf array (0-based)
 * @returns {{
 *   siblings: string[],   // sibling hashes as decimal strings (for snarkjs witness)
 *   indices: number[],    // 0 = leaf is left child, 1 = leaf is right child
 *   leaf: BigInt
 * }}
 */
function getMerklePath(tree, leafIndex) {
  const depth = tree.length - 1;
  const siblings = [];
  const indices = [];

  let currentIndex = leafIndex;

  for (let level = 0; level < depth; level++) {
    const isRightChild = currentIndex % 2 === 1;
    const siblingIndex = isRightChild ? currentIndex - 1 : currentIndex + 1;

    // Sibling exists if within bounds; otherwise use zero value
    const sibling = siblingIndex < tree[level].length
      ? tree[level][siblingIndex]
      : ZERO_LEAF;

    siblings.push(sibling);
    indices.push(isRightChild ? 1 : 0);

    currentIndex = Math.floor(currentIndex / 2);
  }

  return {
    siblings,
    indices,
    leaf: tree[0][leafIndex]
  };
}

/**
 * Verify a Merkle proof locally (without a circuit).
 * Use this to sanity-check path correctness before generating ZK proofs.
 *
 * @param {BigInt} leaf - Leaf hash
 * @param {BigInt[]} siblings - Sibling hashes from root to leaf
 * @param {number[]} indices - 0=left, 1=right for each level
 * @param {BigInt} root - Expected root
 * @returns {boolean}
 */
function verifyMerklePath(leaf, siblings, indices, root) {
  let current = leaf;

  for (let i = 0; i < siblings.length; i++) {
    if (indices[i] === 0) {
      // current is left child
      current = poseidon2([current, siblings[i]]);
    } else {
      // current is right child
      current = poseidon2([siblings[i], current]);
    }
  }

  return current === root;
}

/**
 * Next power of 2 >= n.
 * @param {number} n
 * @returns {number}
 */
function nextPowerOf2(n) {
  let p = 1;
  while (p < n) p *= 2;
  return p;
}

/**
 * Serialize a BigInt tree structure to a JSON-safe format.
 * All BigInt values become hex strings prefixed with "0x".
 */
function serializeTree(treeResult) {
  return {
    root: '0x' + treeResult.root.toString(16),
    leafCount: treeResult.leafCount,
    treeSize: treeResult.treeSize,
    depth: treeResult.depth,
    tree: treeResult.tree.map(level => level.map(n => '0x' + n.toString(16))),
    leafHashes: treeResult.leafHashes.map(n => '0x' + n.toString(16)),
    generatedAt: Date.now()
  };
}

/**
 * Deserialize a tree structure from the JSON-safe format back to BigInts.
 */
function deserializeTree(serialized) {
  return {
    root: BigInt(serialized.root),
    leafCount: serialized.leafCount,
    treeSize: serialized.treeSize,
    depth: serialized.depth,
    tree: serialized.tree.map(level => level.map(n => BigInt(n))),
    leafHashes: serialized.leafHashes.map(n => BigInt(n)),
    generatedAt: serialized.generatedAt
  };
}

module.exports = {
  buildMerkleTree,
  getMerklePath,
  verifyMerklePath,
  nextPowerOf2,
  serializeTree,
  deserializeTree,
  ZERO_LEAF
};

// CLI mode: node scripts/build_tree.js
// The coverage circuit uses depth=10 (max 1024 leaves). This self-test uses
// 4 leaves for speed; the tree will pad to the next power of 2 (4 leaves → depth=2).
if (require.main === module) {
  console.log('Building test Merkle tree with 4 known leaves...');
  console.log('');

  // 4 test leaves with known values for manual verification
  const leaves = [
    buildTestLeaf({ dayId: 0 }),
    buildTestLeaf({ dayId: 1 }),
    buildTestLeaf({ dayId: 2 }),
    buildTestLeaf({ dayId: 3 })
  ];

  const result = buildMerkleTree(leaves);

  console.log('Tree structure:');
  console.log('  Leaf count:', result.leafCount);
  console.log('  Tree size (padded):', result.treeSize);
  console.log('  Depth:', result.depth);
  console.log('  Root:', result.root.toString(16));
  console.log('');

  console.log('Leaf hashes:');
  result.leafHashes.forEach((h, i) => console.log(`  [${i}] ${h.toString(16)}`));
  console.log('');

  // Verify Merkle path for leaf 1
  const { siblings, indices, leaf } = getMerklePath(result.tree, 1);
  const valid = verifyMerklePath(leaf, siblings, indices, result.root);
  console.log('Merkle path verification for leaf[1]:', valid ? '✅ VALID' : '❌ INVALID');
  console.log('  siblings:', siblings.map(s => s.toString(16)));
  console.log('  indices:', indices);
}
