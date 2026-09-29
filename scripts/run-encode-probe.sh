#!/bin/bash
# Compile and run the synthetic probe with bounded subprocess lifetimes.
set -euo pipefail
if (( $# > 2 )); then
  echo "Usage: $0 [report.json] [artifact-directory]" >&2
  exit 2
fi
script_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
project_dir="$(dirname -- "$script_dir")"
report_path="${1:-$project_dir/docs/local-encode-feasibility.json}"
artifact_directory="${2:-$project_dir/target/encode-probe/artifacts}"
/usr/bin/python3 - "$project_dir" "$report_path" "$artifact_directory" <<'PY'
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile

project, report, artifacts = (Path(p).expanduser().resolve() for p in sys.argv[1:])
build = project / 'target' / 'encode-probe'
build.mkdir(parents=True, exist_ok=True)
artifacts.mkdir(parents=True, exist_ok=True)
executable = build / 'encode-probe'

def bounded(arguments, timeout):
    child = subprocess.Popen(arguments, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    try:
        output, errors = child.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(child.pid, signal.SIGKILL)
        child.communicate()
        raise SystemExit(f'Probe stopped after {timeout} seconds: {arguments[0]}')
    if errors:
        sys.stderr.buffer.write(errors)
    if child.returncode:
        raise SystemExit(f'Command failed ({child.returncode}): {arguments[0]}')
    return output

bounded(['/usr/bin/xcrun', 'swiftc', '-warnings-as-errors', '-O', str(project / 'scripts' / 'encode-probe.swift'), '-o', str(executable)], 90)
output = bounded([str(executable), str(artifacts), '/opt/homebrew/bin/ffprobe'], 60)
findings = json.loads(output)
report.parent.mkdir(parents=True, exist_ok=True)
with tempfile.NamedTemporaryFile(dir=report.parent, prefix='encode-report-', delete=False) as pending:
    pending.write(output)
    temporary = Path(pending.name)
temporary.replace(report)
for case in findings['cases']:
    streams = case.get('ffprobe', {}).get('report', {}).get('streams', [])
    stream = streams[0] if streams else {}
    print(f"{case['id']}: {case['outcome']}; codec={stream.get('codec_name', 'unknown')}; "
          f"pixels={stream.get('pix_fmt', 'unknown')}; frames={stream.get('nb_read_frames', '0')}")
print(f'Report: {report}')
print(f'Synthetic bitstreams: {artifacts}')
PY
