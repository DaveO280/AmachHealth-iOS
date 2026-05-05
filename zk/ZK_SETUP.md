# Amach Health ZK Setup Guide

**Circuit compilation and trusted setup — run these commands on Mac.**

---

## Prerequisites

Verify these are installed before starting:

```bash
# Node.js (already required for the app)
node --version   # v18+

# Circom (must be installed on Mac — Dave has this)
circom --version  # 2.x.x

# snarkJS (installed via npm in this project)
npx snarkjs --version
```

Install project dependencies if not already done:
```bash
cd zk/
npm install
```

---

## Phase 2: Cross-Implementation Hash Check (Gate Test 4)

After Phase 2 JS tests pass, verify the circuit produces identical hashes.

### 1. Install circomlib (circuit dependency)

```bash
cd zk/
npm install circomlib
```

### 2. Compile the leaf hash test circuit

```bash
circom circuits/LeafHashTest.circom --r1cs --wasm --sym -o build/leaf_hash_test
```

Expected output: `build/leaf_hash_test/LeafHashTest_js/LeafHashTest.wasm`

### 3. Run cross-implementation check

For each test case in `data/phase2_reference_hashes.json`, create an input file and verify:

```bash
# Example for Case 0 (dayId=0)
# Use the chunk1/chunk2/chunk3 values from phase2_reference_hashes.json
echo '{
  "chunk1": "70621183824797172256250912681990760496200240445074109899949714347",
  "chunk2": "303315674932441677683382695855414798494455648518553716198840432583898877132",
  "chunk3": "361850278866613110698659328152149712041468702080126762623304950024715108352"
}' > data/leaf_hash_test_input.json

npx snarkjs wtns calculate \
  build/leaf_hash_test/LeafHashTest_js/LeafHashTest.wasm \
  data/leaf_hash_test_input.json \
  build/leaf_hash_test/witness.wtns

npx snarkjs wtns export json build/leaf_hash_test/witness.wtns build/leaf_hash_test/witness.json
```

The `hash` output signal in `witness.json` must equal the `hash` field in `phase2_reference_hashes.json`.

**Expected hash for Case 0:**
```
10624258506532291056591391588113233372591132883956521400149586014890874408090
hex: 0x177d1e01fd3e005d5944afe07ec7810dc3ec8a94934a58862d605c4e4bdc8c9a
```

**Gate 4 passes when: circuit hash == Node.js hash for all 4 test cases.**

---

## Phase 4: Coverage Circuit Compilation and Trusted Setup

This is the main circuit. Run after Phase 3 gate tests pass.

### 1. Compile the coverage circuit

```bash
cd zk/

circom circuits/coverage/coverage.circom \
  --r1cs --wasm --sym \
  -o build/coverage \
  -l node_modules

# Check constraint count (should be < 100k for k=20, depth=8)
npx snarkjs r1cs info build/coverage/coverage.r1cs
```

### 2. Download Powers of Tau ceremony file

This is a pre-trusted public parameters file from the Hermez ceremony.
Safe to use for testing. For production, use a ceremony with more participants.

```bash
# 2^15 = 32768 constraints max — sufficient for the v1 circuit
wget https://hermez.s3-eu-west-1.amazonaws.com/powersOfTau28_hez_final_15.ptau \
  -O powersOfTau28_hez_final_15.ptau
```

If the circuit has > 32768 constraints, use `_final_16.ptau` (2^16 = 65536).

### 3. Generate the proving key (Groth16 setup)

```bash
npx snarkjs groth16 setup \
  build/coverage/coverage.r1cs \
  powersOfTau28_hez_final_15.ptau \
  build/coverage/coverage_0.zkey
```

### 4. Contribute randomness (required for security)

Even for testing, a contribution step is required:

```bash
npx snarkjs zkey contribute \
  build/coverage/coverage_0.zkey \
  build/coverage/coverage_final.zkey \
  --name="amach-v1-test" \
  -v
```

Enter any random text when prompted — this is the contribution entropy.

### 5. Export the verification key

```bash
npx snarkjs zkey export verificationkey \
  build/coverage/coverage_final.zkey \
  build/coverage/verification_key.json
```

### 6. Export the Solidity verifier contract

```bash
npx snarkjs zkey export solidityverifier \
  build/coverage/coverage_final.zkey \
  circuits/coverage/CoverageVerifier.sol
```

This generates the Solidity contract that goes on-chain (deployed before MerkleCommitment.sol).

---

## Phase 4 Gate Tests

After compilation:

```bash
# Gate Test 1: Circuit compiles and constraint count is logged
npx snarkjs r1cs info build/coverage/coverage.r1cs

# Gate Test 2: Generate a valid proof
node scripts/generate_proof.js
# (runs dry-run test — actual proof requires genesis data)

# For a full proof with real data:
# 1. Export normalized_leaves.json from iOS
# 2. Run: node scripts/generate_genesis_root.js data/normalized_leaves.json
# 3. Run: node scripts/generate_proof.js 0 89 20
```

---

## Phase 5: On-Chain Deployment

### Deploy contracts (Hardhat + zkSync)

```bash
# In your Hardhat project (separate from this zk/ directory)
# 1. Copy CoverageVerifier.sol to your contracts/ directory
# 2. Deploy to zkSync Era Sepolia

npx hardhat compile
npx hardhat deploy --network zkSyncTestnet

# Note the deployed CoverageVerifier address
# Deploy MerkleCommitment.sol with that address as constructor argument
```

### Submit genesis root

```bash
PRIVATE_KEY=<your_key> \
CONTRACT_ADDRESS=<merkle_commitment_contract_addr> \
node scripts/submit_genesis_root.js
```

---

## Reference: Known Good Hash Values (Phase 2)

These values are the ground truth for cross-implementation verification.
Any circuit or Swift implementation claiming Poseidon compatibility must reproduce these.

| Case | dayId | hash (decimal) |
|------|-------|----------------|
| 0    | 0     | 10624258506532291056591391588113233372591132883956521400149586014890874408090 |
| 1    | 1     | 3267957912595189932182216700203961407135278903482669743250508854061102765201 |
| 2    | 100   | 12042450195781513805720640806171006384959716467134791745025719786018971243820 |
| 3    | 42    | 7684398451330020371245941855232954676525327631258639629656789520948881323673 |

Full reference values: `data/phase2_reference_hashes.json`

---

## File Structure

```
zk/
├── circuits/
│   ├── LeafHashTest.circom          Phase 2 cross-check circuit
│   └── coverage/
│       ├── merkle_verify.circom     Merkle path verification template
│       ├── coverage.circom          Main coverage proof circuit
│       └── MerkleCommitment.sol     On-chain contract (Phase 5)
├── scripts/
│   ├── hash_leaf.js                 Poseidon leaf hashing
│   ├── hash_leaves_batch.js         Batch hashing (called by iOS)
│   ├── build_tree.js                Merkle tree construction
│   ├── build_tree_cli.js            CLI wrapper (called by iOS)
│   ├── generate_genesis_root.js     Full Phase 1→3 pipeline
│   ├── generate_proof.js            Phase 4 proof generation
│   ├── submit_genesis_root.js       Phase 5 on-chain submission
│   ├── test_phase2.js               Phase 2 gate tests
│   └── test_phase3.js               Phase 3 gate tests
├── data/
│   ├── phase2_reference_hashes.json Known-good hashes for circuit verification
│   └── (genesis_tree.json after running generate_genesis_root.js)
├── build/
│   └── (compiled circuit artifacts go here)
├── package.json
└── ZK_SETUP.md                      This file
```
