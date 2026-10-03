#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 1 ]]; then
    echo "usage: $0 output-directory" >&2
    exit 2
fi

root="$(cd "$(dirname "$0")/../.." && pwd)"
output="$1"
mkdir -p "$output/swift-cache"

python3 -B "$root/tools/sony-render-harness/verify_capture_test.py"

xcrun swiftc -O -swift-version 6 -strict-concurrency=complete -Xcc -DACCELERATE_NEW_LAPACK -module-cache-path "$output/swift-cache" \
    "$root/Otos/Support/Instrumentation.swift" \
    "$root/tools/sony-render-harness/NativeRAWDevelopment.swift" \
    "$root/tools/sony-render-harness/AuthoredLook.swift" \
    "$root/tools/sony-render-harness/CreativeColour.swift" \
    "$root/tools/sony-render-harness/BoundedColourSolve.swift" \
    "$root/tools/sony-render-harness/NativeProfileFieldSolve.swift" \
    "$root/tools/sony-render-harness/NativeProfileField.swift" \
    "$root/tools/sony-render-harness/ConditionalProfile.swift" \
    "$root/tools/sony-render-harness/ConditionalProfileSelfTest.swift" \
    "$root/tools/sony-render-harness/NativeInputRangeAudit.swift" \
    "$root/tools/sony-render-harness/DisplayColourCalibration.swift" \
    "$root/tools/sony-render-harness/AuthoredLookSelfTest.swift" \
    "$root/tools/sony-render-harness/LookRegions.swift" \
    "$root/tools/sony-render-harness/AuthoredCalibration.swift" \
    "$root/tools/sony-render-harness/AuthoredCapacitySelfTest.swift" \
    "$root/tools/sony-render-harness/AuthoredCalibrationExport.swift" \
    "$root/tools/sony-render-harness/ColorDifference.swift" \
    "$root/tools/sony-render-harness/Scorecard.swift" \
    "$root/tools/sony-render-harness/ComparisonCalibration.swift" \
    "$root/tools/sony-render-harness/NativeOrderDiagnostic.swift" \
    "$root/tools/sony-render-harness/Geometry.swift" \
    "$root/tools/sony-render-harness/NativeGeometry.swift" \
    "$root/tools/sony-render-harness/LensAudit.swift" \
    "$root/tools/sony-render-harness/Viewer.swift" \
    "$root/tools/sony-render-harness/SensorRAWHEIFRenderer.swift" \
    "$root/tools/sony-render-harness/SensorRAWHEIFSelfTest.swift" \
    "$root/tools/sony-render-harness/SensorRAWHEIFEvaluation.swift" \
    "$root/tools/sony-render-harness/LookModel.swift" \
    "$root/tools/sony-render-harness/LookCalibration.swift" \
    "$root/tools/sony-render-harness/LookCalibrationSelfTest.swift" \
    "$root/tools/sony-render-harness/LookModelSelfTest.swift" \
    "$root/tools/sony-render-harness/main.swift" \
    -o "$output/sony-render-harness"

xcrun swiftc -O -swift-version 6 -strict-concurrency=complete -parse-as-library -module-cache-path "$output/swift-cache" \
    "$root/tools/sony-render-harness/Materialize.swift" \
    -o "$output/sony-render-materialize"

"$output/sony-render-harness" self-test \
    "$root/tools/sony-render-harness/ciede2000-reference.txt"
"$output/sony-render-harness" look-self-test \
    "$root/docs/research/sony-vv2-raw9-reference/model.json" \
    "$root/docs/research/sony-vv2-raw9-reference/test-vectors.json"
