# code-index: codebase-memory-mcp (stdio) behind mcp-proxy (Streamable HTTP).
# Decision record: opencode-config-v2 docs/adr/0017-code-index-spike.md.
#
# trixie, not bookworm: the release binary needs glibc 2.38 / GLIBCXX 3.4.32.
# git is a runtime dependency (file discovery and change detection use it).

FROM debian:trixie-slim AS fetch
ARG TARGETARCH
ARG CBM_VERSION=0.12.1
ARG CBM_SHA256_AMD64=8453015145f072c1b9b019cbdd02cea8cc6f18cc5e116036dd20992631c638c7
ARG CBM_SHA256_ARM64=8575f126092660b93b170bdc2e06f3ef2dd28d3cc49ad6d0895dc3e4767219cd
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*
RUN set -eu; \
    case "${TARGETARCH}" in \
      amd64) sha="${CBM_SHA256_AMD64}" ;; \
      arm64) sha="${CBM_SHA256_ARM64}" ;; \
      *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    tarball="codebase-memory-mcp-linux-${TARGETARCH}.tar.gz"; \
    curl -fsSL --retry 3 -o "/tmp/${tarball}" \
      "https://github.com/DeusData/codebase-memory-mcp/releases/download/v${CBM_VERSION}/${tarball}"; \
    echo "${sha}  /tmp/${tarball}" | sha256sum -c -; \
    mkdir /tmp/cbm; \
    tar -xzf "/tmp/${tarball}" -C /tmp/cbm; \
    install -m 0755 "$(find /tmp/cbm -type f -name codebase-memory-mcp | head -n1)" /usr/local/bin/codebase-memory-mcp; \
    /usr/local/bin/codebase-memory-mcp --version | grep -qx "codebase-memory-mcp ${CBM_VERSION}"

FROM debian:trixie-slim
ARG CBM_VERSION=0.12.1
ARG CODE_INDEX_UID=1000
ARG CODE_INDEX_GID=1000
LABEL org.opencontainers.image.title="code-index" \
      io.opencode.cbm-version="${CBM_VERSION}"

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates git python3 python3-venv tini \
 && rm -rf /var/lib/apt/lists/*

COPY requirements.txt /opt/mcp-proxy/requirements.txt
RUN python3 -m venv /opt/mcp-proxy/venv \
 && /opt/mcp-proxy/venv/bin/pip install --no-cache-dir --require-hashes --only-binary=:all: \
      -r /opt/mcp-proxy/requirements.txt \
 && /opt/mcp-proxy/venv/bin/mcp-proxy --version

COPY --from=fetch /usr/local/bin/codebase-memory-mcp /usr/local/bin/codebase-memory-mcp
COPY entrypoint.sh /usr/local/bin/code-index-entrypoint
COPY refresh.py /usr/local/lib/code-index/refresh.py
RUN chmod 0755 /usr/local/bin/code-index-entrypoint \
 && chmod 0644 /usr/local/lib/code-index/refresh.py

# Same uid/gid as the opencode service so read-only binds of host repos stay
# readable. Code is mounted read-only, so trusting every repo for git reads is safe.
RUN groupadd -o -g "${CODE_INDEX_GID}" cbm \
 && useradd -o -u "${CODE_INDEX_UID}" -g cbm -m -d /home/cbm -s /usr/sbin/nologin cbm \
 && git config --system safe.directory '*' \
 && install -d -o cbm -g cbm /var/lib/code-index /opt/code-index/work

USER cbm
# Neutral working dir: the indexer refuses to watch /, /tmp, $HOME or similar roots.
WORKDIR /opt/code-index/work
ENV CBM_CACHE_DIR=/var/lib/code-index \
    PATH=/opt/mcp-proxy/venv/bin:${PATH}
VOLUME /var/lib/code-index
EXPOSE 8080

# mcp-proxy also guards /healthz with the bearer token; the probe reads it from
# the container env (the entrypoint only unsets it in the server's own process).
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD ["python3", "-c", "import os,sys,urllib.request as u; r=u.Request('http://127.0.0.1:8080/healthz', headers={'Authorization': 'Bearer ' + os.environ.get('CODE_INDEX_TOKEN', '')}); sys.exit(0 if 200 <= u.urlopen(r, timeout=4).status < 300 else 1)"]

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/code-index-entrypoint"]
