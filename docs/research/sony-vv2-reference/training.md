# Training algorithm and what survives removal of media

The checked-in `model.json` contains the final learned function. Applying it or
porting it to another language does not require the original pictures, decoded
images, sampled pixel arrays, private manifests, galleries, or `/tmp` files.
`test-vectors.json` contains invented numeric colors, never samples from photos.

Deleting the training data does remove the ability to independently repeat the
historical photographic quality evaluation or retrain the identical model. It
does not remove the learned function. Future training uses new paired captures.
The aggregate historical evidence is retained in the parent research note and
`validation-summary.json`.

## Exact fitting procedure

The historical preprocessing, pairing, alignment, masks, split policy, and color
spaces are specified in the parent research note. This section fixes the numeric
learning rules, independent of the historical Python/SciPy implementation. Apple
Accelerate's BLAS/LAPACK can solve the same normal equations; no third-party
library is required by the algorithm or the saved model's runtime.

Given N finite neutral/target RGB pairs X and Y:

1. Set D = 1.25 and 49 uniformly spaced curve knots k[j] = D*j/48.
2. Independently for each channel c, assign every sample to
   j = clamp(roundToNearestEven(X[c]/D*48), 0, 48). Count samples n[j] and sum
   targets s[j]. Use weight w[j] = n[j]+1 and provisional mean
   v[j] = (s[j]+clamp(k[j],0,1))/w[j]. This is one identity-prior observation
   per knot, including empty bins.
3. Solve weighted isotonic regression for nondecreasing v, using the
   pool-adjacent-violators algorithm: start with one weighted block per knot;
   merge neighboring decreasing blocks, replacing their means by the weighted
   mean, until no violation remains. Expand block means back to 49 knots.
4. Evaluate the fitted curves using linear interpolation and constant endpoint
   extension. Let E[i] = Y[i] - curve(X[i]). Curve interpolation does not alter
   the coordinates used for the residual LUT.
5. Define a 9x9x9 node cube over the original neutral coordinates [0,D]^3.
   Each row of A contains the eight trilinear interpolation weights for X[i],
   with node flattening index r*81 + g*9 + b. Clamp coordinates to the cube
   boundary; at the maximum use lower index 7 and interpolation fraction 1.
6. Let B be the incidence matrix of all immediate axis-neighbor cube edges,
   with one +1 and one -1 per edge. For each output channel solve
   (AᵀA + 10 BᵀB + 2 I) z = AᵀE. The positive identity term makes the system
   positive definite, suitable for Cholesky. Use Float64 during fitting.
7. Store curves and the three residual solutions. At inference evaluate BOTH
   on the original neutral coordinates, add the results, then clip to [0,1].
   Do not feed curve outputs into the residual cube, and do not clip cube node
   values before interpolation.

Each historical training image contributed 2,500 admitted pixels, with no
per-image exposure fitting against its target during prediction. The final
coefficients used all 344 pairs; held-out photographic metrics came from
separate fits described in the parent note. The reference data does not claim
strict final-function monotonicity; only the one-dimensional curves are monotonic.

## Source of truth

`model.json` is the exact portable parameter data. A sampled `.cube` file is an
approximation and is not needed. Model format version 1 specifies [R][G][B][RGB]
array order, uniform curve knots, finite coefficients, domain [0,1.25], and the
original-input residual convention. Preserve numeric values when reformatting.
The saved function is specific to its documented RAW development, camera/look,
and SDR output assumptions. No original image is embedded in these parameters.
