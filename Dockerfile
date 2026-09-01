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
RUN swift build -c release --static-swift-stdlib --product gegenlesen
RUN BIN="$(swift build -c release --product GegenlesenAPI --show-bin-path)" \
    && install -m 0755 "$BIN/GegenlesenAPI" /usr/local/bin/GegenlesenAPI \
    && install -m 0755 "$BIN/gegenlesen" /usr/local/bin/gegenlesen

FROM debian:bookworm-slim
# git depends on libcurl-gnutls. Swift/Foundation links OpenSSL libcurl4.
ARG TARGETARCH
ARG GROK_VERSION=1.0.13
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl gnupg \
    && install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
    && echo "deb [signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian bookworm stable" \
       > /etc/apt/sources.list.d/docker.list \
    && apt-get update
RUN apt-get install -y --no-install-recommends \
    docker-ce-cli \
    git \
    libarchive13 \
    libcurl4 \
    libsqlite3-0 \
    libxml2 \
    nodejs \
    npm \
    tini \
    tzdata \
    zlib1g \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g @zed-industries/claude-code-acp@0.16.2 \
    && curl https://cursor.com/install -fsS | bash \
    && install -d -m 0755 /opt/cursor-agent \
    && cp -a /root/.local/share/cursor-agent/versions /opt/cursor-agent/versions \
    && AGENT_VERSION="$(ls /opt/cursor-agent/versions | head -1)" \
    && ln -sf "/opt/cursor-agent/versions/${AGENT_VERSION}/cursor-agent" /usr/local/bin/cursor-agent \
    && test -x "/opt/cursor-agent/versions/${AGENT_VERSION}/cursor-agent" \
    && set -eux; \
    case "$TARGETARCH" in \
      arm64) grok_arch=aarch64 ;; \
      amd64) grok_arch=x86_64 ;; \
      *) echo "unsupported TARGETARCH=$TARGETARCH" >&2; exit 1 ;; \
    esac; \
    curl -fsSL \
      "https://storage.googleapis.com/grok-build-public-artifacts/cli/grok-${GROK_VERSION}-linux-${grok_arch}" \
      -o /usr/local/bin/grok; \
    chmod 0755 /usr/local/bin/grok; \
    /usr/local/bin/grok --version
WORKDIR /app
COPY --from=build /usr/local/bin/GegenlesenAPI /usr/local/bin/GegenlesenAPI
COPY --from=build /usr/local/bin/gegenlesen /usr/local/bin/gegenlesen
RUN for bin in /usr/local/bin/GegenlesenAPI /usr/local/bin/gegenlesen; do \
      missing="$(ldd "$bin" | awk '/not found/ {print}')"; \
      if [ -n "$missing" ]; then \
        echo "$bin has unresolved shared libraries:" >&2; \
        echo "$missing" >&2; \
        ldd "$bin" >&2; \
        exit 1; \
      fi; \
    done
COPY --from=frontend /src/frontend/dist /app/frontend/dist
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
