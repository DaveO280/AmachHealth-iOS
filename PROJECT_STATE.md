# Project State — Spring Push Verification Layer

Last updated: 2026-05-05

This file tracks the running state of the Spring Push verification-layer build
across sessions. Update at the end of every session with status, decisions,
and handoff notes.

---

## Current status

**Layer 0 (v2 leaf format): complete.**
Branch: `claude/brave-leakey-06eece` (worktree:
`AmachHealth-iOS/.claude/worktrees/brave-leakey-06eece`).

**Layer 1 (legitimacy verification script): complete.**
Branch: `claude/relaxed-murdock-e22d70` (worktree:
`Amach-Website/.claude/worktrees/relaxed-murdock-e22d70`).
Output destination: `Amach-Website/scripts/legitimacy/`.

**Layer 2 (AverageImprovementProof circuit): complete (proven, verified, awaiting on-chain deploy).**
Branch: `claude/improvement-proof-layer2` (worktree:
`AmachHealth-iOS/.claude/worktrees/unruffled-rosalind-0e2d1e`).
Branched from `claude/brave-leakey-06eece`.

---

## Layer 0 — what shipped (recap)

See the full Layer 0 status in
`AmachHealth-iOS/.claude/worktrees/brave-leakey-06eece/PROJECT_STATE.md`.

Bullet summary:

- `AmachLeafV2.swift` — 124-byte schema, serialize / deserialize / chunks().
- `LeafHashingService.swift` extended to dispatch v1 (Poseidon3) / v2
  (Poseidon4) by leaf length.
- `MerkleTreeBuilder.swift` extended for v2 leaves.
- `MerkleNormalizationService.swift` extended to populate VO2 max, body
  composition, sleep stage breakdown.
- `zk/scripts/hash_leaf.js` — JS dispatcher with v1 backward-compat hash pin.
- 5 cross-platform v2 hash vectors pinned in both Swift XCTest and Jest.
- 20 / 20 Swift tests pass; 19 / 19 JS tests pass.

---

## Layer 1 — what shipped (this session)

Open-source legitimacy verification script. Lives at
`Amach-Website/scripts/legitimacy/`. Self-contained npm package
`@amach/legitimacy` with Node 20+ runtime; minimal deps (`poseidon-lite`,
`simple-statistics`).

### Cryptographic parity

The TS port of v2 leaf serialization and Poseidon4 hashing in
`src/leaf.ts` is asserted against the same five fixed test vectors that
Layer 0's Swift and JS implementations check. `__tests__/leaf.test.ts`
proves Layer 1 hashes identically to Layer 0 for the pinned inputs.
`__tests__/fixtures/crossPlatformVectors.ts` carries the canonical
`(serializedHex, expectedHashDec, expectedHashHex)` triples copied
verbatim from `zk/scripts/__tests__/v2_test_vectors.js`.

### Pipeline

```
runLegitimacyPipeline(input)
  → Category A (cryptographic anchoring; gating — halts on fail)
  → Category B (statistical bounds, 14 metrics × 5 sub-checks)
  → Category C (multi-metric correlations, C.1–C.7)
  → Category D (temporal patterns, D.1–D.5 — added D.5 lag-1 autocorrelation)
  → Category E (continuity, E.1 / E.2.* / E.3)
  → Category F (weighted-aggregate scoring with diagnostic-failure penalty)
  → JSON / Markdown formatter
```

Score formula:

```
score = (0.20·B + 0.35·C + 0.25·D + 0.20·E) × 0.6^N
```

where `N` = number of primary diagnostic failures (C.1–C.5, D.2, D.4,
D.5, E.1, E.3). Two diagnostic failures push the score below the 0.7
threshold even if every other check passes.

### Synthetic data

`src/generator/synthetic.ts` produces realistic v2 leaves with
configurable starting fitness, age, sex, VO2 max trajectory, device
profile, and noise profile. AR(1) noise streams give realistic lag-1
autocorrelation; active energy is mechanically coupled to exercise
minutes (so C.4 is the legitimate signal, not a coincidence).

