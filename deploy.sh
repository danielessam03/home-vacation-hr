#!/bin/sh
# Publishes HR to ALL its addresses through the HV kit (hv-shared/kit/publish.sh): checks the page (JSX compiles,
# every code file present), then Cloudflare Pages home-vacation-hr (main) + hr-home-vacation (spare) — and
# hr.home-vacation.com once attached — and the GitHub Pages backup https://danielessam03.github.io/home-vacation-hr/
# Only index.html + the kit files are published (never this folder).
set -e
cd "$(dirname "$0")"
sh ../hv-shared/kit/sync.sh .
sh ../hv-shared/kit/publish.sh . "home-vacation-hr hr-home-vacation" home-vacation-hr
