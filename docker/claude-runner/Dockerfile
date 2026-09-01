ARG RUNNER_BASE=gegenlesen/runner-base:0.1.0
FROM ${RUNNER_BASE}

ARG CLAUDE_CODE_ACP_VERSION=0.16.2
ARG CLAUDE_CODE_VERSION=2.1.257

USER root

RUN npm install -g --omit=dev \
      "@zed-industries/claude-code-acp@${CLAUDE_CODE_ACP_VERSION}" \
      "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
    && command -v claude-code-acp \
    && command -v claude

LABEL org.gegenlesen.engine="claude"
LABEL org.gegenlesen.claude-code-acp-version="${CLAUDE_CODE_ACP_VERSION}"
LABEL org.gegenlesen.claude-code-version="${CLAUDE_CODE_VERSION}"
LABEL org.gegenlesen.runner-version="0.1.0"

USER gegenlesen
