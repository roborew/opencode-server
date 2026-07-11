# OpenCode server image: clones agents/skills config from GitHub at build time.
# Runtime secrets via Infisical (deployed) or compose .env (local).
FROM ubuntu:24.04

ARG CONFIG_REPO=https://github.com/roborew/opencode.git
ARG CONFIG_REF=main
ARG INFISICAL_CLI_VERSION=0.43.84

ENV DEBIAN_FRONTEND=noninteractive
ENV PATH="/root/.opencode/bin:/root/.local/bin:${PATH}"
ENV INFISICAL_DISABLE_UPDATE_CHECK=true

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    git \
    gnupg \
    python3 \
    python3-pip \
    ripgrep \
    socat \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# Node.js 22 (claude-context MCP requires Node >=20, <24)
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# GitHub CLI
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

# Infisical CLI (same release pattern as fidget-web, deb on Ubuntu)
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

# OpenCode CLI
RUN curl -fsSL https://opencode.ai/install | bash

# Agents, skills, opencode.json from GitHub (read-only at runtime)
RUN git clone --depth 1 --branch "${CONFIG_REF}" "${CONFIG_REPO}" /root/.config/opencode \
    && cd /root/.config/opencode && npm ci

# Deployment-owned overrides (not from config repo)
COPY overrides/ /root/overrides/
COPY docker/plugins/ /root/overrides/plugins/
COPY docker/entrypoint.sh /usr/local/bin/opencode-entrypoint.sh
COPY docker/merge-config.py /usr/local/bin/merge-config.py
RUN chmod +x /usr/local/bin/opencode-entrypoint.sh /usr/local/bin/merge-config.py

EXPOSE 4097 19876

ENTRYPOINT ["/usr/local/bin/opencode-entrypoint.sh"]
CMD ["opencode", "serve", "--hostname", "0.0.0.0", "--port", "4097"]
