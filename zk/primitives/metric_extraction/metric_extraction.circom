pragma circom 2.0.0;

// metric_extraction.circom
// Amach Health ZK — Verification Factory primitive
//
// Template: MetricExtraction(chunkIndex, byteOffsetInChunk)
//
// Strong-binding metric extractor for v2 (124-byte) leaves.
//
// Given:
//   - the four 31-byte field-element chunks that make up the v2 leaf
//     (chunks[0..3], each in BIG-ENDIAN field-encoded form, matching
//     `zk/scripts/hash_leaf.js::chunksV2`)
//   - the leaf's published Poseidon4 hash (`leafHash`)
//
// The template:
//   1. Asserts Poseidon4(chunks[0..3]) === leafHash, binding the chunks to
//      the committed leaf identity (no silent swap of chunks for some other
//      leaf's bytes).
//   2. Bit-decomposes `chunks[chunkIndex]` and reads a contiguous 16-bit
//      window at the requested byte offset, returning it as `metricValue`.
//
// Compile-time parameters:
//   chunkIndex          0..3, which of the four v2 chunks holds the metric
//   byteOffsetInChunk   0..29, byte position within that chunk
//                       (must satisfy byteOffsetInChunk <= 29 so the 2-byte
//                       metric fits inside the 31-byte chunk)
//
// The "byte offset within the leaf" used in metric-pointers.md is computed
// as `chunkIndex * 31 + byteOffsetInChunk`.
//
// Constraint cost: 736 (Poseidon4) + 248 (Num2Bits) = ~984 + bookkeeping.
//
// Why bit-decompose the whole chunk?
//   `Num2Bits(248)` is the cheapest way to enforce both (a) range — the
//   chunk is < 2^248, so it cannot be an arbitrary field element pretending
//   to be a 31-byte payload — and (b) random byte access. Reading just the
//   metric bits without range-checking the rest of the chunk would let a
//   malicious prover smuggle non-zero bits past 248 and produce a chunk
//   value that doesn't correspond to any legal byte serialization.
//
// Endianness:
//   The chunks are big-endian. In `zk/scripts/hash_leaf.js::chunksV2`,
//   `BigInt('0x' + leafBytes.slice(0,31).toString('hex'))` reads byte 0 as
//   the most-significant byte. So bit positions inside the chunk are
//   numbered from the LEAST significant up (bit 0 = bit 0 of byte 30 of the
//   chunk slice, bit 247 = bit 7 of byte 0). To extract byte k of the chunk
//   slice as a u8, we read bits [(30-k)*8 .. (30-k)*8 + 7]. The 16-bit
//   metric occupying chunk bytes [byteOffsetInChunk, byteOffsetInChunk+1]
//   corresponds to the bit window
//   [(30 - byteOffsetInChunk - 1) * 8 .. (30 - byteOffsetInChunk - 1) * 8 + 15],
//   i.e. starting at bit `(29 - byteOffsetInChunk) * 8`.

include "../../node_modules/circomlib/circuits/poseidon.circom";
include "../../node_modules/circomlib/circuits/bitify.circom";

template MetricExtraction(chunkIndex, byteOffsetInChunk) {
    // ── Compile-time sanity ────────────────────────────────────────
    // chunkIndex must be 0..3
    assert(chunkIndex >= 0);
    assert(chunkIndex <= 3);
    // 16-bit metric must fit inside the 31-byte chunk
    assert(byteOffsetInChunk >= 0);
    assert(byteOffsetInChunk <= 29);

    signal input chunks[4];     // big-endian 31-byte field elements
    signal input leafHash;      // expected Poseidon4(chunks) commitment
    signal output metricValue;  // u16 at the requested offset

    // ── 1. Bind chunks to leafHash ─────────────────────────────────
    component leafHasher = Poseidon(4);
    for (var i = 0; i < 4; i++) {
        leafHasher.inputs[i] <== chunks[i];
    }
    leafHasher.out === leafHash;

    // ── 2. Bit-decompose the chunk holding the metric ──────────────
    // 248 bits = 31 bytes. Num2Bits both decomposes and range-checks.
    component bits = Num2Bits(248);
    bits.in <== chunks[chunkIndex];

    // Bit position of the metric's LOW byte:
    //   chunk-byte index of the low byte = byteOffsetInChunk + 1
    //   chunks are 31 bytes, bit `b` corresponds to chunk-byte
    //     `30 - floor(b/8)` (big-endian).
    //   So the low byte starts at bit (30 - (byteOffsetInChunk + 1)) * 8
    //                              = (29 - byteOffsetInChunk) * 8.
    var lowBit = (29 - byteOffsetInChunk) * 8;

    // Reconstruct u16 from 16 bits starting at `lowBit`. The k-th bit (LSB
    // first) goes to position 2^k in the value.
    var acc = 0;
    var pow = 1;
    for (var k = 0; k < 16; k++) {
        acc += bits.out[lowBit + k] * pow;
        pow *= 2;
    }
    metricValue <== acc;
}
