#!/bin/bash
# Publish already-built static files to the Pages branch from this local Mac.
# The .nojekyll marker permits direct Pages deployment with Actions disabled.
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"
[[ -f site/index.html && -f site/.nojekyll ]] || { printf '%s\n' 'Missing static site or .nojekyll marker.' >&2; exit 1; }
[[ -z "$(git status --porcelain -- site)" ]] || { printf '%s\n' 'Commit the reviewed site before publishing.' >&2; exit 1; }
site_tree="$(git rev-parse HEAD:site)"
parent_commit=""
if git fetch origin refs/heads/gh-pages:refs/remotes/origin/gh-pages 2>/dev/null; then
    parent_commit="$(git rev-parse refs/remotes/origin/gh-pages)"
fi
if [[ -n "$parent_commit" ]]; then
    site_commit="$(git commit-tree "$site_tree" -p "$parent_commit" -m 'Publish Mooring static site')"
else
    site_commit="$(git commit-tree "$site_tree" -m 'Publish Mooring static site')"
fi
git push origin "$site_commit:refs/heads/gh-pages"
printf '%s\n' 'Published the prebuilt site branch. GitHub Actions stays disabled.'
