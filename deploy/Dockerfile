# Control plane image. Build context is the repository root:
#     docker build -f deploy/Dockerfile .
# docker-compose.yml does that for you.

ARG SWIFT_VERSION=6.2

# --- web client (D): web/dist, or a placeholder until web/ exists ---------------------------
FROM node:22-bookworm-slim AS web
RUN --mount=type=bind,source=.,target=/src \
    set -eu; mkdir -p /out; \
    if [ -f /src/web/package.json ]; then \
        cp -r /src/web /tmp/web && cd /tmp/web && rm -rf node_modules dist \
        && (npm ci || npm install) && npm run build && cp -r dist/. /out/; \
    else \
        printf '<!doctype html><title>maccheri</title><p>Web client is not built yet.</p>\n' > /out/index.html; \
    fi

# --- server -----------------------------------------------------------------------------------
FROM swift:${SWIFT_VERSION}-noble AS build
WORKDIR /src
# Resolve dependencies first so source edits don't refetch them.
COPY protocol/Package.swift protocol/
COPY controlplane/Package.swift controlplane/Package.resolved controlplane/
RUN mkdir -p protocol/Sources/MaccheriProtocol protocol/Sources/SimStreamProtocol \
    && cd controlplane && swift package resolve
COPY protocol protocol
COPY controlplane controlplane
RUN cd controlplane \
    && swift build -c release --static-swift-stdlib \
    && mkdir /out && cp "$(swift build -c release --show-bin-path)/ControlPlane" /out/controlplane

# --- runtime ----------------------------------------------------------------------------------
FROM ubuntu:noble
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates tzdata libcurl4 libxml2 \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --uid 10001 --home /app maccheri \
    && mkdir -p /data && chown maccheri /data
WORKDIR /app
COPY --from=build /out/controlplane /app/controlplane
COPY --from=web /out /app/public
USER maccheri
ENV PUBLIC_DIR=/app/public DATABASE_PATH=/data/maccheri.sqlite
VOLUME /data
EXPOSE 8080
ENTRYPOINT ["/app/controlplane"]
CMD ["serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "8080"]
