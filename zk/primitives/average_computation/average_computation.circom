pragma circom 2.0.0;

// average_computation.circom
// Amach Health ZK — Verification Factory primitive
//
// Template: AverageComputation(N)
//
// Sums an N-element vector and exposes both the running sum and the count.
//
// Why a primitive at all?
//   Field arithmetic doesn't have integer division. The "average" claim has
//   to be re-expressed as an integer equation:
//
//       sum(values) == average * N + remainder,   0 <= remainder < N
//
//   Each call site needs the *sum* and *N* — the average itself is a
//   downstream verification. Pulling the sum + N exposure into a named
//   primitive avoids reinventing it in every claim circuit and gives the
//   reader a single template to reason about.
//
// Inputs:
//   values[N]   field elements representing per-leaf metric values. Range
//               checks (e.g. that each is < 2^16 for a u16 metric) are the
//               caller's responsibility — `MetricExtraction` does that
//               implicitly via Num2Bits.
//
// Outputs:
//   sum   sum of `values` (no division performed in-circuit)
//   n     constant N, exposed for the downstream improvement equation so
//         callers don't need to plumb the compile-time constant separately
//
// Constraint cost: N - 1 additions (no quadratic constraints).

template AverageComputation(N) {
    assert(N >= 1);

    signal input values[N];
    signal output sum;
    signal output n;

    // Running sum via a chain of intermediate signals. Circom 2.x requires
    // each linear combination to flow through a declared signal.
    signal running[N + 1];
    running[0] <== 0;
    for (var i = 0; i < N; i++) {
        running[i + 1] <== running[i] + values[i];
    }
    sum <== running[N];
    n   <== N;
}
