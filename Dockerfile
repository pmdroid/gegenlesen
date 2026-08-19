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
RUN swift build -c release --static-swift-stdlib --product GegenlesenAPI
RUN BIN="$(swift build -c release --product GegenlesenAPI --show-bin-path)" \
    && install -m 0755 "$BIN/GegenlesenAPI" /usr/local/bin/GegenlesenAPI

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    docker.io \
    git \
    libarchive13 \
    libsqlite3-0 \
    zlib1g \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /usr/local/bin/GegenlesenAPI /usr/local/bin/GegenlesenAPI
COPY --from=frontend /src/frontend/dist /app/frontend/dist
COPY rules /app/rules
COPY schemas /app/schemas
COPY docker/opencode-runner /app/docker/opencode-runner
COPY config/gegenlesen.example.json /app/config/gegenlesen.example.json
RUN mkdir -p /data
ENV GEGENLESEN_DATA_DIR=/data
ENV GEGENLESEN_BIND=127.0.0.1
EXPOSE 8080
ENTRYPOINT ["GegenlesenAPI"]
CMD ["serve"]
