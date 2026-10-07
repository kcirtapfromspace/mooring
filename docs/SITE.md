# Mooring website

The public landing page is [kcirtapfromspace.github.io/mooring](https://kcirtapfromspace.github.io/mooring/). Its source is in `site/`: plain HTML, CSS, and the approved Threshold assets. It has no runtime dependencies, analytics, external fonts, or JavaScript.

The demo (`site/assets/demo.mp4` and `demo-poster.jpg`) is an edited screen recording, the one approved exception to the captured-screens rule. Before replacing it, trim browser history and bookmarks, blur file lists and other personal details, and keep pairing codes masked. Encode H.264 MP4 at 1440×900 with `+faststart` and no audio track, and keep it under about 5 MB.

Preview locally with `python3 -m http.server 8000 --directory site`. Check desktop and narrow-screen layouts, keyboard navigation, and the download/source links. When CSS changes, update the stylesheet URL’s `v` query to the first 12 characters of its SHA-256 hash so returning visitors load the current styles. Commit reviewed changes, then run `./scripts/publish-site.sh` from this Mac.

The script publishes the committed `site/` tree to `gh-pages`. Pages uses that branch's root with `build_type: legacy`. Its `.nojekyll` marker tells GitHub to deploy prebuilt files directly, including when Actions is disabled. Do not add a workflow or enable Actions. [GitHub's direct deployment guidance](https://github.blog/changelog/2024-07-08-pages-legacy-worker-sunset/).

The download link opens the latest release, so it keeps working as previews advance. App signing, notarization, builds, and tests remain local.
