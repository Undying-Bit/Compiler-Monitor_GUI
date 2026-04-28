export interface Env {
  UPDATES_BUCKET: R2Bucket;
  DATA_BUCKET: R2Bucket;
  UPDATES_PREFIX?: string;
  DATA_PREFIX?: string;
  UPDATE_TOKEN?: string;
}

type BucketRoute = "updates" | "data";

function normalizePrefix(prefix: string): string {
  return prefix.replace(/^\/+|\/+$/g, "");
}

function isAuthorized(request: Request, token?: string): boolean {
  if (!token) {
    return true;
  }
  const auth = request.headers.get("Authorization") || "";
  if (!auth.toLowerCase().startsWith("bearer ")) {
    return false;
  }
  return auth.slice(7).trim() === token;
}

function contentTypeForPath(path: string): string | null {
  const lower = path.toLowerCase();
  if (lower.endsWith(".json")) {
    return "application/json; charset=utf-8";
  }
  if (lower.endsWith(".zip")) {
    return "application/zip";
  }
  if (lower.endsWith(".sig")) {
    return "application/octet-stream";
  }
  if (lower.endsWith(".db")) {
    return "application/octet-stream";
  }
  return null;
}

function resolveObjectTarget(pathname: string, env: Env): { route: BucketRoute; objectKey: string } | null {
  const trimmed = pathname.replace(/^\/+|\/+$/g, "");
  if (!trimmed) {
    return null;
  }

  const parts = trimmed.split("/");
  const route = parts[0]?.toLowerCase();
  const remainder = parts.slice(1).join("/");

  if (route === "updates" && remainder) {
    const prefix = normalizePrefix(env.UPDATES_PREFIX || "");
    return {
      route: "updates",
      objectKey: prefix ? `${prefix}/${remainder}` : remainder,
    };
  }

  if (route === "data" && remainder) {
    const prefix = normalizePrefix(env.DATA_PREFIX || "");
    return {
      route: "data",
      objectKey: prefix ? `${prefix}/${remainder}` : remainder,
    };
  }

  // Support root DB paths for clients that use /estaciones.db or /reportes.db.
  const rootDataObject = trimmed.toLowerCase();
  if (rootDataObject === "estaciones.db" || rootDataObject === "reportes.db") {
    const prefix = normalizePrefix(env.DATA_PREFIX || "");
    return {
      route: "data",
      objectKey: prefix ? `${prefix}/${trimmed}` : trimmed,
    };
  }

  const legacyPrefix = normalizePrefix(env.UPDATES_PREFIX || "");
  return {
    route: "updates",
    objectKey: legacyPrefix ? `${legacyPrefix}/${trimmed}` : trimmed,
  };
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (request.method !== "GET" && request.method !== "HEAD") {
      return new Response("Method Not Allowed", { status: 405 });
    }

    if (!isAuthorized(request, env.UPDATE_TOKEN)) {
      return new Response("Unauthorized", { status: 401 });
    }

    const url = new URL(request.url);
    const target = resolveObjectTarget(url.pathname, env);
    if (!target) {
      return new Response("Not Found", { status: 404 });
    }

    const bucket = target.route === "data" ? env.DATA_BUCKET : env.UPDATES_BUCKET;
    const object = await bucket.get(target.objectKey);
    if (!object) {
      return new Response("Not Found", { status: 404 });
    }

    const headers = new Headers();
    object.writeHttpMetadata(headers);
    const contentType = contentTypeForPath(target.objectKey);
    if (contentType && !headers.get("content-type")) {
      headers.set("content-type", contentType);
    }
    headers.set("etag", object.httpEtag);
    headers.set("cache-control", target.objectKey.toLowerCase().endsWith(".json")
      ? "public, max-age=60"
      : "public, max-age=31536000, immutable");

    const customMetadata = (object as { customMetadata?: Record<string, string> }).customMetadata ?? {};
    if (customMetadata.sha256 && !headers.get("x-monitor-sha256")) {
      headers.set("x-monitor-sha256", customMetadata.sha256);
    }

    return new Response(request.method === "HEAD" ? null : object.body, {
      status: 200,
      headers,
    });
  },
};
