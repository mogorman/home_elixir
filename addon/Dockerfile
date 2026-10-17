# The base image (built by Dockerfile.release) is a full Elixir env with the
# app compiled at /app. We run it with `mix run --no-halt` (dev-mode VM allows
# dynamic code loading for runtime dep installation).
ARG RELEASE_IMAGE=localhost/home-elixir-release:local
FROM ${RELEASE_IMAGE}

RUN apt-get update \
    && apt-get install -y --no-install-recommends nginx bash jq curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

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
