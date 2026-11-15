#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"
# Select the reviewed Xcode per process; never change the Mac's global selection.
export DEVELOPER_DIR="$(python3 scripts/native-targets.py setting developerDir)"
./scripts/prepare-native-tests.sh
for target in status-menu display-topology privacy input; do
    python3 scripts/run-native-test.py "$target"
done
swift_target="$(python3 scripts/native-targets.py setting swiftTarget)"
clang -fobjc-arc -O2 -Wall -Werror -DML_VIRTUAL_DISPLAY_TESTING -target "$swift_target" \
    -framework Foundation -framework CoreGraphics app/NativeVirtualDisplay.m scripts/test-native-display.m \
    -o target/mooring-native-display-boundary-tests
target/mooring-native-display-boundary-tests
python3 scripts/run-native-test.py vnc-viewer "$project_root"
python3 scripts/run-native-test.py media > target/native-media-report.json
python3 scripts/run-native-test.py session "target/$(python3 scripts/native-targets.py setting rustTarget)/release/mooring"
python3 scripts/run-native-test.py stream
python3 scripts/run-native-test.py workflows
printf '%s\n' 'All native and application workflow tests passed.'
