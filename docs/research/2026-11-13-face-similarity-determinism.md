# Are face decisions deterministic across processes? (2026-11-13)

## Question

`docs/research/2026-11-13-people-assignment-scale.md` (#722) records likeness values that
differ in the last bits (at most 4.8e-7) between old and new code, and between two runs of
the new code, and attributes it to Accelerate's matrix product rounding differently from
process to process. Assignment's threshold (0.434), margin (0.16) and group link (0.65)
read the same products (`BlockedSimilarity`, `vDSP_mmul`) with exact comparisons. If the
products wobble between processes for the same inputs, a borderline face could change
person on relaunch with no input change.

## Probe

A standalone Swift program (built with `-O`, run three times as separate processes) made
300 unit 512-d rows and 700 unit columns from a fixed generator and compared `vDSP_mmul`'s
products:

| Comparison | Products that differ | Largest difference |
| --- | --- | --- |
| Three processes, same inputs | 0 of 210,000 (same digest) | 0 |
| 300 rows at once against 7 rows at once (another block size) | 0 | 0 |
| 700 columns against the first 333 (another width) | 0 | 0 |
| Columns in reverse order (each product in another place) | 0 | 0 |
| `vDSP_mmul` against `vDSP_dotpr` per pair (another routine) | 195,200 | 1.8e-7 |

## Conclusion

On this Mac, `vDSP_mmul` gave bit-identical products across processes, block sizes, widths
and column orders. Only a different routine gave different last bits, which is what the
old-against-new comparison of #722 compared. The probe does not reproduce a wobble between
processes for the same code and inputs, so the claim that assignment's exact comparisons
flip between processes is not established, and the policy is left unchanged.

Quantising similarities to a fixed step would not make the decisions deterministic in any
case: any rounding of a value that wobbles has a boundary where the wobble crosses it, so it
moves the flip to the grid line rather than removing it. A real wobble would need products
computed in one fixed order (or integer embeddings), measured on the assignment benchmark.
