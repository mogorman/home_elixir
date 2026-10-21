#!/usr/bin/env sh
# Cut a home-elixir add-on release: commit+push, build amd64+arm64, deploy to GHCR.
#
#   scripts/release.sh [-m "commit message"] [--no-commit]
#
# The version is read from addon/config.yaml, so bump `version:` and add a
# CHANGELOG entry BEFORE running. The script refuses to push an image unless its
# architecture matches the tag, and refuses to push a manifest unless it has both
# amd64 and arm64 -- the two ways this release has silently shipped a bad image.
set -Eeuo pipefail

cd "$(dirname "$0")/.."   # repo root

# --- args ---
MSG=""; DO_COMMIT=1
while [ $# -gt 0 ]; do
  case "$1" in
    -m) MSG="$2"; shift 2 ;;
    --no-commit) DO_COMMIT=0; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

VERSION=$(sed -nE 's/^version:[[:space:]]*//p' addon/config.yaml | tr -d '[:space:]')
[ -n "$VERSION" ] || { echo "FATAL: no version: in addon/config.yaml" >&2; exit 1; }
IMAGE="ghcr.io/mogorman/home-elixir"
[ -n "$MSG" ] || MSG="Release $VERSION"
echo "==> Releasing $IMAGE:$VERSION"

# --- preflight: arm64 emulation must be on, else the arm build is silently wrong ---
ARMA=$(docker run --rm --platform linux/arm64 alpine:3.20 uname -m 2>/dev/null || true)
[ "$ARMA" = "aarch64" ] || { echo "FATAL: arm64 emulation not enabled (got '${ARMA:-none}'); see AGENTS.md one-time prereq" >&2; exit 1; }

assert_arch() { # image expected-arch
  got=$(podman image inspect "$1" --format '{{.Architecture}}' 2>/dev/null || echo missing)
  [ "$got" = "$2" ] || { echo "FATAL: $1 arch='$got' expected='$2'" >&2; exit 1; }
}

# --- regenerate the ExDoc API reference (host, dev env) ---
# Runs on the host so the prod Docker build never pulls in ex_doc. Output is
# committed below and served read-only at /static/docs. A failing build (e.g. a
# compile error) aborts the release via `set -e` — a free preflight.
echo "==> regenerating ExDoc API reference"
sh scripts/build_docs.sh

# --- git: commit + push pending changes (the release) ---
if [ "$DO_COMMIT" = 1 ]; then
  if [ -n "$(git status --porcelain)" ]; then
    git add -A
    echo "==> committing:"; git diff --cached --stat
    git commit -m "$MSG"
  else
    echo "==> tree clean, nothing to commit"
  fi
  git push origin HEAD
fi

# --- auth ---
podman login ghcr.io -u mogorman --password-stdin < ~/.ghcr-token >/dev/null

  # --- build one arch (release base + addon), verify the arch before returning ---
  # $3 = podman/OCI arch (image tag + assert: amd64|arm64); $4 = HA arch label
  # (io.hass.arch: amd64|aarch64). podman v5+ reports "arm64"; HA wants "aarch64".
  build() { # name  platform  img-arch  ha-arch
    plat="$2"
    imgarch="$3"
    haarch="$4"
    rel="localhost/home-elixir-release:$1"
    # Always pass an explicit --platform so the build never silently follows host/base arch.
    docker build --platform "$plat" --no-cache -f Dockerfile.release -t "$rel" . >/dev/null
    assert_arch "$rel" "$imgarch"
    docker build --platform "$plat" --no-cache \
      --build-arg RELEASE_IMAGE="$rel" \
      --build-arg BUILD_ARCH="$haarch" \
      --build-arg BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --build-arg BUILD_DESCRIPTION="Node-RED-style Elixir flow engine for Home Assistant" \
      --build-arg BUILD_NAME=HomeElixir --build-arg BUILD_VERSION="$VERSION" \
      -f addon/Dockerfile -t "$IMAGE:$VERSION-$imgarch" addon/ >/dev/null
    assert_arch "$IMAGE:$VERSION-$imgarch" "$imgarch"
    echo "    $imgarch built (arch verified)"
  }

  echo "==> building amd64 + arm64 (parallel)"
  build amd64 linux/amd64 amd64 amd64 & P1=$!
  build arm64 linux/arm64 arm64 aarch64 & P2=$!
  wait "$P1"; wait "$P2"

# --- push arch tags ---
echo "==> pushing arch tags"
docker push "$IMAGE:$VERSION-amd64" >/dev/null
docker push "$IMAGE:$VERSION-arm64" >/dev/null
echo "    amd64 + arm64 tags pushed"

# --- manifest: clean stale local tag-images first (they can shadow the manifest name) ---
podman rmi -f "$IMAGE:$VERSION" "$IMAGE:latest" >/dev/null 2>&1 || true
manifest() { # tag
  podman manifest rm "$IMAGE:$1" >/dev/null 2>&1 || true
  podman manifest create "$IMAGE:$1" >/dev/null
  podman manifest add "$IMAGE:$1" "$IMAGE:$VERSION-amd64" >/dev/null
  podman manifest add "$IMAGE:$1" "$IMAGE:$VERSION-arm64" >/dev/null
  arches=$(podman manifest inspect "$IMAGE:$1" | grep -oE '"architecture": *"[a-z0-9]+"' | sed -E 's/.*"([a-z0-9]+)"$/\1/' | sort -u | paste -sd,)
  [ "$arches" = "amd64,arm64" ] || { echo "FATAL: manifest $1 arches='$arches' expected 'amd64,arm64'" >&2; exit 1; }
  podman manifest push "$IMAGE:$1" "docker://$IMAGE:$1" >/dev/null
  echo "    manifest $1 pushed (arches: $arches)"
}
manifest "$VERSION"
manifest "latest"

# --- verify each arch resolves from the registry ---
for a in amd64 arm64; do
  podman pull --platform linux/$a "$IMAGE:$VERSION" >/dev/null 2>&1
  got=$(podman image inspect "$IMAGE:$VERSION" --format '{{.Architecture}}')
  [ "$got" = "$a" ] || { echo "FATAL: registry $VERSION $a variant resolved as '$got'" >&2; exit 1; }
  podman rmi -f "$IMAGE:$VERSION" >/dev/null 2>&1 || true
  echo "    verified $a -> $got"
done

echo "==> done: $IMAGE:$VERSION deployed (amd64+arm64), git pushed."
