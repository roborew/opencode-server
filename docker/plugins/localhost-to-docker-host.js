/**
 * Rewrites loopback URLs (localhost / 127.0.0.1 / [::1]) to the Docker host
 * gateway before tools like webfetch or bash curl run inside the container.
 *
 * Env:
 *   DOCKER_HOST_INTERNAL — target host (default: host.docker.internal)
 *   LOCALHOST_REWRITE    — set to 0 or false to disable
 */

const LOOPBACK_HOSTS = new Set(["localhost", "127.0.0.1", "::1"]);
const URL_FIELD_NAMES = new Set(["url", "uri", "href"]);
const LOOPBACK_URL_RE =
  /https?:\/\/(?:localhost|127\.0\.0\.1|\[::1\])(?::\d+)?[^\s"'`<>]*/gi;

function isRewriteEnabled() {
  const flag = (process.env.LOCALHOST_REWRITE ?? "1").toLowerCase();
  return flag !== "0" && flag !== "false" && flag !== "no" && flag !== "off";
}

function targetHost() {
  return (process.env.DOCKER_HOST_INTERNAL || "host.docker.internal").trim();
}

function normalizeHost(hostname) {
  return hostname.toLowerCase().replace(/^\[|\]$/g, "");
}

function isLoopbackHost(hostname) {
  return LOOPBACK_HOSTS.has(normalizeHost(hostname));
}

function rewriteLoopbackUrl(urlString, host) {
  try {
    const url = new URL(urlString);
    if (!isLoopbackHost(url.hostname)) {
      return urlString;
    }
    url.hostname = host;
    return url.toString();
  } catch {
    return urlString;
  }
}

function rewriteUrlsInText(text, host) {
  if (typeof text !== "string" || text.length === 0) {
    return text;
  }
  return text.replace(LOOPBACK_URL_RE, (match) => rewriteLoopbackUrl(match, host));
}

function rewriteArgs(args, host, toolName) {
  if (!args || typeof args !== "object") {
    return;
  }

  for (const [key, value] of Object.entries(args)) {
    if (typeof value !== "string") {
      continue;
    }

    if (URL_FIELD_NAMES.has(key)) {
      args[key] = rewriteLoopbackUrl(value, host);
      continue;
    }

    if (toolName === "bash" && key === "command") {
      args[key] = rewriteUrlsInText(value, host);
      continue;
    }

    if (/https?:\/\//i.test(value)) {
      args[key] = rewriteUrlsInText(value, host);
    }
  }
}

export const LocalhostToDockerHost = async () => {
  if (!isRewriteEnabled()) {
    return {};
  }

  const host = targetHost();

  return {
    "tool.execute.before": async (input, output) => {
      if (!output?.args) {
        return;
      }
      rewriteArgs(output.args, host, input.tool);
    },
  };
};
