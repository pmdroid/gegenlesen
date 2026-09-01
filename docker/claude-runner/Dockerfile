ARG RUNNER_BASE=gegenlesen/runner-base:0.1.0
FROM ${RUNNER_BASE}

ARG CLAUDE_ACP_VERSION=0.72.0
ARG CLAUDE_CODE_VERSION=2.1.257

USER root

RUN npm install -g --omit=dev \
      "@agentclientprotocol/claude-agent-acp@${CLAUDE_ACP_VERSION}" \
      "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
    && command -v claude-agent-acp \
    && command -v claude \
    && ln -sf "$(command -v claude-agent-acp)" /usr/local/bin/claude-code-acp

LABEL org.gegenlesen.engine="claude"
LABEL org.gegenlesen.claude-acp-version="${CLAUDE_ACP_VERSION}"
LABEL org.gegenlesen.claude-code-version="${CLAUDE_CODE_VERSION}"
LABEL org.gegenlesen.runner-version="0.1.0"

USER gegenlesen
