ARG RUNNER_BASE=gegenlesen/runner-base:0.1.0
FROM ${RUNNER_BASE}

ARG OPENCODE_VERSION=1.1.25
ARG TARGETARCH

USER root

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

COPY opencode.json /home/gegenlesen/.config/opencode/opencode.json
COPY agents/ /home/gegenlesen/.config/opencode/agents/

RUN chown -R 1000:1000 /home/gegenlesen

LABEL org.gegenlesen.engine="opencode"
LABEL org.gegenlesen.opencode-version="${OPENCODE_VERSION}"
LABEL org.gegenlesen.runner-version="0.1.0"

USER gegenlesen
