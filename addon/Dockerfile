# Consumes the Nix-free, standard-glibc HomeElixir release (built by CI from
# Dockerfile.release) and layers the runtime. For a local build, pass:
#   --build-arg RELEASE_IMAGE=home-elixir-release:local
ARG RELEASE_IMAGE=ghcr.io/mogorman/home-elixir-release:0.1.0
ARG RUNTIME_IMAGE=debian:trixie-slim
ARG ELIXIR_IMAGE=elixir:1.20.4

FROM ${RELEASE_IMAGE} AS release
FROM ${ELIXIR_IMAGE} AS elixir-tools
RUN mix local.hex --force && mix local.rebar --force

FROM ${RUNTIME_IMAGE}
RUN apt-get update \
    && apt-get install -y --no-install-recommends nginx bash jq curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# The self-contained release (standard glibc, portable).
COPY --from=release /opt/home-elixir /opt/home-elixir

# Elixir toolchain for runtime dep installation (mix deps.get/compile).
COPY --from=elixir-tools /usr/local/lib/elixir /usr/local/lib/elixir
COPY --from=elixir-tools /usr/local/bin/elixir /usr/local/bin/elixir
COPY --from=elixir-tools /usr/local/bin/mix /usr/local/bin/mix
COPY --from=elixir-tools /usr/local/bin/rebar3 /usr/local/bin/rebar3
COPY --from=elixir-tools /root/.mix /root/.mix

# bashio (Supervisor option/port discovery) + the app's nginx front.
COPY vendor/lib/bashio /usr/local/lib/bashio
RUN ln -sf /usr/local/lib/bashio/bashio /usr/local/bin/bashio
COPY rootfs/etc/nginx /etc/nginx
COPY rootfs/start.sh /usr/local/bin/home-elixir-start
RUN chmod +x /usr/local/bin/home-elixir-start && mkdir -p /etc/nginx/servers /config

HEALTHCHECK --start-period=10m \
    CMD curl --fail http://127.0.0.1:4000/favicon.ico || exit 1

ARG BUILD_ARCH
ARG BUILD_DATE
ARG BUILD_DESCRIPTION
ARG BUILD_NAME
ARG BUILD_VERSION

LABEL \
    io.hass.name="${BUILD_NAME}" \
    io.hass.description="${BUILD_DESCRIPTION}" \
    io.hass.arch="${BUILD_ARCH}" \
    io.hass.type="addon" \
    io.hass.version="${BUILD_VERSION}" \
    org.opencontainers.image.title="${BUILD_NAME}" \
    org.opencontainers.image.vendor="HomeElixir" \
    org.opencontainers.image.licenses="MIT" \
    org.opencontainers.image.url="https://github.com/mogorman/home_elixir" \
    org.opencontainers.image.source="https://github.com/mogorman/home_elixir" \
    org.opencontainers.image.version="${BUILD_VERSION}"

EXPOSE 8080 8090
ENTRYPOINT ["/usr/local/bin/home-elixir-start"]
