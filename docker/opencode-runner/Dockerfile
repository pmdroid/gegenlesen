FROM --platform=$TARGETPLATFORM debian:bookworm-slim

ARG OPENCODE_VERSION=1.1.25
ARG TARGETARCH
ARG OASDIFF_VERSION=1.11.7

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    clangd \
    curl \
    git \
    nodejs \
    npm \
    python3 \
    python3-pip \
    ripgrep \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g --omit=dev \
    typescript \
    typescript-language-server \
    pyright \
    yaml-language-server \
    vscode-langservers-extracted

RUN useradd -u 1000 -m gegenlesen

RUN set -eux; \
    case "$TARGETARCH" in \
      arm64) asset="opencode-linux-arm64.tar.gz" ;; \
      amd64) asset="opencode-linux-x64.tar.gz" ;; \
      *) echo "unsupported TARGETARCH=$TARGETARCH" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/opencode.tgz \
      "https://github.com/anomalyco/opencode/releases/download/v${OPENCODE_VERSION}/${asset}"; \
    mkdir -p /tmp/opencode; \
    tar -xzf /tmp/opencode.tgz -C /tmp/opencode; \
    if [ -f /tmp/opencode/opencode ]; then \
      install -m 0755 /tmp/opencode/opencode /usr/local/bin/opencode; \
    else \
      install -m 0755 "$(find /tmp/opencode -type f -name opencode | head -n 1)" /usr/local/bin/opencode; \
    fi; \
    rm -rf /tmp/opencode /tmp/opencode.tgz; \
    opencode --version

RUN set -eux; \
    case "$TARGETARCH" in \
      arm64) oas="linux_arm64" ;; \
      amd64) oas="linux_amd64" ;; \
      *) echo "unsupported TARGETARCH=$TARGETARCH" >&2; exit 1 ;; \
    esac; \
    if curl -fsSL -o /tmp/oasdiff.tgz \
      "https://github.com/oasdiff/oasdiff/releases/download/v${OASDIFF_VERSION}/oasdiff_${OASDIFF_VERSION}_${oas}.tar.gz"; then \
      tar -xzf /tmp/oasdiff.tgz -C /tmp; \
      if [ -f /tmp/oasdiff ]; then install -m 0755 /tmp/oasdiff /usr/local/bin/oasdiff; fi; \
      rm -rf /tmp/oasdiff /tmp/oasdiff.tgz; \
    fi

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

COPY opencode.json /home/gegenlesen/.config/opencode/opencode.json
COPY agents/ /home/gegenlesen/.config/opencode/agents/

RUN chown -R 1000:1000 /home/gegenlesen

LABEL org.gegenlesen.opencode-version="${OPENCODE_VERSION}"
LABEL org.gegenlesen.runner-version="0.1.0"

USER gegenlesen
WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
