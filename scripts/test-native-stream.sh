#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"
# Select the reviewed Xcode per process; never change the Mac's global selection.
export DEVELOPER_DIR="$(python3 scripts/native-targets.py setting developerDir)"
./scripts/prepare-native-tests.sh
python3 scripts/run-native-test.py stream
