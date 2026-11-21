# Model notices

Otos ships four converted models (ADR 0045, ADR 0047, ADR 0048):

- `FocalNet.mlpackage` is Appwrite FocalNet's human-preference crop ranker
  (https://huggingface.co/appwrite/focalnet), converted to Core ML at full precision.
  MIT licence: `FocalNet-LICENSE.txt`.
- `GeoCalib.mlpackage` is the perspective-field network of GeoCalib: Single-image Calibration
  with Geometric Optimization, Alexander Veicht, Paul-Edouard Sarlin, Philipp Lindenberger and
  Marc Pollefeys, ECCV 2024 (https://github.com/cvg/GeoCalib), converted to Core ML at half
  precision with fixed NMF starting bases. Code: Apache License 2.0, `GeoCalib-LICENSE.txt`.
  Weights: © 2024 ETH Zurich, Creative Commons Attribution 4.0 International,
  https://creativecommons.org/licenses/by/4.0/legalcode. The conversion changes the weights' precision and is a
  modification under that licence. `OtosKit/Services/PerspectiveFieldSolver.swift` ports
  GeoCalib's Levenberg–Marquardt solver.
- `AdaFaceIR101.mlpackage` is AdaFace IR-101 trained on WebFace12M, the CVLFace weights
  (https://huggingface.co/minchul/cvlface_adaface_ir101_webface12m), from AdaFace: Quality
  Adaptive Margin for Face Recognition, Minchul Kim, Anil K. Jain and Xiaoming Liu, CVPR 2022.
  It is converted to Core ML with 8-bit linear per-channel weights. Code: MIT,
  `AdaFace-LICENSE.txt`. The weights follow the training dataset's licence (WebFace260M,
  non-commercial research); Otos is non-commercial.
- `SigLIP2Image.mlpackage`, `SigLIP2Text.mlpackage`, `SigLIP2TokenEmbeddings-0…3.bin` and
  `SigLIP2Tokenizer.bin` are SigLIP 2 B/16-256 (https://huggingface.co/timm/ViT-B-16-SigLIP2-256),
  from SigLIP 2: Multilingual Vision-Language Encoders, Michael Tschannen et al., 2025. Both
  towers are converted to Core ML with 8-bit linear per-channel weights; the text tower's token
  table is stored as int8 rows with per-row scales, and its Gemma tokenizer as a binary
  vocabulary and merge list. Apache License 2.0: `SigLIP2-LICENSE.txt`.
