# Project State — Spring Push Verification Layer

Last updated: 2026-05-05

This file tracks the running state of the Spring Push verification-layer build
across sessions. Update at the end of every session with status, decisions,
and handoff notes.

---

## Current status

**Layer 0 (v2 leaf format): complete on this branch.**
**Layer 1 (legitimacy script): not started.**
**Layer 2 (AverageImprovementProof circuit): not started.**

Branch: `claude/brave-leakey-06eece` (worktree:
`.claude/worktrees/brave-leakey-06eece`).
Base: `main` at `c1be672`.

---

## Layer 0 — what shipped

The v2 leaf format is implemented end-to-end with cross-platform hash
consistency proven against five fixed test vectors. Everything specified in
the session brief's Layer 0 section is in place:

### Swift (iOS)

- `AmachHealth/Sources/Models/AmachLeafV2.swift` — new. 124-byte schema
  matching `VERIFICATION_FACTORY.md` exactly. Implements:
  - Envelope: version (0x02), leafType (0x00 = daily_summary), schemaVersion
    (0x01), reservedEnvelope (0x00).
  - Identity & time: wallet (32 bytes), dayId (u32), timezoneOffset (i16).
  - v1-equivalent metrics: steps, activeEnergy, exerciseMins, hrv, restingHR,
    sleepMins, workoutCount, sourceCount, dataFlags (now u32).
  - v2 additions: vo2max, weight, bodyFatPct, leanMass, deepSleepMins,
    remSleepMins, lightSleepMins, awakeMins.
  - Reserved payload: 12 bytes, must be zero in v2.0.
  - Source binding: sourceHash (32 bytes).
  - `serialize()` / `deserialize(from:)` round-trip, `validate()` envelope
    enforcement, `chunks()` for Poseidon4 input.
- `AmachHealth/Sources/Services/MerkleNormalizationService.swift` — extended.
  `NormalizedDailyLeaf` now carries v2 fields and presence flags. `normalizeDay`
  populates VO2 max, weight, body fat percentage, lean mass, and the four
  sleep-stage values from HealthKit samples. `toAmachLeafV2()` converts to the
  v2 wire format with `dataFlagsV2` (low bits mirror v1, upper bits encode v2
  presence flags). `toMerkleLeaf()` (v1) is unchanged — no regression on the
  v1 path.
- `AmachHealth/Sources/Services/LeafHashingService.swift` — extended. New
  `HashedLeafV2` struct and `hashLeavesV2(_:)` that serializes 124-byte leaves
  and shells out to the same Node batch script. Validates each leaf's
  envelope before returning. v1 `hashLeaves(_:)` is unchanged.
- `AmachHealth/Sources/Services/MerkleTreeBuilder.swift` — extended. Generic
  internal `buildGenesisTreeImpl` is shared by the v1 and v2 entry points.
  v2 `buildStorjPayload(tree:hashedLeaves:walletAddress:)` overload writes
  the v2 metric set to the encrypted leaves payload and pins
  `protocolVersion: "2.0"`. v1 is unchanged.
- `AmachHealth.xcodeproj/project.pbxproj` — `AmachLeafV2.swift` and
  `AmachLeafV2Tests.swift` are added to the app target's Sources phase and
  the test target respectively.

### JavaScript (zk/)

- `zk/scripts/hash_leaf.js` — rewritten as a dispatch layer.
  - Public `hashLeaf(buf)` selects v1 (Poseidon3, 90 bytes) or v2 (Poseidon4,
    124 bytes) by buffer length.
  - `hashLeafV1` / `hashLeafV2` and `chunksV1` / `chunksV2` are exported for
    direct use.
  - `chunksV2` enforces the version byte at hash time as a low-cost guard
    against passing a v1 buffer to the v2 path.
  - v1 chunking is bit-for-bit identical to the previous implementation —
    pinned by the back-compat Jest test against the captured pre-refactor
    hash.
  - `buildTestLeafV1` / `buildTestLeafV2` produce canonical fixtures.
- `zk/scripts/build_tree.js` and `zk/scripts/build_tree_cli.js` — relaxed
  length checks to accept either 90- or 124-byte leaves; tree construction
  is hash-agnostic and works for both via the new dispatcher.
- `zk/scripts/__tests__/v2_test_vectors.js` — five fixed leaves with their
  expected Poseidon4 hashes. Mirrored in
  `AmachLeafV2Tests.swift::crossPlatformFixtures`. Regenerate with
  `node zk/scripts/__tests__/v2_test_vectors.js` and refresh both the JS
  module and the Swift mirror together when extending the schema.
- `zk/scripts/__tests__/hash_leaf.test.js` — Jest coverage:
  - v1 backward-compat hash pin.
  - 5 cross-platform v2 vectors.
  - Dispatch and validation (length, version byte, type rejection).
  - Edge cases (zero envelope, all-max fields, BN128 field bound).
- `zk/package.json` — adds `jest` devDependency, `npm test` script, and a
  `vectors:v2` script for regenerating fixtures.

### Tests

- 20 XCTest cases in `AmachLeafV2Tests` — all pass.
  - Serialization length / envelope byte positions / known field offsets.
  - Round-trip for default, all-zero envelope, and all-max fields.
  - Validation (rejects wrong version, leafType, schemaVersion, non-zero
    reserved bytes, wrong wallet/sourceHash length).
  - Chunking shape (4 × 31 == 124, no padding).
  - Cross-platform vectors round-trip the pinned bytes; chunks are < BN128
    field size; Swift-serialized bytes equal the JS-pinned hex.
- 19 Jest cases in `hash_leaf.test.js` — all pass.

