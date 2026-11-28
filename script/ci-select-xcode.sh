#!/usr/bin/env bash
# Selects the newest Xcode 27 on GitHub's xcode-27 runner and prints `build=<Xcode build>` for
# $GITHUB_OUTPUT: the build caches are keyed by it, because another Xcode's compile results
# could never be hits. Every workflow job on that runner selects Xcode through here.
set -euo pipefail

xcode="$(ls -d /Applications/Xcode_27*.app | sort -V | tail -n 1)"
sudo xcode-select --switch "$xcode/Contents/Developer"
xcodebuild -version >&2
echo "build=$(xcodebuild -version | awk '/Build version/ { print $3 }')"