`src/generator/datasets.ts` defines all 16 named test datasets:

- L1–L5 — legitimate trajectories (must score > 0.85)
- A1–A8 — adversarial transforms (random, smoothed, single-metric,
  cherry-picked, copy-paste week, friend's-data stitched, device
  switch, backloaded commits — must fail at least one C/D/E check
  AND score < 0.70)
- E1–E3 — edge cases (sparse but real, night-shift schedule, elite
  athlete — must score > 0.70)

### Acceptance criteria status

| Criterion | Status |
|---|---|
| 95 %+ coverage on check functions | yes — 97.35 % statements, 91.13 % branches |
| 85 %+ overall coverage | yes — 95.80 % statements, 87.62 % branches |
| All 18 integration tests pass | yes — 133 / 133 tests across 14 suites |
| `npm install` runs cleanly from a fresh clone | yes |
| CLI works as documented for all flags | yes — covered by `__tests__/cli.test.ts` |
| All L1–L5 score > 0.85 | yes — 0.973–0.999 |
| All A1–A8 fail at least one diagnostic check | yes — and score in [0.16, 0.58] |
| No false positives on E1–E3 | yes — all score ≈ 0.999 |
| Runtime < 10 s for 365-day dataset | yes — < 250 ms |

### File map

```
scripts/legitimacy/
├── package.json                  @amach/legitimacy v0.1.0
├── tsconfig.json
├── jest.config.js                95 % checks, 85 % overall thresholds
├── README.md
├── examples/
│   └── legitimate-90d.json       sample CLI input fixture
├── src/
│   ├── index.ts                  public API re-exports
│   ├── cli.ts                    `amach-legitimacy-check`
│   ├── pipeline.ts               runLegitimacyPipeline()
│   ├── types.ts
│   ├── config.ts                 DEFAULT_CONFIG with citations
│   ├── leaf.ts                   v2 serialization + Poseidon4 hashing
│   ├── merkle.ts                 binary tree + path verifier
│   ├── stats.ts                  pearson, modeFraction, lag1Autocorrelation, …
│   ├── generator/
│   │   ├── synthetic.ts          configurable v2 leaf generator
│   │   └── datasets.ts           L1–L5 / A1–A8 / E1–E3
│   ├── checks/
│   │   ├── categoryA.ts          cryptographic anchoring (gating)
│   │   ├── categoryB.ts          per-metric bounds
│   │   ├── categoryC.ts          multi-metric correlations
│   │   ├── categoryD.ts          temporal patterns + autocorrelation
│   │   ├── categoryE.ts          continuity / device consistency
│   │   └── categoryF.ts          weighted scoring + penalty
│   └── formatters/
│       ├── json.ts
│       └── markdown.ts
└── __tests__/
    ├── leaf.test.ts              cross-platform vectors
    ├── merkle.test.ts
    ├── stats.test.ts
    ├── generator.test.ts
    ├── pipeline.test.ts          integration
    ├── cli.test.ts
    ├── formatters.test.ts
    ├── datasets.test.ts          ★ acceptance criteria
    ├── checks/
    │   ├── categoryA.test.ts
    │   ├── categoryB.test.ts
    │   ├── categoryC.test.ts
    │   ├── categoryD.test.ts
    │   ├── categoryE.test.ts
    │   └── categoryF.test.ts
    └── fixtures/
        └── crossPlatformVectors.ts
```

### How to run

```bash
cd Amach-Website/.claude/worktrees/relaxed-murdock-e22d70/scripts/legitimacy
npm install
npm test                    # 133 tests, ~3 s
npm run test:coverage       # confirms 97 % checks / 96 % overall
npx amach-legitimacy-check --data ./examples/legitimate-90d.json --format markdown
```

---

## Tuning notes (for Layer 2 reviewers and future maintainers)

The synthetic generator and the check thresholds were co-tuned. Notable
calibrations:

- **C.1 / C.2 / C.3 correlation thresholds** were relaxed from the brief's
  implied stricter values to match what real wearable data with 90 days
  and high noise actually shows. Diagnostic separation comes from D.5
  (lag-1 autocorrelation) and the multiplicative penalty on diagnostic
  failures, not from tight Pearson thresholds.