The cross-platform consistency proof is two-sided: the Swift test asserts
that Swift serialization equals the pinned JS-vector bytes; the Jest test
asserts those exact bytes hash to the pinned expected decimals. So any
Swift caller that goes through `LeafHashingService.hashLeavesV2` →
`hash_leaf.js` gets the same hash a JS-side caller would.

### How to run tests

Swift (from worktree root):

```
xcodebuild -project AmachHealth.xcodeproj \
  -scheme "Amach Health" \
  -destination 'platform=iOS Simulator,id=<your-iphone-sim-uuid>' \
  test -only-testing:'Amach HealthTests/AmachLeafV2Tests'
```

JS:

```
cd zk && npm install && npx jest
```

---

## Acceptance criteria status

| Criterion | Status |
|---|---|
| All Swift tests pass | yes (20/20 in AmachLeafV2Tests) |
| All JS tests pass | yes (19/19 in hash_leaf.test.js) |
| Cross-platform consistency for ≥ 5 fixed leaves | yes (5 vectors pinned both sides) |
| v1 commitments still verify (no regression) | yes — v1 hash path is byte-identical, pinned by the back-compat Jest test |
| Commits clearly demarcate v2 work | see commit `feat(leaf-v2): ...` on this branch |
| Documentation explains v1/v2 dispatch | yes — header comments in `AmachLeafV2.swift` and `hash_leaf.js`, plus this file |

The brief's higher-bar 100-randomized-leaves consistency check is the next
session's setup work (a synthetic leaf generator that emits the same input
in both languages and asserts hash equality across the batch).

---

## Outstanding pre-existing test failures (not from this work)

Three tests fail on the base `c1be672` and continue to fail after Layer 0;
they are unrelated to v2:

- `Amach HealthTests.PDFGenerationAndParseTests.test_generated_bloodwork_pdf_is_parseable`
- `Amach HealthTests.PDFReportTypeDetectionTests.test_returns_nil_for_nonsense_text`
- `Amach HealthTests.ParserRobustnessTests.test_random_prose_returns_nil`

These were introduced when `feat: add medical record type as catch-all for
any uploaded PDF` (commit `5c1257f`) made non-lab text return a `medicalRecord`
value where the tests still expected `nil`. Out of scope for Layer 0; flagging
here so they don't get attributed to this branch.

---

## Notes on zk/ being newly tracked

This branch is the first to commit the `zk/` directory to git. Before this
work `zk/` lived as untracked working files in the parent checkout. To keep
the diff focused, a `zk/.gitignore` excludes:

- `node_modules/`, `coverage/` (Jest report dir at the zk root only — does
  not match `zk/circuits/coverage/`)
- Hardhat artifacts (`deploy/artifacts-zk/`, `deploy/cache-zk/`,
  `deploy/typechain-types/`)
- snarkJS artifacts (`*.zkey`, `*.r1cs`, `*.sym`, `*.wtns`)
- Phase 1 trusted-setup files (`*.ptau`)
- Local witness/proof intermediates (`data/`)
- `build/`

The committed surface is the source: scripts, circuits, deploy contracts,
and the Hardhat / package configs. `pot17_final.ptau` (~150 MB) is expected
to be downloaded out-of-band per `zk/ZK_SETUP.md`.

---

## Next-session handoff: Layer 1 (legitimacy verification script)

Read first:

- `Spring-Push-Verification-Layer-Session-Brief.md` Layer 1 section
- `VERIFICATION_FACTORY.md` for the data-layer principles already in place

Layer 1 ships:

- `/Users/dave/Amach-Website/scripts/legitimacy/` (new directory).
- TypeScript / Node 20+, Jest tests, JSON + Markdown report formats, CLI.
- Reads v2 leaves committed via this Layer 0 work and reconstructs the
  Merkle root using the same Poseidon4 pipeline (`hash_leaf.js` is the
  authoritative implementation; the legitimacy package can `require` it
  directly or vendor a copy under its own dependency).
- Categories A–F as documented; thresholds configurable via a single config
  file.

Suggested first slice:

1. Set up the package skeleton, including a `circomlibjs` Poseidon binding
   that produces the same field elements as `poseidon-lite/poseidon4`.
2. Cross-check by re-running the Layer 0 `v2_test_vectors.js` fixtures
   through the new package — same expected hashes.
3. Then build Category A (cryptographic anchoring) which is the only category
   that can fail closed; everything else is statistical scoring.

The synthetic data generator the brief calls for is also Layer 1 / Layer 2
shared infrastructure — sketching its API early helps both later layers.

---

## Layer 0 follow-ups (not blockers, but worth queuing)

- 100-leaf randomized cross-platform consistency batch (the brief's stretch
  acceptance criterion). The 5 fixed vectors prove the format is consistent;
  the 100-leaf batch proves it stays consistent across the input space.
  Best done as a small generator under `zk/scripts/__tests__/` that emits
  random `AmachLeafV2` inputs in both languages and compares hashes.
- iOS proof-generation pipeline (`MerkleGenesisService` and friends) does
  not yet promote v2 to the genesis flow — that's a separate, Layer-1-
  adjacent task. v2 hashing exists; the registration trigger that exercises
  it does not.
- The `LeafHashingService` `zkScriptPath` still hard-codes
  `~/Projects/AmachHealth-iOS/zk` (a stale path). v2 inherits the same
  string. Worth fixing alongside whatever resolves this for v1 — out of
  scope for Layer 0.

---

## Commit log on this branch

- `feat(leaf-v2): ship v2 leaf format with cross-platform hash dispatch`
  (this session)

Earlier branch commits, if any, listed above this line.
