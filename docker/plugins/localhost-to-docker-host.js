/**
 * Rewrites loopback URLs (localhost / 127.0.0.1 / [::1]) to the Docker host
 * gateway before tools like webfetch or bash/shell curl run inside the container.
 *
 * OpenCode v2 plugin API: default-export a definition with id + setup(ctx);
 * hooks are registered on the domain that owns the operation
 * (ctx.tool.hook("execute.before", ...)) and the callback receives one
 * mutable event with .tool (tool name) and .input (the tool args object).
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

  // v2 renamed the bash tool to shell; accept both.
  const isShell =
    toolName === "bash" || toolName === "shell" || toolName === "terminal";

  for (const [key, value] of Object.entries(args)) {
    if (typeof value !== "string") {
      continue;
    }

    if (URL_FIELD_NAMES.has(key)) {
      args[key] = rewriteLoopbackUrl(value, host);
      continue;
    }

    if (isShell && key === "command") {
      args[key] = rewriteUrlsInText(value, host);
      continue;
    }

    if (/https?:\/\//i.test(value)) {
      args[key] = rewriteUrlsInText(value, host);
    }
  }
}

async function definePlugin(definition) {
  // Prefer Plugin.define from @opencode/plugin when resolvable; the plain
  // {id, setup} object satisfies the v2 plugin loader either way.
  try {
    const mod = await import("@opencode/plugin");
    if (mod && mod.Plugin && typeof mod.Plugin.define === "function") {
      return mod.Plugin.define(definition);
    }
  } catch { }
  return definition;
}

export default await definePlugin({
  id: "localhost-to-docker-host",
  async setup(ctx) {
    if (!isRewriteEnabled()) {
      return;
    }
    const host = targetHost();

    await ctx.tool.hook("execute.before", (event) => {
      const args = event?.input;
      if (!args || typeof args !== "object") {
        return;
      }
      rewriteArgs(args, host, event.tool);
    });
  },
});
