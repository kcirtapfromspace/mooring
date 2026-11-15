#!/usr/bin/env python3
"""The local native build graph: one checked manifest for app and test inputs."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = json.loads((ROOT / "build/native-targets.json").read_text())
os.environ["DEVELOPER_DIR"] = MANIFEST["toolchain"]["developerDir"]


def sources(name):
    target = MANIFEST["targets"][name]
    values = [source for group in target.get("groups", []) for source in MANIFEST["groups"][group]]
    values += target.get("sources", [])
    return list(dict.fromkeys(values))


def check_graph():
    owned = [source for group in MANIFEST["groups"].values() for source in group]
    actual = {str(path.relative_to(ROOT)) for path in (ROOT / "app").glob("*.swift")}
    if len(owned) != len(set(owned)) or set(owned) != actual:
        raise ValueError("Every app Swift source must have exactly one owning build group: " + str(actual ^ set(owned)))
    for name in MANIFEST["targets"]:
        for source in sources(name):
            if not (ROOT / source).is_file():
                raise ValueError(f"Missing input for {name}: {source}")
    workflows = set(sources("workflows"))
    required = set(sources("app")) - set(MANIFEST["groups"]["shell"])
    if not required <= workflows:
        raise ValueError("Application workflow tests must compile every non-entry-point app source")


def check_toolchain():
    expected = MANIFEST["toolchain"]
    commands = [("rust", ["rustc", "--version"], rf'^rustc {re.escape(expected["rust"])}(?:\s|$)'),
                ("swift", ["swiftc", "--version"], rf'Apple Swift version {re.escape(expected["swift"])}(?:\s|$)'),
                ("xcodeBuild", ["xcodebuild", "-version"], rf'Build version {re.escape(expected["xcodeBuild"])}(?:\s|$)')]
    for label, command, pattern in commands:
        result = subprocess.run(command, check=True, capture_output=True, text=True)
        if not re.search(pattern, result.stdout, re.MULTILINE):
            raise ValueError(f"Expected {label} {expected[label]}; update and validate build/native-targets.json for a toolchain change")
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-version"], text=True).strip()
    if sdk != expected["sdk"]:
        raise ValueError(f'Expected macOS SDK {expected["sdk"]}, found {sdk}')
    architecture = subprocess.check_output(["uname", "-m"], text=True).strip()
    if architecture != MANIFEST["platform"]["architecture"]:
        raise ValueError("Native builds require the local Apple silicon Mac")


def compile_test(name):
    if name == "app":
        raise ValueError("Use build-app.sh for bundle assembly and signing")
    output = ROOT / f"target/mooring-{name}-tests"
    command = ["swiftc", "-O", "-swift-version", "5", "-warnings-as-errors", "-parse-as-library",
               "-sdk", subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip(),
               "-target", MANIFEST["platform"]["swiftTarget"]]
    for framework in MANIFEST["frameworks"]:
        command += ["-framework", framework]
    if name in {"input", "vnc-viewer", "media", "session", "stream", "workflows"}:
        header = "app/Mooring-Bridging.h" if name == "workflows" else "crates/mooring-session/include/mooring_session.h"
        command += ["-import-objc-header", header,
                    "-L", f'target/{MANIFEST["platform"]["rustTarget"]}/release', "-lmooring_session"]
        if name == "workflows":
            command += ["target/NativeVirtualDisplay.o"]
    command += sources(name) + ["-o", str(output)]
    subprocess.run(command, cwd=ROOT, check=True)
    print(output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["check", "toolchain", "sources", "compile", "setting"])
    parser.add_argument("name", nargs="?")
    args = parser.parse_args()
    if args.command == "setting":
        print(MANIFEST["platform"].get(args.name, MANIFEST["toolchain"].get(args.name)))
    elif args.command == "toolchain":
        check_toolchain()
    else:
        check_graph()
        if args.command == "sources":
            print("\n".join(sources(args.name)))
        elif args.command == "compile":
            compile_test(args.name)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(f"Native build: {error}", file=sys.stderr)
        sys.exit(1)
