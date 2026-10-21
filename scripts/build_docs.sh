#!/usr/bin/env sh
# Build the ExDoc API reference into priv/static/docs: generate (dev env), copy,
# and anchor each page to its own root (<base>) so it works under any ingress /
# reverse-proxy prefix. Run this (or just rely on scripts/release.sh) whenever
# lib/ changes, then commit priv/static/docs.
set -Eeuo pipefail
cd "$(dirname "$0")/.."

MIX_ENV=dev mix deps.get
MIX_ENV=dev mix docs
rm -rf priv/static/docs
cp -r doc priv/static/docs
MIX_ENV=dev mix docs.inject_base
echo "ExDoc built -> priv/static/docs (base-anchored)"
