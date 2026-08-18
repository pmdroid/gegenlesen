# Stub. PR 6 installs anomalyco/opencode, oasdiff, and baked agent prompts.
# build-runner.sh selects the platform:
#   Apple Silicon host → --platform linux/arm64
#   otherwise          → --platform linux/amd64
FROM debian:bookworm-slim
LABEL org.meister.runner-version="0.1.0"
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    git \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /workspace
CMD ["echo", "meister/opencode-runner stub — OpenCode lands in PR 6"]
