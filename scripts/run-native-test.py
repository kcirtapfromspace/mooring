#!/usr/bin/env python3
"""Compile one declared target and run it with a bounded deadline."""
from pathlib import Path
import subprocess
import sys
root = Path(__file__).resolve().parents[1]
name = sys.argv[1]
binary = subprocess.check_output([sys.executable, str(root / 'scripts/native-targets.py'), 'compile', name], cwd=root, text=True).strip()
subprocess.run([binary, *sys.argv[2:]], cwd=root, check=True, timeout=120)
