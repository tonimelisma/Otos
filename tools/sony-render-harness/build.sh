#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 1 ]]; then
    echo "usage: $0 output-directory" >&2
    exit 2
fi

root="$(cd "$(dirname "$0")/../.." && pwd)"
output="$1"
mkdir -p "$output/swift-cache"

# The preserved numerical model is the one source for the baseline algorithm.
# Extract its Swift listing into the private build directory; never fork it here.
awk '/^```swift$/{inside=1;next}/^```$/{inside=0}inside' \
    "$root/docs/research/sony-vv2-reference/NativeReference.swift.md" \
    > "$output/NativeReference.swift"
if [[ ! -s "$output/NativeReference.swift" ]]; then
    echo "missing native reference listing" >&2
    exit 1
fi

xcrun swiftc -O -module-cache-path "$output/swift-cache" \
    "$root/script/sony-render-harness/ColorDifference.swift" \
    "$root/script/sony-render-harness/Scorecard.swift" \
    "$root/script/sony-render-harness/Geometry.swift" \
    "$root/script/sony-render-harness/Viewer.swift" \
    "$output/NativeReference.swift" \
    "$root/script/sony-render-harness/main.swift" \
    -o "$output/sony-render-harness"

xcrun swiftc -O -parse-as-library -module-cache-path "$output/swift-cache" \
    "$root/script/sony-render-harness/Materialize.swift" \
    -o "$output/sony-render-materialize"

"$output/sony-render-harness" self-test \
    "$root/script/sony-render-harness/ciede2000-reference.txt"
