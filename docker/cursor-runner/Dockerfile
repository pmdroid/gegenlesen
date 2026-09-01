ARG RUNNER_BASE=gegenlesen/runner-base:0.1.0
FROM ${RUNNER_BASE}

USER root

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl \
    && curl https://cursor.com/install -fsS | bash \
    && install -d -m 0755 /opt/cursor-agent \
    && cp -a /root/.local/share/cursor-agent/versions /opt/cursor-agent/versions \
    && AGENT_VERSION="$(ls /opt/cursor-agent/versions | head -1)" \
    && ln -sf "/opt/cursor-agent/versions/${AGENT_VERSION}/cursor-agent" /usr/local/bin/agent \
    && test -x "/opt/cursor-agent/versions/${AGENT_VERSION}/cursor-agent" \
    && chown -R 1000:1000 /opt/cursor-agent \
    && rm -rf /var/lib/apt/lists/*

LABEL org.gegenlesen.engine="cursor-agent"
LABEL org.gegenlesen.runner-version="0.1.0"

USER gegenlesen
