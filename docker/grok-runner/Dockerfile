ARG RUNNER_BASE=gegenlesen/runner-base:0.1.0
FROM ${RUNNER_BASE}

ARG GROK_VERSION=1.0.13
ARG TARGETARCH

USER root

RUN set -eux; \
    case "$TARGETARCH" in \
      arm64) arch=aarch64 ;; \
      amd64) arch=x86_64 ;; \
      *) echo "unsupported TARGETARCH=$TARGETARCH" >&2; exit 1 ;; \
    esac; \
    curl -fsSL \
      "https://storage.googleapis.com/grok-build-public-artifacts/cli/grok-${GROK_VERSION}-linux-${arch}" \
      -o /usr/local/bin/agent; \
    chmod 0755 /usr/local/bin/agent; \
    ln -sf agent /usr/local/bin/grok; \
    install -d -m 0755 -o 1000 -g 1000 /home/gegenlesen/.grok; \
    agent --version

LABEL org.gegenlesen.engine="grok"
LABEL org.gegenlesen.grok-version="${GROK_VERSION}"
LABEL org.gegenlesen.runner-version="0.1.0"

USER gegenlesen
