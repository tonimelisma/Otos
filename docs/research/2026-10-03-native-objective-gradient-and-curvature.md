# Native objective gradient and stabilized curvature

Date: October 3, 2026. Plan0105 numerical development work. Photographic matching
and shared inference acceptance remain open. RAW9, fixed geometry, field and colour
limits are unchanged. Embedded camera images remain excluded.

## Research and mathematical boundary

[Boyd and Vandenberghe, unconstrained minimization](https://stanford.edu/class/ee364a/lectures/unconstrained.pdf)
describe a quadratic/Newton step using the objective gradient and a positive
curvature matrix, with line search controlling accepted displacement. This supports
checking the first derivative independently of the curvature approximation. Their
smooth convex convergence guarantees do not apply automatically to our clipped,
finite-difference native pipeline with a changing worst-five-percent tail.

For an absolute bounded position y, a local quadratic with displacement y-x has
first derivative g at x only if its linear system has rhs H*x-g. Stabilizing H
near zero residuals can retain that derivative. Flooring the residual denominator
in both H and a residual-derived rhs instead changes the quadratic fixed point.
Actual native scalar loss still decides every accepted step. This derivation does
not certify global model capacity, convergence or HEIF matching.

## Frozen-state audit

A private regression-role audit freezes the final full-support cyan coefficients;
it performs181 native observations, with all81 central columns and nine half-step
checks. No optimization is performed. At that state, the reported analytic
projected gradient is0.17483; direct actual-objective projected differences reach
0.22132. Dark-node columns0/1 disagree in sign, with absolute differences0.184/0.205
and meaningful half-step changes. Tail membership changes are reported explicitly.

A second bounded diagnostic separates the mean derivative and the quadratic
floor's gradient. Maximum absolute quadratic gradient is0.17001, near the analytic
0.17483. Therefore the norm floor is not established as the dominant native
plateau cause. The numerical disagreement remains a limit on convergence claims.
No gradient threshold or photographic limit is relaxed.

## Reproduced defect and bounded correction

An observable pure solver fixture requests a0.01scalar correction under the
existing distance objective and priors. The old quadratic stalls with residual
0.000935, although the distance optimum reaches the target. A six-step tolerance
of1e-5 catches this wrong-objective fixed point.

Removing the0.1floor from curvature was tested and rejected: the bounded-solve
fixture reports `didNotConverge`. It is not a fallback or accepted numerical change.

The accepted numerical correction retains stabilized curvature and its existing
priors, but forms rhs H*x-g from the declared objective gradient. Line search
permits at most twenty halving trials per step; outer iterations remain six. Five
coarse fractions can all overshoot a small necessary correction. The repaired
fixture reaches residual5.615e-6 rather than0.000935 and retains explicit budget
exhaustion rather than claiming global convergence. Published colour and CPU/Metal
fixtures remain green. Report contract3 names the gradient-based quadratic step,
curvature floor and line-search budget.

## Actual native result and stopping decision

The same full-support cyan fit completes1015 native observations in241.45seconds.
All six steps accept fraction1, so this image does not need the added line-search
range. Objective2.718240 versus2.718241 is effectively unchanged. Actual HEIF
whole-image mean/p95 is1.7384/4.7600; face1.0310 and white0.9094 pass. Cyan2.1091
and reliable grid-4-1 mean2.0427 still fail. All twenty outcomes remain twelve
passes, five failures and three inconclusive. No photograph changes status.

Adopt the reproduced numerical-correctness repair, but reject it as a resolution
of the cyan photographic failure. Close this bounded solver investigation; do not
extend iterations or run more floor/step sweeps. Remaining derivative uncertainty
is recorded, not transformed into a global-capacity conclusion.

The next measured question is loss alignment: a pooled region mean/tail plus a
profile prior is not a requirement that every reliable region meet its limit.
Audit per-region feasibility with full support before interpreting the near-limit
failures as inadequate colour capacity. Any new objective must be explicitly
named/versioned, retain original photographic limits, and pass actual native
whole-image and original-region checks. Diagnostic per-photo fits never become
shared inference recipes or independent validation.
