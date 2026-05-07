export interface Env {
  UPDATES_BUCKET: R2Bucket;
  DATA_BUCKET: R2Bucket;
  TELEMETRY_DB: D1Database;
  UPDATES_PREFIX?: string;
  DATA_PREFIX?: string;
  UPDATE_TOKEN?: string;
  TELEMETRY_TOKEN?: string;
}

type BucketRoute = "updates" | "data";
type TelemetryEventName =
  | "launcher_started"
  | "first_run_after_install"
  | "launcher_update_check_failed"
  | "launcher_update_install_completed"
  | "launcher_update_install_failed"
  | "launcher_app_only_update_completed"
  | "launcher_app_only_update_failed"
  | "launcher_rollback_completed"
  | "launcher_rollback_failed"
  | "launcher_app_launch_failed";

type PreparedTelemetryEvent = {
  event: TelemetryEventName;
  installation_id: string;
  launcher_session_id: string;
  timestamp: string;
  launcher_version: string | null;
  channel: string | null;
  user_name: string | null;
  user_domain: string | null;
  os_description: string | null;
  os_architecture: string | null;
  payload: Record<string, unknown>;
};

const telemetryPath = "/telemetry/events";
const maxTelemetryBodyBytes = 64 * 1024;
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const allowedTelemetryEvents = new Set<TelemetryEventName>([
  "launcher_started",
  "first_run_after_install",
  "launcher_update_check_failed",
  "launcher_update_install_completed",
  "launcher_update_install_failed",
  "launcher_app_only_update_completed",
  "launcher_app_only_update_failed",
  "launcher_rollback_completed",
  "launcher_rollback_failed",
  "launcher_app_launch_failed",
]);

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
    const url = new URL(request.url);
    if (url.pathname === telemetryPath) {
      return handleTelemetryRequest(request, env);
    }

    if (request.method !== "GET" && request.method !== "HEAD") {
      return new Response("Method Not Allowed", { status: 405 });
    }

    if (!isAuthorized(request, env.UPDATE_TOKEN)) {
      return new Response("Unauthorized", { status: 401 });
    }

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

async function handleTelemetryRequest(request: Request, env: Env): Promise<Response> {
  if (request.method !== "POST") {
    return new Response("Method Not Allowed", { status: 405 });
  }

  if (!isAuthorized(request, env.TELEMETRY_TOKEN)) {
    return new Response("Unauthorized", { status: 401 });
  }

  const body = await request.arrayBuffer();
  if (body.byteLength > maxTelemetryBodyBytes) {
    return new Response("Payload Too Large", { status: 413 });
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(new TextDecoder().decode(body));
  } catch {
    return new Response("Bad Request", { status: 400 });
  }

  const preparedEvents = validateTelemetryRequest(parsed);
  if (!preparedEvents) {
    return new Response("Bad Request", { status: 400 });
  }

  const receivedAt = new Date().toISOString();
  const statements = preparedEvents.map((event) =>
    env.TELEMETRY_DB
      .prepare(
        `INSERT INTO telemetry_events (
          received_at,
          event,
          installation_id,
          launcher_session_id,
          launcher_version,
          channel,
          user_name,
          user_domain,
          os_description,
          os_architecture,
          payload_json
        ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)`,
      )
      .bind(
        receivedAt,
        event.event,
        event.installation_id,
        event.launcher_session_id,
        event.launcher_version,
        event.channel,
        event.user_name,
        event.user_domain,
        event.os_description,
        event.os_architecture,
        JSON.stringify(event.payload),
      ),
  );

  await env.TELEMETRY_DB.batch(statements);
  return new Response(null, { status: 204 });
}

function validateTelemetryRequest(payload: unknown): PreparedTelemetryEvent[] | null {
  if (!isPlainObject(payload) || !hasOnlyKeys(payload, ["events"])) {
    return null;
  }

  const events = payload.events;
  if (!Array.isArray(events) || events.length === 0) {
    return null;
  }

  const prepared: PreparedTelemetryEvent[] = [];
  for (const entry of events) {
    const validated = validateTelemetryEvent(entry);
    if (!validated) {
      return null;
    }

    prepared.push(validated);
  }

  return prepared;
}

function validateTelemetryEvent(payload: unknown): PreparedTelemetryEvent | null {
  if (!isPlainObject(payload)) {
    return null;
  }

  const launcherSessionId = getNullableString(payload, "launcher_session_id", "session_id");
  const launcherVersion = getNullableString(payload, "launcher_version", "app_version");

  if (
    !hasOnlyKeys(payload, [
      "event",
      "installation_id",
      "launcher_session_id",
      "session_id",
      "timestamp",
      "launcher_version",
      "app_version",
      "channel",
      "user_name",
      "user_domain",
      "os_description",
      "os_architecture",
      "payload",
    ])
  ) {
    return null;
  }

  if (
    typeof payload.event !== "string" ||
    !allowedTelemetryEvents.has(payload.event as TelemetryEventName) ||
    typeof payload.installation_id !== "string" ||
    !uuidPattern.test(payload.installation_id) ||
    typeof launcherSessionId !== "string" ||
    !uuidPattern.test(launcherSessionId) ||
    typeof payload.timestamp !== "string" ||
    Number.isNaN(Date.parse(payload.timestamp)) ||
    !isNullableString(launcherVersion) ||
    !isNullableString(payload.channel) ||
    !isNullableString(payload.user_name) ||
    !isNullableString(payload.user_domain) ||
    !isNullableString(payload.os_description) ||
    !isNullableString(payload.os_architecture) ||
    !isPlainObject(payload.payload)
  ) {
    return null;
  }

  return {
    event: payload.event as TelemetryEventName,
    installation_id: payload.installation_id,
    launcher_session_id: launcherSessionId,
    timestamp: payload.timestamp,
    launcher_version: launcherVersion ?? null,
    channel: payload.channel ?? null,
    user_name: payload.user_name ?? null,
    user_domain: payload.user_domain ?? null,
    os_description: payload.os_description ?? null,
    os_architecture: payload.os_architecture ?? null,
    payload: payload.payload,
  };
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function hasOnlyKeys(value: Record<string, unknown>, allowedKeys: string[]): boolean {
  const allowed = new Set(allowedKeys);
  return Object.keys(value).every((key) => allowed.has(key));
}

function isNullableString(value: unknown): value is string | null | undefined {
  return value === null || value === undefined || typeof value === "string";
}

function getNullableString(
  value: Record<string, unknown>,
  primaryKey: string,
  fallbackKey: string,
): string | null | undefined {
  const primaryValue = value[primaryKey];
  if (primaryValue !== undefined) {
    return isNullableString(primaryValue) ? primaryValue : null;
  }

  const fallbackValue = value[fallbackKey];
  return isNullableString(fallbackValue) ? fallbackValue : null;
}
