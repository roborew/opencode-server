# Sysbox sibling sandbox: Ubuntu + systemd + Docker Engine (Nestybox reference).
# Run with: docker run --runtime=sysbox-runc ...
# Built as OPENCODE_SANDBOX_IMAGE (default opencode-sandbox:local).
FROM nestybox/ubuntu-noble-systemd-docker:latest

USER root
ENV DEBIAN_FRONTEND=noninteractive

# Compose plugin + common tools for repo test entrypoints.
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    jq \
    && rm -rf /var/lib/apt/lists/*

# Ensure Docker Compose v2 plugin is present (base image usually has dockerd+cli).
RUN if ! docker compose version >/dev/null 2>&1; then \
      apt-get update \
      && apt-get install -y --no-install-recommends docker-compose-plugin \
      && rm -rf /var/lib/apt/lists/*; \
    fi

# Default systemd init (Sysbox); nested dockerd starts via systemd units in base image.
CMD ["/sbin/init"]
