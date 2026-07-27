# OpenCode server image: clones agents/skills config from GitHub at build time.
# Runtime secrets via Infisical (deployed) or compose .env (local).
FROM ubuntu:24.04

ARG CONFIG_REPO=https://github.com/roborew/opencode-config.git
ARG CONFIG_REF=main
ARG INFISICAL_CLI_VERSION=0.43.84
# mikefarah/yq v4 — PRD frontmatter, registry/label sync, legacy slices fanout
ARG YQ_VERSION=v4.53.2
# Build-time uid/gid for COPY --chown and a stable `opencode` passwd entry.
# Runtime identity comes from OPENCODE_UID/GID via the entrypoint drop (may
# differ on macOS, e.g. 501:20).
ARG OPENCODE_UID=1000
ARG OPENCODE_GID=1000

ENV DEBIAN_FRONTEND=noninteractive
ENV HOME=/home/opencode
ENV PATH="/home/opencode/.opencode/bin:/home/opencode/.local/bin:${PATH}"
ENV INFISICAL_DISABLE_UPDATE_CHECK=true

# Dedicated `opencode` user/group for COPY --chown. --non-unique / -o lets
# useradd/groupadd succeed when the requested uid/gid collides with the base
# image (Ubuntu 24.04 ships `ubuntu` at 1000:1000). Runtime drops to the host
# uid/gid in the entrypoint after chowning volumes.
RUN if ! getent group opencode >/dev/null ; then \
      groupadd -o -g "${OPENCODE_GID}" opencode || groupadd opencode ; \
    fi ; \
    if ! getent passwd opencode >/dev/null ; then \
      useradd -o -u "${OPENCODE_UID}" -g opencode -M -s /bin/bash opencode \
        || useradd -g opencode -M -s /bin/bash opencode ; \
    fi ; \
    mkdir -p /home/opencode && chown opencode:opencode /home/opencode

# Base + PRD/fanout CLI deps: python3, git, jq (bash/sed/grep/coreutils/curl from Ubuntu)
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    git \
    gnupg \
    jq \
    python3 \
    python3-pip \
    ripgrep \
    socat \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# PyYAML — only non-stdlib Python dep for bin/project/spec helpers
RUN pip3 install --no-cache-dir --break-system-packages 'PyYAML>=6.0'

# yq (mikefarah v4) — not the apt/snap Python wrapper
RUN ARCH="$(dpkg --print-architecture)" \
    && case "$ARCH" in \
      amd64) YQ_ARCH=amd64 ;; \
      arm64) YQ_ARCH=arm64 ;; \
      *) echo "unsupported dpkg arch for yq: $ARCH" >&2; exit 1 ;; \
    esac \
    && curl -fsSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${YQ_ARCH}" \
      -o /usr/local/bin/yq \
    && chmod +x /usr/local/bin/yq \
    && yq --version

# Node.js 22 (claude-context MCP requires Node >=20, <24)
# Install from official nodejs.org binaries (includes npm) to avoid NodeSource 403s.
RUN ARCH="$(dpkg --print-architecture)" \
    && case "$ARCH" in \
      amd64) NODE_ARCH=x64 ;; \
      arm64) NODE_ARCH=arm64 ;; \
      *) echo "unsupported dpkg arch for Node.js: $ARCH" >&2; exit 1 ;; \
    esac \
    && NODE_FILENAME="$(curl -fsSL https://nodejs.org/dist/latest-v22.x/SHASUMS256.txt | grep "linux-${NODE_ARCH}.tar.xz" | awk "NR==1 {print \$2}")" \
    && test -n "$NODE_FILENAME" \
    && curl -fsSL "https://nodejs.org/dist/latest-v22.x/${NODE_FILENAME}" -o /tmp/node.tar.xz \
    && tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1 --no-same-owner \
    && rm -f /tmp/node.tar.xz \
    && node --version \
    && npm --version

# GitHub CLI (apt stable; need >= 2.94 when using GH_PROJECT boards)
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# uv (dash-api MCP)
RUN curl -LsSf https://astral.sh/uv/install.sh | sh

