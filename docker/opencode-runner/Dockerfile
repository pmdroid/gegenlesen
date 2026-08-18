# Stub runner image. OpenCode, oasdiff, and agent prompts are not installed yet.
FROM debian:bookworm-slim
LABEL org.meister.runner-version="0.1.0"
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    git \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /workspace
CMD ["echo", "meister/opencode-runner stub"]
