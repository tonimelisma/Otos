# Model notices

Otos ships three converted models (ADR 0045, ADR 0047):

- `FocalNet.mlpackage` is Appwrite FocalNet's human-preference crop ranker
  (https://huggingface.co/appwrite/focalnet), converted to Core ML at full precision.
  MIT licence: `FocalNet-LICENSE.txt`.
- `GeoCalib.mlpackage` is the perspective-field network of GeoCalib: Single-image Calibration
  with Geometric Optimization, Alexander Veicht, Paul-Edouard Sarlin, Philipp Lindenberger and
  Marc Pollefeys, ECCV 2024 (https://github.com/cvg/GeoCalib), converted to Core ML at half
  precision with fixed NMF starting bases. Code: Apache License 2.0, `GeoCalib-LICENSE.txt`.
  Weights: © 2024 ETH Zurich, Creative Commons Attribution 4.0 International,
  https://creativecommons.org/licenses/by/4.0/legalcode. The conversion changes the weights' precision and is a
  modification under that licence. `Otos/Services/PerspectiveFieldSolver.swift` ports
  GeoCalib's Levenberg–Marquardt solver.
- `AdaFaceIR101.mlpackage` is AdaFace IR-101 trained on WebFace12M, the CVLFace weights
  (https://huggingface.co/minchul/cvlface_adaface_ir101_webface12m), from AdaFace: Quality
  Adaptive Margin for Face Recognition, Minchul Kim, Anil K. Jain and Xiaoming Liu, CVPR 2022.
  It is converted to Core ML with 8-bit linear per-channel weights. Code: MIT,
  `AdaFace-LICENSE.txt`. The weights follow the training dataset's licence (WebFace260M,
  non-commercial research); Otos is non-commercial.
