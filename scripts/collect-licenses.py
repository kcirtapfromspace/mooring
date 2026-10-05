#!/usr/bin/env python3
"""Collect original Rust dependency notices for the Apple-silicon distribution.

Uses Cargo's locked target graph, including build/proc-macro dependencies.
Fails closed when a package has no license text, an unsupported expression, or
no fully covered SPDX license branch. Does not download substitute texts.
"""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
TARGET = "aarch64-apple-darwin"
NOTICE_NAME = re.compile(r"^(?:licen[cs]e|copying|copyright|notice|unlicense)(?:[._-].*)?$", re.I)
SPDX_TOKEN = re.compile(r"[A-Za-z0-9][A-Za-z0-9.+-]*|[()/]")

# Coverage checks require distinguishing text, not just an SPDX identifier in a
# short header. Every discovered notice is still included verbatim, including
# nested component notices (notably ring/BoringSSL/once_cell/fiat).
LICENSE_TEXT = {
    "MIT": lambda text: "permission is hereby granted, free of charge" in text
        and "the software is provided" in text,
    "Apache-2.0": lambda text: "apache license" in text and "version 2.0" in text
        and "terms and conditions for use, reproduction" in text,
    "BSD-3-Clause": lambda text: "redistribution and use in source and binary forms" in text
        and "neither the name" in text and "this software is provided" in text,
    "BSD-2-Clause": lambda text: "redistribution and use in source and binary forms" in text
        and "redistributions in binary form" in text and "this software is provided" in text,
    "BSD-1-Clause": lambda text: "redistribution and use in source and binary forms" in text
        and "redistributions of source code" in text and "this software is provided" in text,
    "ISC": lambda text: "permission to use, copy, modify, and/or distribute" in text
        and "for any purpose with or without fee" in text and "the software is provided" in text,
    "Unicode-3.0": lambda text: "unicode license v3" in text
        and "permission is hereby granted" in text and "the data files and software are provided" in text,
    "Unlicense": lambda text: "free and unencumbered software released into the public domain" in text
        and "the software is provided" in text,
    "LLVM-exception": lambda text: "llvm exception" in text and "apache" in text
        and "license" in text,
}


class NoticeError(Exception):
    pass


def license_ids(expression):
    if not expression:
        return set()
    tokens = SPDX_TOKEN.findall(expression)
    if "".join(tokens) != re.sub(r"\s+", "", expression):
        raise NoticeError(f"Unsupported license expression: {expression}")
    identifiers = set(tokens) - {"AND", "OR", "WITH", "(", ")", "/"}
    unknown = identifiers - LICENSE_TEXT.keys()
    if unknown:
        raise NoticeError("Unrecognized license identifiers: " + ", ".join(sorted(unknown)))
    if not identifiers:
        raise NoticeError("License expression has no license identifier")
    return identifiers


def license_branches(expression):
    """Return allowed license sets, respecting SPDX AND/OR/WITH parentheses."""
    license_ids(expression)
    tokens, index = SPDX_TOKEN.findall(expression), 0

    def atom():
        nonlocal index
        if index >= len(tokens):
            raise NoticeError("Incomplete license expression")
        if tokens[index] == "(":
            index += 1
            result = alternatives()
            if index >= len(tokens) or tokens[index] != ")":
                raise NoticeError("Unbalanced license expression")
            index += 1
        else:
            token = tokens[index]
            if token not in LICENSE_TEXT:
                raise NoticeError("Invalid license expression")
            result = [{token}]
            index += 1
        if index < len(tokens) and tokens[index] == "WITH":
            index += 1
            if index >= len(tokens) or tokens[index] not in LICENSE_TEXT:
                raise NoticeError("Unsupported license exception")
            result = [branch | {tokens[index]} for branch in result]
            index += 1
        return result

    def conjunction():
        nonlocal index
        result = atom()
        while index < len(tokens) and tokens[index] == "AND":
            index += 1
            right = atom()
            result = [left | other for left in result for other in right]
            if len(result) > 32:
                raise NoticeError("License expression exceeds branch limit")
        return result

    def alternatives():
        nonlocal index
        result = conjunction()
        while index < len(tokens) and tokens[index] in ("OR", "/"):
            index += 1
            result += conjunction()
        return result

    result = alternatives()
    if index != len(tokens):
        raise NoticeError("Invalid license expression suffix")
    return result


