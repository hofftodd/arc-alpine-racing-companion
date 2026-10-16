#!/usr/bin/env bash
# Increment the build number (CURRENT_PROJECT_VERSION in project.yml) before each archive.
# Every upload to App Store Connect / TestFlight needs a build number it hasn't seen before.
#   scripts/bump_build.sh          # 7 -> 8
#   scripts/bump_build.sh 1.1.0    # also set the version shown to testers (MARKETING_VERSION)
set -euo pipefail
cd "$(dirname "$0")/.."

current=$(sed -nE 's/^ *CURRENT_PROJECT_VERSION: "([0-9]+)".*/\1/p' project.yml)
next=$((current + 1))
sed -i.bak -E "s/^( *CURRENT_PROJECT_VERSION: )\"[0-9]+\"/\1\"$next\"/" project.yml
if [ $# -ge 1 ]; then
  sed -i.bak -E "s/^( *MARKETING_VERSION: )\"[^\"]+\"/\1\"$1\"/" project.yml
fi
rm -f project.yml.bak
version=$(sed -nE 's/^ *MARKETING_VERSION: "([^"]+)".*/\1/p' project.yml)
echo "ARC $version (build $next). Now run: xcodegen generate"
