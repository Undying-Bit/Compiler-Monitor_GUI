export interface Env {
  UPDATES_BUCKET: R2Bucket;
  BASE_PREFIX?: string;
  UPDATE_TOKEN?: string;
}

function normalizePrefix(prefix: string): string {
  return prefix.replace(/^\/+|\/+$/g, "");
}

function isAuthorized(request: Request, token?: string): boolean {
  if (!token) {
    return true;
  }
  const auth = request.headers.get("Authorization") || "";
  if (auth.toLowerCase().startsWith("bearer ")) {
    return auth.slice(7).trim() === token;
  }
  const url = new URL(request.url);
  return url.searchParams.get("token") === token;
}

function contentTypeForPath(path: string): string | null {
  const lower = path.toLowerCase();
  if (lower.endsWith(".json")) {
    return "application/json; charset=utf-8";
  }
  if (lower.endsWith(".zip")) {
    return "application/zip";
  }
  return null;
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
    const path = url.pathname.replace(/^\/+/, "");
    if (!path) {
      return new Response("Not Found", { status: 404 });
    }

    const prefix = normalizePrefix(env.BASE_PREFIX || "");
    if (prefix && path !== prefix && !path.startsWith(`${prefix}/`)) {
      return new Response("Not Found", { status: 404 });
    }

    const object = await env.UPDATES_BUCKET.get(path);
    if (!object) {
      return new Response("Not Found", { status: 404 });
    }

    const headers = new Headers();
    object.writeHttpMetadata(headers);
    const contentType = contentTypeForPath(path);
    if (contentType && !headers.get("content-type")) {
      headers.set("content-type", contentType);
    }
    headers.set("etag", object.httpEtag);
    headers.set("cache-control", path.toLowerCase().endsWith(".json")
      ? "public, max-age=60"
      : "public, max-age=31536000, immutable");

    return new Response(request.method === "HEAD" ? null : object.body, {
      status: 200,
      headers,
    });
  },
};
