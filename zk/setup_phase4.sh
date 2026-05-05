#!/usr/bin/env zsh
# setup_phase4.sh
# Amach Health ZK — Phase 4 automated setup
#
# Runs the full circuit compilation and trusted setup sequence.
# Run from the zk/ directory:
#   cd AmachHealth-iOS/zk && ./setup_phase4.sh

set -e  # exit on first error

echo ""
echo "════════════════════════════════════════════════"
echo "  AMACH HEALTH — Phase 4 ZK Setup"
echo "════════════════════════════════════════════════"
echo ""

# ─── Locate circom ────────────────────────────────────────────────
# Try PATH first, then common install locations from cargo/homebrew
CIRCOM=""
for candidate in \
    "$(command -v circom 2>/dev/null)" \
    "$HOME/.cargo/bin/circom" \
    "/usr/local/bin/circom" \
    "/opt/homebrew/bin/circom"
do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
        CIRCOM="$candidate"
        break
    fi
done

if [[ -z "$CIRCOM" ]]; then
    echo "❌  circom not found. Install it with:"
    echo ""
    echo "    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
    echo "    source ~/.cargo/env"
    echo "    git clone https://github.com/iden3/circom.git /tmp/circom"
    echo "    cd /tmp/circom && cargo build --release"
    echo "    cp /tmp/circom/target/release/circom ~/.cargo/bin/"
    echo ""
    exit 1
fi

echo "✅  circom found: $CIRCOM"
$CIRCOM --version
echo ""

# ─── Ensure we're in the zk/ directory ───────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
echo "Working directory: $SCRIPT_DIR"
echo ""

# ─── Create build directories ────────────────────────────────────
mkdir -p build/coverage
mkdir -p build/leaf_hash_test
mkdir -p data

# ─── Install npm dependencies ────────────────────────────────────
echo "📦 Installing npm dependencies..."
npm install --silent
echo ""

# ─── Step 1: Compile LeafHashTest circuit (Phase 2 cross-check) ──
echo "Step 1/7: Compiling LeafHashTest circuit..."
$CIRCOM circuits/LeafHashTest.circom \
    --r1cs --wasm --sym \
    -o build/leaf_hash_test \
    -l node_modules

echo "✅  LeafHashTest compiled"
echo ""

# ─── Step 2: Compile coverage circuit ────────────────────────────
echo "Step 2/7: Compiling coverage circuit (k=20, depth=8)..."
$CIRCOM circuits/coverage/coverage.circom \
    --r1cs --wasm --sym \
    -o build/coverage \
    -l node_modules

echo "✅  Coverage circuit compiled"
echo ""

# Log constraint count
echo "Constraint info:"
npx snarkjs r1cs info build/coverage/coverage.r1cs
echo ""

# ─── Step 3: Powers of Tau ceremony ──────────────────────────────
# The circuit has ~85k constraints, requiring at least 2^17 = 131,072 capacity.
# We generate a fresh local ceremony (dev-only — not production safe).
# For production: use a multi-party ceremony ptau file with sufficient capacity.
PTAU_FINAL="pot17_final.ptau"

if [[ -f "$PTAU_FINAL" ]]; then
    echo "Step 3/7: Powers of Tau file already exists — skipping"
    echo "  ($PTAU_FINAL)"
else
    echo "Step 3/7: Generating Powers of Tau ceremony locally (2^17, ~1 minute)..."
    echo "  (Dev-only ceremony — sufficient for testing, not for production)"

    npx snarkjs powersoftau new bn128 17 pot17_0000.ptau -v 2>&1 | grep -E "(Contribution|Done|Error)" || true
    echo "  Ceremony initialized"

    echo "amach-health-zk-dev-$(date +%s)" | \
        npx snarkjs powersoftau contribute pot17_0000.ptau pot17_0001.ptau \
            --name="dev-contribution" -v 2>&1 | grep -E "(Contribution|contribution|Done)" || true
    echo "  Randomness contributed"

    npx snarkjs powersoftau prepare phase2 pot17_0001.ptau "$PTAU_FINAL" -v 2>&1 | grep -E "(Preparing|Done|Written)" || true

    rm -f pot17_0000.ptau pot17_0001.ptau
    echo "✅  Powers of Tau ceremony ready: $PTAU_FINAL"
fi
echo ""

# ─── Step 4: Groth16 setup ────────────────────────────────────────
echo "Step 4/7: Running Groth16 setup (this may take a minute)..."
npx snarkjs groth16 setup \
    build/coverage/coverage.r1cs \
    "$PTAU_FINAL" \
    build/coverage/coverage_0.zkey

echo "✅  Groth16 setup complete"
echo ""

