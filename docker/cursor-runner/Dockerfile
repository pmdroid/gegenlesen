ARG RUNNER_BASE=gegenlesen/runner-base:0.1.0
FROM ${RUNNER_BASE}

USER root

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl \
    && curl https://cursor.com/install -fsS | bash \
    && install -m 0755 /root/.local/bin/agent /usr/local/bin/agent \
    && agent --version \
    && rm -rf /var/lib/apt/lists/*

LABEL org.gegenlesen.engine="cursor-agent"
LABEL org.gegenlesen.runner-version="0.1.0"

USER gegenlesen
