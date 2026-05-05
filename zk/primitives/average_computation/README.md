# AverageComputation

Sums an N-element vector and exposes the running sum and N. Pure linear
arithmetic — zero quadratic constraints. The "average" itself is never
computed in-circuit; field elements have no integer division. Downstream
circuits express the average as `sum * (1/N) ≡ ...` reformulated as a
multiplicative integer equation (see `improvement.circom`).

```circom
include "../../primitives/average_computation/average_computation.circom";

component avg = AverageComputation(7);
for (var i = 0; i < 7; i++) {
  avg.values[i] <== metricValues[i];
}
signal baselineSum, baselineN;
baselineSum <== avg.sum;
baselineN   <== avg.n;
```

## Constraint cost

`N - 1` linear constraints (additions through a chain of intermediate
signals). At N=7 that is 6 constraints — negligible compared with the
Merkle paths and Poseidon hashes around it.
