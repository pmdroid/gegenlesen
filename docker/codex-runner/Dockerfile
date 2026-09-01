ARG RUNNER_BASE=gegenlesen/runner-base:0.1.0
FROM ${RUNNER_BASE}

ARG CODEX_ACP_VERSION=1.7.0

USER root

RUN npm install -g --omit=dev "@agentclientprotocol/codex-acp@${CODEX_ACP_VERSION}" \
    && command -v codex-acp

LABEL org.gegenlesen.engine="codex"
LABEL org.gegenlesen.codex-acp-version="${CODEX_ACP_VERSION}"
LABEL org.gegenlesen.runner-version="0.1.0"

USER gegenlesen