def read_notices(package):
    directory = Path(package["manifest_path"]).resolve().parent
    declared = package.get("license_file")
    paths = set()
    for path in directory.rglob("*"):
        if not path.is_file():
            continue
        relative = path.relative_to(directory)
        in_license_directory = any(part.lower() in ("licenses", "licences") for part in relative.parts[:-1])
        if NOTICE_NAME.fullmatch(path.name) or in_license_directory or path.name.upper() in ("AUTHORS", "AUTHORS.TXT"):
            if path.suffix.lower() not in (".rs", ".c", ".h", ".py", ".js", ".json", ".toml"):
                paths.add(path)
    if declared:
        declared_path = Path(declared)
        if not declared_path.is_absolute():
            declared_path = directory / declared_path
        if not declared_path.is_file():
            raise NoticeError("Declared license_file is missing")
        paths.add(declared_path)
    if not paths:
        raise NoticeError("No original license/notice files found")
    notices = []
    for path in sorted(paths, key=lambda item: str(item.relative_to(directory))):
        if not path.resolve().is_relative_to(directory):
            raise NoticeError("A license file points outside its package")
        if path.stat().st_size > 2 * 1024 * 1024:
            raise NoticeError("A license file exceeds the 2 MiB collection limit")
        try:
            content = path.read_text(encoding="utf-8")
        except UnicodeError as error:
            raise NoticeError("An original license file is not UTF-8") from error
        if not content.strip():
            raise NoticeError("An original license file is empty")
        notices.append((path.relative_to(directory).as_posix(), content))
    expression = package.get("license")
    if not expression and not declared:
        raise NoticeError("Package declares neither license nor license_file")
    full_texts = [re.sub(r"\s+", " ", re.sub(r"(?m)^\s*(?://|\*) ?", "", content)).lower()
                  for _, content in notices if len(content.strip()) >= 200]
    if not full_texts:
        raise NoticeError("Only short notices found; full license text is required")
    branches = license_branches(expression) if expression else [set()]
    covered = [branch for branch in branches if all(any(LICENSE_TEXT[identifier](text) for text in full_texts)
                                                   for identifier in branch)]
    if not covered:
        raise NoticeError(f"No complete original text for an allowed license branch: {expression}")
    selected = min(covered, key=lambda branch: ("MIT" not in branch, len(branch), sorted(branch)))
    return notices, " AND ".join(sorted(selected)) or "Declared license_file"


def reachable_packages(metadata):
    nodes = {node["id"]: node for node in metadata["resolve"]["nodes"]}
    members = set(metadata["workspace_members"])
    pending, visited = list(members), set()
    while pending:
        identity = pending.pop()
        if identity in visited:
            continue
        visited.add(identity)
        pending.extend(dependency["pkg"] for dependency in nodes[identity]["deps"])
    return sorted((package for package in metadata["packages"] if package["id"] in visited - members),
                  key=lambda package: (package["name"], package["version"], package.get("source") or ""))


def render(metadata, lock_digest):
    packages = reachable_packages(metadata)
    sections = [
        "Mooring — third-party Rust dependency notices\n",
        f"Target: {TARGET}\nCargo.lock SHA-256: {lock_digest}\n",
        "Generated by scripts/collect-licenses.py using cargo metadata --locked.\n"
        "Includes all reachable target dependencies plus build/proc-macro dependencies.\n"
        "Original license and notice texts follow; their terms remain authoritative.\n"
        "Some listed build tools may not be present in the final binary.\n",
        f"External packages: {len(packages)}\n",
    ]
    for package in packages:
        label = f"{package['name']} {package['version']}"
        try:
            notices, selected = read_notices(package)
        except (NoticeError, OSError, ValueError) as error:
            # Never expose registry/cache filesystem paths in generated output.
            raise NoticeError(f"{label}: {error if isinstance(error, NoticeError) else 'Unable to read original notice files'}") from error
        source = package.get("source") or "local dependency"
        repository = package.get("repository") or "not specified"
        if not source.startswith(("registry+https://", "git+https://")):
            source = "local or non-HTTPS dependency source"
        if not repository.startswith("https://"):
            repository = "not specified as an HTTPS URL"
        sections.extend([
            "\n" + "=" * 78 + "\n" + label + "\n",
            f"Declared license: {package.get('license') or 'See declared license_file'}\n",
            f"Covered license branch: {selected}\n",
            f"Source: {source}\nRepository: {repository}\n",
        ])
        for relative, content in notices:
            sections.append(f"\n--- Original file: {relative} ---\n\n")
            sections.append(content)
            if not content.endswith("\n"):
                sections.append("\n")
    return "".join(sections)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "docs/THIRD-PARTY-NOTICES.txt")
    parser.add_argument("--check", action="store_true", help="Fail if the generated notices are missing or stale")
    options = parser.parse_args()
    metadata = subprocess.run(["cargo", "metadata", "--locked", "--format-version", "1", "--filter-platform", TARGET],
                              cwd=ROOT, check=True, capture_output=True, text=True)
    digest = hashlib.sha256((ROOT / "Cargo.lock").read_bytes()).hexdigest()
    content = render(json.loads(metadata.stdout), digest)
    if options.check:
        if not options.output.is_file() or options.output.read_text(encoding="utf-8") != content:
            raise NoticeError("Third-party notices are missing or stale; run scripts/collect-licenses.py")
        print("Third-party notices verified against the locked Apple-silicon dependency graph.")
    else:
        options.output.parent.mkdir(parents=True, exist_ok=True)
        temporary = options.output.with_suffix(options.output.suffix + ".tmp")
        temporary.write_text(content, encoding="utf-8")
        temporary.replace(options.output)
        print(f"Collected original notices for {len(reachable_packages(json.loads(metadata.stdout)))} dependency packages.")


if __name__ == "__main__":
    try:
        main()
    except (NoticeError, subprocess.CalledProcessError, json.JSONDecodeError) as error:
        print(f"License collection failed: {error}", file=sys.stderr)
        sys.exit(1)
