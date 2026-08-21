FROM --platform=$TARGETPLATFORM debian:bookworm-slim

ARG TARGETARCH
ARG GITLEAKS_VERSION=8.30.1
ARG OSV_SCANNER_VERSION=2.5.1

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    python3 \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -u 1000 -m gegenlesen

RUN set -eux; \
    case "$TARGETARCH" in \
      arm64) gleaks="gitleaks_${GITLEAKS_VERSION}_linux_arm64.tar.gz" ;; \
      amd64) gleaks="gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz" ;; \
      *) echo "unsupported TARGETARCH=$TARGETARCH" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/gitleaks.tgz \
      "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/${gleaks}"; \
    tar -xzf /tmp/gitleaks.tgz -C /tmp; \
    install -m 0755 /tmp/gitleaks /usr/local/bin/gitleaks; \
    rm -rf /tmp/gitleaks /tmp/gitleaks.tgz; \
    gitleaks version

RUN set -eux; \
    case "$TARGETARCH" in \
      arm64) osv="osv-scanner_linux_arm64" ;; \
      amd64) osv="osv-scanner_linux_amd64" ;; \
      *) echo "unsupported TARGETARCH=$TARGETARCH" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/osv-scanner \
      "https://github.com/google/osv-scanner/releases/download/v${OSV_SCANNER_VERSION}/${osv}"; \
    install -m 0755 /tmp/osv-scanner /usr/local/bin/osv-scanner; \
    rm -f /tmp/osv-scanner; \
    osv-scanner --version

RUN mkdir -p /usr/local/lib/gegenlesen /checks
COPY scan.py /usr/local/lib/gegenlesen/scan.py
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh /usr/local/lib/gegenlesen/scan.py \
    && chown -R 1000:1000 /home/gegenlesen /checks

LABEL org.gegenlesen.scanner-version="0.1.0"
LABEL org.gegenlesen.gitleaks-version="${GITLEAKS_VERSION}"
LABEL org.gegenlesen.osv-scanner-version="${OSV_SCANNER_VERSION}"

USER gegenlesen
WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
