pragma circom 2.0.0;

// threshold_comparison.circom
// Amach Health ZK — Verification Factory primitive
//
// Two related templates:
//
//   ThresholdEqual(nBits)
//     Asserts `actual === claimed` (both range-checked to nBits). The
//     range check matters: bare `===` doesn't enforce that the values are
//     actual u<nBits> integers, so a malicious prover could otherwise
//     wrap around the field modulus.
//
//   SignedImprovementCheck(nBits)
//     Encodes the improvement equation
//       claimedMagnitudeBp * baselineSum * M == diff * 10000
//     where:
//       diff = signFlag == 0  ?  finishSum*N - baselineSum*M
//              signFlag == 1  ?  baselineSum*M - finishSum*N
//     and asserts `signFlag * (1 - signFlag) === 0` (boolean).
//
// Why pull this into a named primitive?
//   The signed-improvement equation is non-trivial because the field has no
//   native sign. Folding it into a re-usable primitive avoids reinventing
//   the trick in every claim circuit and makes the composition in
//   `improvement.circom` legible.
//
// Constraint cost:
//   ThresholdEqual(nBits)             ~ 2 * nBits + 1 (two Num2Bits + 1 eq)
//   SignedImprovementCheck(nBits)     ~ 2 * nBits + 8 (Num2Bits + a handful
//                                                     of multiplications)
//
// nBits is sized for the largest possible product. For Spring Push we need
// to cover claimedMagnitudeBp ≤ 1e6 (10000% in basis points), baselineSum
// ≤ 7 * 65535 ≈ 4.6e5, and M ≤ 7. The product is ≤ 1e6 * 4.6e5 * 7 ≈ 3.2e12,
// well under 2^45. We size nBits=64 for safety; the field is 254 bits so
// there's no overflow risk and the cost is negligible.

include "../../node_modules/circomlib/circuits/bitify.circom";
include "../../node_modules/circomlib/circuits/comparators.circom";

template ThresholdEqual(nBits) {
    signal input actual;
    signal input claimed;

    // Range-check both inputs to nBits. Without this, a prover could submit
    // an "actual" of (claimed + p) — equal in the field but not a real
    // integer match.
    component aBits = Num2Bits(nBits);
    component cBits = Num2Bits(nBits);
    aBits.in <== actual;
    cBits.in <== claimed;

    actual === claimed;
}

template SignedImprovementCheck(nBits) {
    // ── inputs ──────────────────────────────────────────────────────────
    signal input baselineSum;     // sum of N baseline values
    signal input baselineN;       // = N (compile-time, but plumbed for
                                  //   composition with AverageComputation)
    signal input finishSum;       // sum of M finish values
    signal input finishM;         // = M
    signal input claimedMagnitude;// claimed |improvement|, in basis points
                                  //   (1234 = 12.34 %)
    signal input signFlag;        // 0 = improvement (finishAvg >= baselineAvg)
                                  // 1 = decline    (finishAvg <  baselineAvg)

    // ── 0. signFlag must be boolean ─────────────────────────────────────
    signFlag * (1 - signFlag) === 0;

    // ── 1. Compute the cross-multiplied numerator and denominator. ──────
    //
    //     improvement = (finishAvg - baselineAvg) / baselineAvg
    //                 = (finishSum/M - baselineSum/N) / (baselineSum/N)
    //                 = (finishSum*N - baselineSum*M) / (baselineSum*M)
    //
    // To avoid in-circuit division we re-arrange:
    //
    //     claimed_bp * (baselineSum * M) ==  10000 * (finishSum*N - baselineSum*M)   (improvement)
    //     claimed_bp * (baselineSum * M) ==  10000 * (baselineSum*M - finishSum*N)   (decline)
    //
    // We bundle both into a single equation by selecting the rhs based on
    // signFlag.
    signal denom;
    denom <== baselineSum * finishM;     // baselineSum * M

    // baselineSum > 0 — otherwise the equation is trivially 0=0 and any
    // claim "succeeds". We require the prover to expose a non-zero
    // inverse, which only exists for non-zero values.
    signal baselineSumInv;
    baselineSumInv <-- 1 / baselineSum;
    baselineSum * baselineSumInv === 1;

    // diffPos = finishSum * baselineN  -  baselineSum * finishM
    // diffNeg = baselineSum * finishM  -  finishSum * baselineN
    signal finishCross;
    signal baselineCross;
    finishCross   <== finishSum   * baselineN;
    baselineCross <== baselineSum * finishM;
    signal diffPos;
    signal diffNeg;
    diffPos <== finishCross   - baselineCross;
    diffNeg <== baselineCross - finishCross;

    // Select diff based on signFlag.
    //   signFlag == 0 -> diff = diffPos
    //   signFlag == 1 -> diff = diffNeg
    // diff = diffPos + signFlag * (diffNeg - diffPos)
    //      = diffPos - signFlag * diffPos + signFlag * diffNeg
    signal diffSel;
    signal selA;
    signal selB;
    selA <== signFlag * diffPos;
    selB <== signFlag * diffNeg;
    diffSel <== diffPos - selA + selB;

    // The selected diff must be non-negative (range-checked to nBits).
    // This is what FORCES signFlag to honestly indicate the direction:
    // if signFlag is wrong, the "selected diff" wraps the field and fails
    // the range check.
    component diffBits = Num2Bits(nBits);
    diffBits.in <== diffSel;

    // ── 2. The improvement equation. ────────────────────────────────────
    signal lhs;
    lhs <== claimedMagnitude * denom;
    lhs === diffSel * 10000;

    // ── 3. Range-check the magnitude so a wrap-around can't satisfy LHS.
    component magBits = Num2Bits(nBits);
    magBits.in <== claimedMagnitude;
}
