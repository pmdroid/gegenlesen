FROM --platform=$TARGETPLATFORM debian:bookworm-slim

ARG TARGETARCH
ARG OASDIFF_VERSION=1.11.7
ARG RUNNER_VERSION=0.1.0

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

COPY acp-runner.mjs lib/ tests/ /opt/gegenlesen/acp-runner/
RUN chmod 0755 /opt/gegenlesen/acp-runner/acp-runner.mjs \
    && ln -sf /opt/gegenlesen/acp-runner/acp-runner.mjs /usr/local/bin/acp-runner \
    && node /opt/gegenlesen/acp-runner/tests/validate.test.mjs \
    && node /opt/gegenlesen/acp-runner/tests/transcript.test.mjs \
    && node /opt/gegenlesen/acp-runner/tests/acp-contract.test.mjs

RUN chown -R 1000:1000 /home/gegenlesen

LABEL org.gegenlesen.runner-base-version="${RUNNER_VERSION}"

USER gegenlesen
WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