# Infisical CLI (deb on Ubuntu)
RUN ARCH="$(dpkg --print-architecture)" \
    && case "$ARCH" in \
      amd64) INFISICAL_ARCH=amd64 ;; \
      arm64) INFISICAL_ARCH=arm64 ;; \
      *) echo "unsupported dpkg arch for Infisical CLI: $ARCH" >&2; exit 1 ;; \
    esac \
    && curl -fsSL "https://github.com/Infisical/cli/releases/download/v${INFISICAL_CLI_VERSION}/infisical_${INFISICAL_CLI_VERSION}_linux_${INFISICAL_ARCH}.deb" \
      -o /tmp/infisical.deb \
    && apt-get update \
    && apt-get install -y /tmp/infisical.deb \
    && rm -f /tmp/infisical.deb \
    && rm -rf /var/lib/apt/lists/*

# claude-context MCP (preinstall — npx at runtime races on native tree-sitter deps)
RUN npm install -g @zilliz/claude-context-mcp@latest

# CodeRabbit CLI (agent code review)
# install.sh prints SUCCESS then can exit 2 under dash (`| sh`) or when updating
# shell rc files in Docker. PATH already includes /home/opencode/.local/bin.
RUN curl -fsSL https://cli.coderabbit.ai/install.sh | bash; \
    test -x /home/opencode/.local/bin/coderabbit

# Docker CLI only (no dockerd). Used when docker-compose.sandbox.yml mounts the
# host socket so agents can create Sysbox sibling sandboxes. Without the socket
# mount (Mac / OPENCODE_SANDBOX_MODE=off), `sandbox probe` reports unavailable.
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
    && chmod a+r /etc/apt/keyrings/docker.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu noble stable" \
      > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

# OpenCode CLI (installed to /home/opencode/.opencode/bin via curl installer)
RUN curl -fsSL https://opencode.ai/install | bash

# Agents, skills, opencode.json from GitHub (read-only at runtime)
RUN git clone --depth 1 --branch "${CONFIG_REF}" "${CONFIG_REPO}" /home/opencode/.config/opencode \
    && cd /home/opencode/.config/opencode && npm ci \
    && chown -R opencode:opencode /home/opencode

# Deployment-owned overrides (not from config repo)
COPY --chown=opencode:opencode overrides/ /home/opencode/overrides/
COPY --chown=opencode:opencode docker/plugins/ /home/opencode/overrides/plugins/
COPY docker/entrypoint.sh /usr/local/bin/opencode-entrypoint.sh
COPY docker/configure-git-identity.sh /usr/local/bin/configure-git-identity.sh
COPY docker/merge-config.py /usr/local/bin/merge-config.py
COPY docker/rewrite-worktree-gitdirs.py /usr/local/bin/rewrite-worktree-gitdirs.py
COPY docker/worktree-delete-guard.py /usr/local/bin/worktree-delete-guard.py
COPY docker/opencode-serve-guarded.sh /usr/local/bin/opencode-serve-guarded.sh
COPY --chown=opencode:opencode scripts/sandbox/sandbox /usr/local/bin/sandbox
RUN chmod +x /usr/local/bin/opencode-entrypoint.sh \
    /usr/local/bin/configure-git-identity.sh \
    /usr/local/bin/merge-config.py \
    /usr/local/bin/rewrite-worktree-gitdirs.py /usr/local/bin/worktree-delete-guard.py \
    /usr/local/bin/opencode-serve-guarded.sh \
    /usr/local/bin/sandbox

# Runtime data dirs are NOT baked into the image — the entrypoint (as root)
# chowns them to OPENCODE_UID:GID then drops privileges before serve.

EXPOSE 4097 19876

# Starts as root (no Dockerfile USER / compose user:). Entrypoint chowns
# volumes then runuser-drops to OPENCODE_UID:OPENCODE_GID (host user).
ENTRYPOINT ["/usr/local/bin/opencode-entrypoint.sh"]
CMD ["opencode", "serve", "--hostname", "0.0.0.0", "--port", "4097"]
