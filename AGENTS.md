# HomeElixir — build & deploy

How to cut a new add-on release. Every release ships **both** `amd64` and `arm64`
as a single multi-arch manifest, so Home Assistant pulls the right arch automatically.

- `docker` here is the **podman** CLI shim (v5.8). `docker buildx` is **not**
  available — multi-arch is done with `docker build --platform` + `podman manifest`.
- The add-on image does **not** carry `config.yaml`. HA reads `name`/`version`/
  `changelog`/`arch` from this repo's `addon/config.yaml` (the add-on store), so
  always edit + commit + push it.

## One-time prereq: arm64 emulation (re-run after each reboot)

Arm builds run under QEMU. It must be enabled on the host (needs root):
```sh
sudo mount -t binfmt_misc none /proc/sys/fs/binfmt_misc
sudo docker run --privileged multiarch/qemu-user-static --reset -p yes
```
Sanity check: `docker run --rm --platform linux/arm64 alpine:3.20 uname -m` → `aarch64`.
Arm builds are slow under QEMU (the first one is the longest; later builds reuse
cached release layers).

## Release steps (replace `<ver>` with the new version, e.g. 0.1.62)

1. **Bump + changelog** — in `addon/config.yaml`: set `version: <ver>` and add a
   `<ver>` entry at the top of `changelog`. (`arch` is already `[amd64, aarch64]`.)

2. **Auth**
   ```sh
   podman login ghcr.io -u mogorman --password-stdin < ~/.ghcr-token
   ```

3. **Build both arches** (amd64 is fast; arm64 is the slow one — run them in parallel)
   ```sh
   # amd64
   docker build -f Dockerfile.release -t localhost/home-elixir-release:amd64 .
   docker build --no-cache \
     --build-arg RELEASE_IMAGE=localhost/home-elixir-release:amd64 \
     --build-arg BUILD_ARCH=amd64 \
     --build-arg BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
     --build-arg BUILD_DESCRIPTION="Node-RED-style Elixir flow engine for Home Assistant" \
     --build-arg BUILD_NAME=HomeElixir --build-arg BUILD_VERSION=<ver> \
     -f addon/Dockerfile -t ghcr.io/mogorman/home-elixir:<ver>-amd64 addon/

   # arm64
   docker build --platform linux/arm64 -f Dockerfile.release -t localhost/home-elixir-release:arm64 .
   docker build --no-cache --platform linux/arm64 \
     --build-arg RELEASE_IMAGE=localhost/home-elixir-release:arm64 \
     --build-arg BUILD_ARCH=aarch64 \
     --build-arg BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
     --build-arg BUILD_DESCRIPTION="Node-RED-style Elixir flow engine for Home Assistant" \
     --build-arg BUILD_NAME=HomeElixir --build-arg BUILD_VERSION=<ver> \
     -f addon/Dockerfile -t ghcr.io/mogorman/home-elixir:<ver>-arm64 addon/
   ```
   `--no-cache` on the add-on build is required (stale `io.hass.version` label otherwise).
   Note: the image is built as OCI, which drops the `HEALTHCHECK` — this matches every
   prior release and the add-on runs fine in HA without it. Don't "fix" it.

4. **Push the arch tags**
   ```sh
   docker push ghcr.io/mogorman/home-elixir:<ver>-amd64
   docker push ghcr.io/mogorman/home-elixir:<ver>-arm64
   ```

5. **Assemble + push the multi-arch manifest** (for `<ver>` and `latest`)
   ```sh
   for tag in <ver> latest; do
     podman manifest create   ghcr.io/mogorman/home-elixir:$tag
     podman manifest add      ghcr.io/mogorman/home-elixir:$tag ghcr.io/mogorman/home-elixir:<ver>-amd64
     podman manifest add      ghcr.io/mogorman/home-elixir:$tag ghcr.io/mogorman/home-elixir:<ver>-arm64
     podman manifest push     ghcr.io/mogorman/home-elixir:$tag docker://ghcr.io/mogorman/home-elixir:$tag
   done
   ```

6. **Verify** the manifest resolves each arch
   ```sh
   podman pull --platform linux/arm64 ghcr.io/mogorman/home-elixir:<ver>
   podman image inspect ghcr.io/mogorman/home-elixir:<ver> --format '{{.Architecture}}'   # arm64
   ```

7. **Commit + push** (config.yaml + any source) to `main` so the store shows the new version.

## Tests
```sh
mix test
```
