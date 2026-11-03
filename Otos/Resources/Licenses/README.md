# Model notices

Otos ships two converted models (ADR 0045):

- `FocalNet.mlpackage` is Appwrite FocalNet's human-preference crop ranker
  (https://huggingface.co/appwrite/focalnet), converted to Core ML at full precision.
  MIT licence: `FocalNet-LICENSE.txt`.
- `GeoCalib.mlpackage` is the perspective-field network of GeoCalib: Single-image Calibration
  with Geometric Optimization, Alexander Veicht, Paul-Edouard Sarlin, Philipp Lindenberger and
  Marc Pollefeys, ECCV 2024 (https://github.com/cvg/GeoCalib), converted to Core ML at half
  precision with fixed NMF starting bases. Code: Apache License 2.0, `GeoCalib-LICENSE.txt`.
  Weights: © 2024 ETH Zurich, Creative Commons Attribution 4.0 International,
  `GeoCalib-LICENSE-WEIGHTS.txt`. The conversion changes the weights' precision and is a
  modification under that licence. `Otos/Services/PerspectiveFieldSolver.swift` ports
  GeoCalib's Levenberg–Marquardt solver.
