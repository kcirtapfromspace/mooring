# Reviewed dependency license evidence

Some Cargo packages omit their repository's complete license files from their
published archive. These supplements preserve upstream files at the exact
commit recorded in that archive's `.cargo_vcs_info.json`.

For packages whose repository also omits full license text, the supplement
retains the upstream Cargo manifest containing its SPDX declaration and authors,
plus the matching canonical license text from SPDX license-list-data v3.27.0.
Canonical SPDX text is a template; it is not an upstream copyright notice.
The objc2 repository's own licensing explanation is preserved separately.
Copyright holders are never inferred from a neighboring crate.

`manifest.json` records package/version, upstream commit, original source URLs,
and SHA-256 hashes. The collector verifies these against Cargo metadata and
the installed package's VCS revision before including any supplement. It also
retains all notices shipped in the package, including component licenses.
Collection and app builds are offline with respect to this evidence.

When updating a dependency, review its new source and license declaration,
replace the relevant evidence and hashes, run
`python3 scripts/test-license-supplements.py`, then regenerate
`docs/THIRD-PARTY-NOTICES.txt`. A version change never silently reuses evidence.