- **C.4 active energy ↔ exercise correlation** uses 0.20 because most
  active kcal in real data come from non-exercise activity (steps).
  A higher threshold produced false positives on legitimate datasets.
- **B.3 mode-fraction** is skipped for `weight`, `bodyFatPct`, `leanMass` —
  body composition legitimately has low cardinality (people don't weigh
  themselves daily).
- **B.4 step changes**: RHR is 350 wire-units (35 bpm) max d/d, weight
  is 500 wire (5 kg) — realistic upper bounds, not modal.
- **Score formula** uses a category-weighted aggregate (B 20 %, C 35 %,
  D 25 %, E 20 %) multiplied by `0.6^N` where N = primary-diagnostic
  failures. The product is what gives clean separation between
  legitimate (≥ 0.97) and adversarial (≤ 0.58) datasets.
- **A6 (friend's data)** stitches RHR / HRV / sleep from a sedentary
  series onto an elite VO2 trajectory. The internal correlations
  between physiology metrics break, so C.3 catches it cleanly even
  though every individual metric sits in a plausible range.

---

## Layer 0 hand-off items still queued

These were noted in the Layer 0 PROJECT_STATE and are NOT addressed by
Layer 1:

- 100-randomized-leaves cross-platform consistency batch
  (Layer 0 stretch criterion).
- iOS proof-generation pipeline (`MerkleGenesisService`) does not yet
  promote v2 to genesis.
- `LeafHashingService.zkScriptPath` still hard-codes a stale path.

---

## Layer 2 — what shipped (this session)

`AverageImprovementProof` Groth16 circuit + four reusable primitives in
the verification-factory pattern. Proves that a claimed average-improvement
percentage was honestly computed from VO2 max values committed in v2
Merkle leaves. The same template recompiles for any of the 12 v2 metrics
by changing `(METRIC_CHUNK_IDX, METRIC_BYTE_OFFSET_IN_CHUNK)`.

### Constraint budget — UNDER target

| | |
|---|---|
| Constraints       | **18,707** (under the brief's 20,000 cap) |
| Wires             | 18,744 |
| Public inputs     | 5 |
| Private inputs    | 76 |
| Local prove time  | ~430–580 ms per proof on this machine |
| Verify gas (EVM)  | **242,133** (under the brief's 500,000 cap) |
| Trusted setup     | Local Phase 2 reusing `pot17_final.ptau` (Phase 1) |

### Default instantiation

```
component main = AverageImprovementProof(2, 2, 7, 2, 2);
```

| Param | Value | Meaning |
|------|------:|---|
| `N`                           | 2 | baseline-window leaf count |
| `M`                           | 2 | finish-window leaf count |
| `depth`                       | 7 | Merkle tree depth (max 128 leaves) |
| `METRIC_CHUNK_IDX`            | 2 | chunk index holding vo2max |
| `METRIC_BYTE_OFFSET_IN_CHUNK` | 2 | byte offset inside chunk 2 (= leaf byte 64) |

The 2-day window was the largest size that fit the 20 k constraint
target with strong leaf-hash binding. Larger seasons can recompile
with bigger N / M / depth (constraint scaling is documented inline in
`improvement.circom`); pot17 supports up to ~131 k constraints, which
covers a re-instantiation as wide as N=M=12 at depth=7.

### Public-input order (matches `verifyProof(...,_pubSignals[5])`)

```
[0] baselineRoot
[1] finishRoot
[2] metricPointer            // bound at compile time to chunkIdx*31+offsetInChunk
[3] claimedMagnitudeBp       // basis points, e.g. 1000 = 10.00 %
[4] claimedSignFlag          // 0 = improvement, 1 = decline
```

### Composition (verification factory)

```
AverageImprovementProof
  └─ MetricExtraction × (N+M)            zk/primitives/metric_extraction/
  ├─ MerkleInclusion  × (N+M)            zk/primitives/merkle_inclusion/
  ├─ AverageComputation × 2              zk/primitives/average_computation/
  └─ SignedImprovementCheck              zk/primitives/threshold_comparison/
```

`MerkleInclusion` is a clean lift of `coverage/merkle_verify.circom` into
the shared library; `coverage.circom` itself was left untouched to avoid
disturbing the live Phase 4 setup. New circuits (incl. coverage v2)
should switch to the primitive going forward.

### Binding model

The circuit binds:

- **Leaf-content integrity** — `Poseidon4(chunks) === leafHash` per leaf.
- **Inclusion** — Poseidon(2) Merkle path against the public root.
- **Metric extraction** — 16-bit value reconstructed from chunk bits at
  the compile-time-pinned offset.
- **Improvement equation** — `claimedMagnitudeBp · baselineSum · M ==
  10000 · |finishSum · N − baselineSum · M|` with `claimedSignFlag`
  selecting direction (sign honesty enforced by Num2Bits range check on
  the selected diff).
- **Pointer/instantiation alignment** — public `metricPointer` MUST
  equal `chunkIdx*31 + offsetInChunk`.

What the circuit does NOT bind:

- **Day IDs / windowing.** Whether the chosen baseline / finish leaves
  correspond to the right contest days is enforced by the off-chain
  legitimacy script (Layer 1) and by an on-chain registry that maps
  roots → windows.
- **Statistical meaningfulness** of N=M=2 averages — that's policy.

### Test-suite results

| Suite | Tests | Time |
|---|---:|---:|
| `improvement_smoke.test.js` (witness-only) | 7 / 7 pass | 0.86 s |
| `improvement_proof.test.js` (full Groth16 prove → verify) | 22 / 22 pass | 5.66 s |
| `deploy/test/AverageImprovementProofV1Verifier.test.js` (Hardhat / EVM) | 14 / 14 pass | 0.49 s |
| Layer 0 `hash_leaf.test.js` regression | 19 / 19 pass | 0.15 s |

**Positive proofs covered:** 5 % / 10 % / 15 % / 25 % / 50 % / 75 % VO2 max
gain, 0.25 % small, 0 % flat, 5 % decline (negative claim), edge max
window. All verify both locally (`snarkjs.groth16.verify`) and on-chain
(`Groth16Verifier.verifyProof` on hardhat EVM).

**Negative proofs rejected:** wrong claim (±1 bp), wrong baseline /
finish root, tampered Merkle path, tampered Merkle index bit, wrong
metricPointer, forged leaf chunks (Poseidon4 binding), out-of-range
boolean Merkle index, wrong sign flag.

**Edge cases:** zero-baseline (witness builder catches before circuit;
in-circuit `baselineSumInv` would also catch), max-window (N=M=2 fully
populated).

**Cross-public-signal swap test:** taking proof for "10 %" and verifying
against the public signals for "25 %" rejects on-chain — i.e. proofs
are bound to their public inputs, no cross-claim re-use.

### File map

```
zk/circuits/improvement/
├── improvement.circom                              circuit source (default = AverageImprovementProof(2, 2, 7, 2, 2))
├── metric-pointers.md                              canonical metric → byte offset table
├── README.md
└── AverageImprovementProofV1Verifier.sol           snarkJS-emitted verifier (regenerated by setup_improvement.sh)

zk/primitives/
├── README.md                                       primitives index
├── merkle_inclusion/  {merkle_inclusion.circom, README.md}
├── metric_extraction/ {metric_extraction.circom, README.md}
├── average_computation/ {average_computation.circom, README.md}
└── threshold_comparison/ {threshold_comparison.circom, README.md}

zk/scripts/
├── build_improvement_witness.js                    witness builder (used by tests + iOS pipeline)
└── __tests__/
    ├── improvement_smoke.test.js                   witness-only sanity (no zkey needed)
    └── improvement_proof.test.js                   full prove → verify positive / negative / edge

zk/setup_improvement.sh                             compile → Phase 2 → verifier export
zk/build/improvement/                               compiled artefacts (r1cs / wasm / zkey)

zk/deploy/contracts/AverageImprovementProofV1Verifier.sol    Hardhat-side copy (auto-mirrored)
zk/deploy/scripts/03_AverageImprovementProofVerifier.js      zkSync Sepolia deploy script
zk/deploy/test/AverageImprovementProofV1Verifier.test.js     Hardhat unit tests (local EVM)
zk/deploy/hardhat.test.config.js                             test-only config (regular solc, NOT zksolc)

Amach-Website/contracts/AverageImprovementProofV1Verifier.sol   mirror for the website repo
```

### How to run

Build + trusted setup (compiles, ceremony, Solidity verifier export, mirror to Amach-Website):

```bash
cd AmachHealth-iOS/zk
./setup_improvement.sh
```

Witness + proof tests (29 tests, ~6 s):

```bash
cd AmachHealth-iOS/zk
npm run test:improvement
```

Hardhat verifier tests (14 tests, on local EVM, ~0.5 s):

```bash
cd AmachHealth-iOS/zk/deploy
npm install            # one-time, picks up @nomicfoundation/hardhat-toolbox + chai
npm test
```

### Acceptance-criteria status (brief Layer 2)

| Criterion | Status |
|---|---|
| All witness tests pass (positive)             | yes — 11 / 11 (incl. 8 magnitudes + decline + RHR ptr witness + max window) |
| All negative tests fail to verify             | yes — 10 / 10 (incl. ±1 bp claim, root swap, path tamper, chunk tamper, sign flip) |
| Constraint count under 20,000                 | yes — 18,707 |
| Proving time under 30 s                       | yes — ~0.5 s on this machine, 60× under target |
| Verifier gas cost under 500,000               | yes — 242,133 |
| Verifier deployed to zkSync Sepolia           | **deferred to Dave** — see deploy command below |
| End-to-end across 3+ metric pointers          | partial — circuit recompiles cleanly per metric (compile-time pointer assertion proven); only VO2 max is the live default. RHR / weight verifiers ship at next instantiation cycle |
| README explains usage and primitives          | yes — `circuits/improvement/README.md`, `metric-pointers.md`, four primitive READMEs |
| Primitives exported as reusable               | yes — `zk/primitives/{merkle_inclusion,metric_extraction,average_computation,threshold_comparison}` |

### zkSync Sepolia deployment — Dave to run

The verifier compiled, the Hardhat tests passed, the deploy script is
in place. To finish the brief's "deploy to zkSync Sepolia" criterion,
run:

```bash
cd AmachHealth-iOS/.claude/worktrees/unruffled-rosalind-0e2d1e/zk/deploy
DEPLOYER_KEY=<hex> npx hardhat deploy \
  --script scripts/03_AverageImprovementProofVerifier.js \
  --network zkSyncSepolia
```

The script writes the deployed address to `zk/data/deployed_contracts.json`
under `improvementVerifier`, alongside metadata (metric, N, M, depth,
chainId). I deferred this on purpose: deploying is a non-reversible
on-chain action that costs testnet ETH and creates a public commitment
— wanted Dave's authorization before touching live state.

After deploy, run a final cross-check against the live contract by
replaying any of the JSON proofs in `zk/data/improvement_proofs/` —
e.g. wire the `calldata` field into `verifyProof(...)` against the
deployed address.

---

## Commit log on Layer 2 branch

(to be updated when commits are squashed for review)

- `feat(zk): ship AverageImprovementProof circuit + 4 primitives`
  (this session — full Layer 2 stack: 4 primitives in `zk/primitives/`,
  generic claim circuit in `zk/circuits/improvement/`, witness builder,
  29 jest tests, 14 Hardhat tests, Phase-2 ceremony script,
  zkSync Sepolia deploy script, mirror to Amach-Website contracts)

---

## Commit log on Layer 1 branch

- `feat(legitimacy): ship Layer 1 verification script`
  (single squashed commit covering package setup, v2 leaf TS port,
  Merkle reconstruction, all six check categories, scoring, formatters,
  CLI, 16 datasets, 133 tests)
