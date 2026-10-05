# Mooring website

The public landing page is [kcirtapfromspace.github.io/mooring](https://kcirtapfromspace.github.io/mooring/). Its source is in `site/`: plain HTML, CSS, and the approved Threshold assets. It has no runtime dependencies, analytics, external fonts, or JavaScript.

Preview locally with `python3 -m http.server 8000 --directory site`. Check desktop and narrow-screen layouts, keyboard navigation, and the download/source links. Commit reviewed changes, then run `./scripts/publish-site.sh` from this Mac.

The script publishes the committed `site/` tree to `gh-pages`. Pages uses that branch's root with `build_type: legacy`. Its `.nojekyll` marker tells GitHub to deploy prebuilt files directly, including when Actions is disabled. Do not add a workflow or enable Actions. [GitHub's direct deployment guidance](https://github.blog/changelog/2024-07-08-pages-legacy-worker-sunset/).

The download link opens the latest release, so it keeps working as previews advance. App signing, notarization, builds, and tests remain local.
