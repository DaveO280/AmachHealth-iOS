# ThresholdComparison

Two templates that share a "compare integer values that have to be honest"
theme:

- **`ThresholdEqual(nBits)`** — assert two values are equal AND fit in
  `nBits`. Without the range check, a prover could exploit the field
  modulus to forge equality.
- **`SignedImprovementCheck(nBits)`** — encode the per-cent improvement
  identity in the form
  `claimedMagnitudeBp * baselineSum * M == 10000 * |finishSum*N - baselineSum*M|`
  with an explicit `signFlag` selecting the direction. The selected
  `diff` is range-checked to `nBits`, which is what makes the prover unable
  to lie about the sign.

```circom
include "../../primitives/threshold_comparison/threshold_comparison.circom";

component check = SignedImprovementCheck(64);
check.baselineSum      <== bSum;
check.baselineN        <== 7;
check.finishSum        <== fSum;
check.finishM          <== 7;
check.claimedMagnitude <== 1234;        // 12.34 % in basis points
check.signFlag         <== 0;           // 0 = improvement, 1 = decline
```

## Why nBits = 64?

The largest in-circuit product is roughly `claimedMagnitude * baselineSum * M`.
With Spring Push bounds (claimed ≤ 1e6, baselineSum ≤ 7·65535, M ≤ 7) that
product is below 2^45. We size at 64 bits for headroom; the BN-128 field is
254 bits so there is no overflow risk and the extra ~40 bits of bitify cost
is negligible.

## Constraint cost

| Template                       | Approx constraints |
|--------------------------------|--------------------|
| ThresholdEqual(64)             | ~130 (2 * Num2Bits + 1) |
| SignedImprovementCheck(64)     | ~140 (2 * Num2Bits + 6 mults) |

(`Num2Bits(64)` is 64 constraints.)
