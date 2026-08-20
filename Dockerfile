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
COPY rules /app/rules
COPY schemas /app/schemas
COPY docker/opencode-runner /app/docker/opencode-runner
COPY config/gegenlesen.example.json /app/config/gegenlesen.example.json
RUN mkdir -p /data
ARG GEGENLESEN_OPENCODE_IMAGE=ghcr.io/pmdroid/gegenlesen:runner-main
ENV GEGENLESEN_DATA_DIR=/data
ENV GEGENLESEN_BIND=127.0.0.1
ENV GEGENLESEN_OPENCODE_IMAGE=${GEGENLESEN_OPENCODE_IMAGE}
EXPOSE 8080
ENTRYPOINT ["GegenlesenAPI"]
CMD ["serve"]
