# syntax=docker/dockerfile:1

FROM node:20-bookworm-slim AS frontend
WORKDIR /src/frontend
COPY frontend/package.json frontend/package-lock.json ./
RUN npm ci
COPY frontend/ ./
RUN npm run build

FROM swift:6.2-bookworm AS build
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    git \
    libarchive-dev \
    libsqlite3-dev \
    pkg-config \
    zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY Package.swift Package.resolved ./
COPY Sources ./Sources
COPY Tests ./Tests
RUN swift build -c release --static-swift-stdlib --product GegenlesenAPI
RUN BIN="$(swift build -c release --product GegenlesenAPI --show-bin-path)" \
    && install -m 0755 "$BIN/GegenlesenAPI" /usr/local/bin/GegenlesenAPI

FROM debian:bookworm-slim
# git depends on libcurl-gnutls. Swift/Foundation links OpenSSL libcurl4.
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    docker.io \
    git \
    libarchive13 \
    libcurl4 \
    libsqlite3-0 \
    libxml2 \
    tini \
    tzdata \
    zlib1g \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /usr/local/bin/GegenlesenAPI /usr/local/bin/GegenlesenAPI
RUN missing="$(ldd /usr/local/bin/GegenlesenAPI | awk '/not found/ {print}')" \
    && if [ -n "$missing" ]; then \
      echo "GegenlesenAPI has unresolved shared libraries:" >&2; \
      echo "$missing" >&2; \
      ldd /usr/local/bin/GegenlesenAPI >&2; \
      exit 1; \
    fi
COPY --from=frontend /src/frontend/dist /app/frontend/dist
COPY --from=frontend /usr/local/bin/node /usr/local/bin/node
COPY --from=frontend /usr/local/bin/npm /usr/local/bin/npm
COPY --from=frontend /usr/local/bin/npx /usr/local/bin/npx
COPY --from=frontend /usr/local/lib/node_modules /usr/local/lib/node_modules
COPY rules /app/rules
COPY schemas /app/schemas
COPY docker/opencode-runner /app/docker/opencode-runner
COPY docker/runner-base/acp-models.mjs /app/docker/runner-base/acp-models.mjs
COPY config/gegenlesen.example.json /app/config/gegenlesen.example.json
RUN mkdir -p /data
ARG GEGENLESEN_OPENCODE_IMAGE=ghcr.io/pmdroid/gegenlesen:runner-main
ARG GEGENLESEN_CLAUDE_RUNNER_IMAGE=ghcr.io/pmdroid/gegenlesen:claude-runner-main
ARG GEGENLESEN_CODEX_RUNNER_IMAGE=ghcr.io/pmdroid/gegenlesen:codex-runner-main
ARG GEGENLESEN_CURSOR_RUNNER_IMAGE=ghcr.io/pmdroid/gegenlesen:cursor-runner-main
ARG GEGENLESEN_GROK_RUNNER_IMAGE=ghcr.io/pmdroid/gegenlesen:grok-runner-main
ARG GEGENLESEN_SCANNER_IMAGE=ghcr.io/pmdroid/gegenlesen:scanner-main
ENV GEGENLESEN_DATA_DIR=/data
ENV GEGENLESEN_BIND=127.0.0.1
ENV GEGENLESEN_OPENCODE_IMAGE=${GEGENLESEN_OPENCODE_IMAGE}
ENV GEGENLESEN_CLAUDE_RUNNER_IMAGE=${GEGENLESEN_CLAUDE_RUNNER_IMAGE}
ENV GEGENLESEN_CODEX_RUNNER_IMAGE=${GEGENLESEN_CODEX_RUNNER_IMAGE}
ENV GEGENLESEN_CURSOR_RUNNER_IMAGE=${GEGENLESEN_CURSOR_RUNNER_IMAGE}
ENV GEGENLESEN_GROK_RUNNER_IMAGE=${GEGENLESEN_GROK_RUNNER_IMAGE}
ENV GEGENLESEN_SCANNER_IMAGE=${GEGENLESEN_SCANNER_IMAGE}
EXPOSE 8080
# PID 1 must reap docker children. Foundation also fails CFSocket wakeup
# pairs when GegenlesenAPI is PID 1 ("Could not create wakeup socket pair").
ENTRYPOINT ["tini", "--", "GegenlesenAPI"]
CMD ["serve"]