# ─── Step 5: Contribute randomness ───────────────────────────────
echo "Step 5/7: Contributing randomness to zkey..."
# Use a fixed entropy string for reproducible test setup.
# For production: run this interactively and enter real random text.
echo "amach-health-zk-v1-testentropy-$(date +%s)" | \
    npx snarkjs zkey contribute \
        build/coverage/coverage_0.zkey \
        build/coverage/coverage_final.zkey \
        --name="amach-v1-dev" \
        -v 2>&1 | grep -E "(contribution|hash|name)" || true

echo "✅  Randomness contributed"
echo ""

# ─── Step 6: Export verification key ─────────────────────────────
echo "Step 6/7: Exporting verification key..."
npx snarkjs zkey export verificationkey \
    build/coverage/coverage_final.zkey \
    build/coverage/verification_key.json

echo "✅  Verification key exported: build/coverage/verification_key.json"
echo ""

# ─── Step 7: Export Solidity verifier ────────────────────────────
echo "Step 7/7: Exporting Solidity verifier contract..."
npx snarkjs zkey export solidityverifier \
    build/coverage/coverage_final.zkey \
    circuits/coverage/CoverageVerifier.sol

echo "✅  Solidity verifier exported: circuits/coverage/CoverageVerifier.sol"
echo ""

# ─── Phase 2 cross-check: LeafHashTest ───────────────────────────
echo "════════════════════════════════════════════════"
echo "  Phase 2 Gate 4: Cross-implementation hash check"
echo "════════════════════════════════════════════════"
echo ""

# Read Case 0 from reference file and verify circuit matches JS
if [[ -f "data/phase2_reference_hashes.json" ]]; then
    node -e "
const ref = require('./data/phase2_reference_hashes.json');
const fs = require('fs');
// Write input for Case 0
const c = ref[0];
fs.writeFileSync('data/leaf_hash_test_input.json', JSON.stringify({
    chunk1: c.chunk1,
    chunk2: c.chunk2,
    chunk3: c.chunk3
}, null, 2));
console.log('Case 0 input written:');
console.log('  chunk1:', c.chunk1.slice(0, 20) + '...');
console.log('  expected hash:', c.hash.slice(0, 20) + '...');
"

    npx snarkjs wtns calculate \
        build/leaf_hash_test/LeafHashTest_js/LeafHashTest.wasm \
        data/leaf_hash_test_input.json \
        build/leaf_hash_test/witness.wtns

    npx snarkjs wtns export json \
        build/leaf_hash_test/witness.wtns \
        build/leaf_hash_test/witness.json 2>/dev/null

    node -e "
const witness = require('./build/leaf_hash_test/witness.json');
const ref = require('./data/phase2_reference_hashes.json');

// witness[0] is always '1', witness[1] is the output signal (hash)
const circuitHash = witness[1];
const jsHash = ref[0].hash;

if (circuitHash === jsHash) {
    console.log('✅ Gate 4 PASSED: Circuit hash matches Node.js hash');
    console.log('   hash:', circuitHash.slice(0, 30) + '...');
} else {
    console.log('❌ Gate 4 FAILED: Hash mismatch!');
    console.log('   Circuit:', circuitHash);
    console.log('   Node.js:', jsHash);
    process.exit(1);
}
"
else
    echo "⚠️  data/phase2_reference_hashes.json not found — run 'npm run test:phase2' first"
fi

echo ""

# ─── Run Phase 4 gate tests ───────────────────────────────────────
echo "════════════════════════════════════════════════"
echo "  Phase 4 Gate Tests (test_phase4.js)"
echo "════════════════════════════════════════════════"
echo ""
echo "  Running: node scripts/test_phase4.js"
echo "  (Gate Test 3 generates a real Groth16 proof — allow ~30s)"
echo ""

node scripts/test_phase4.js

echo ""
echo "════════════════════════════════════════════════"
echo "  PHASE 4 SETUP COMPLETE"
echo "════════════════════════════════════════════════"
echo ""
echo "Files ready:"
echo "  build/coverage/coverage_final.zkey"
echo "  build/coverage/verification_key.json"
echo "  circuits/coverage/CoverageVerifier.sol"
echo ""
echo "Next steps:"
echo "  1. Deploy CoverageVerifier.sol to zkSync Sepolia"
echo "  2. Deploy MerkleCommitment.sol with verifier address"
echo "  3. Export HealthKit data and run the genesis pipeline:"
echo "     node scripts/generate_genesis_root.js data/normalized_leaves.json"
echo "     node scripts/generate_proof.js 0 89 20"
echo "     PRIVATE_KEY=<key> CONTRACT_ADDRESS=<addr> node scripts/submit_genesis_root.js"
echo ""
