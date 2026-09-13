// supabase/functions/availability/index.ts
//
// Public, browser-callable. Reads no client-specific data and returns no
// resource identity, reservation rows, or internal database detail --
// only a boolean outcome for the requested service/package/add-ons/window.
//
// This endpoint owns request validation (package/add-on existence,
// active/bookable state, applicability, shape of the input). Resource
// availability computation itself lives in _shared/availabilityResolver.ts.

import { corsHeaders, handlePreflight, isOriginAllowed } from "../_shared/cors.ts";
import { withTransaction } from "../_shared/db.ts";
import { jsonErrorResponse, mapError } from "../_shared/errors.ts";
import { lazyExpireStaleHolds } from "../_shared/lazyExpire.ts";
import { resolveAvailability } from "../_shared/availabilityResolver.ts";
import { parseStrictIsoTimestamp } from "../_shared/strictDatetime.ts";
import { fingerprintClientIdentity } from "../_shared/clientIdentity.ts";
import { checkRateLimit, RATE_LIMIT_SECRET } from "../_shared/rateLimit.ts";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MAX_REQUEST_DURATION_MS = 24 * 60 * 60 * 1000; // sanity bound only, not a business rule
const MAX_BODY_BYTES = 4096; // same conservative cap as hold -- this payload is a handful of UUIDs + timestamps
const ALLOWED_BODY_FIELDS = new Set([
  "service_package_id",
  "service_addon_ids",
  "requested_start_datetime",
  "requested_end_datetime",
]);

function badRequest(message: string, headers: HeadersInit): Response {
  return new Response(
    JSON.stringify({ error: "invalid_request", message }),
    { status: 422, headers: { "Content-Type": "application/json", ...headers } },
  );
}

function rateLimited(retryAfterSeconds: number, headers: HeadersInit): Response {
  return new Response(
    JSON.stringify({
      error: "rate_limited",
      message: "Too many requests. Please try again shortly.",
    }),
    {
      status: 429,
      headers: {
        "Content-Type": "application/json",
        "Retry-After": String(retryAfterSeconds),
        ...headers,
      },
    },
  );
}

function serverConfigurationError(headers: HeadersInit): Response {
  return new Response(
    JSON.stringify({
      error: "server_configuration_error",
      message: "Unable to process request.",
    }),
    { status: 500, headers: { "Content-Type": "application/json", ...headers } },
  );
}

Deno.serve(async (req: Request) => {
  const origin = req.headers.get("Origin");

  const preflight = handlePreflight(req);
  if (preflight) return preflight;

  const headers = corsHeaders(origin);

  if (!isOriginAllowed(origin)) {
    // corsHeaders() above already omitted any permissive header, so the
    // browser will block this regardless -- respond cleanly rather than
    // leaking any detail about why.
    return new Response(JSON.stringify({ error: "forbidden" }), {
      status: 403,
      headers: { "Content-Type": "application/json", ...headers },
    });
  }

  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "method_not_allowed" }), {
      status: 405,
      headers: { "Content-Type": "application/json", ...headers },
    });
  }

  // Rate limit before any body is read, so a malformed or oversized body
  // still consumes a unit once a request has passed the origin/method
  // gate -- see _shared/rateLimit.ts for why this must commit on its own
  // rather than inside the availability DB transaction below (there
  // isn't one that writes here, but the same independent-commit
  // discipline is kept for consistency with hold).
  let rateLimitResult: Awaited<ReturnType<typeof checkRateLimit>>;
  try {
    const clientFingerprint = await fingerprintClientIdentity(req, RATE_LIMIT_SECRET);
    rateLimitResult = await checkRateLimit("availability", clientFingerprint);
  } catch {
    // Unexpected failure in the rate-limit path itself (e.g. a database
    // connectivity problem) -- fails closed rather than falling through
    // to body validation/business logic. The caught error is never
    // logged itself, since it could carry a raw SQL/connection detail;
    // only a fixed, generic label is recorded.
    console.error("[availability] rate_limit_infrastructure_failure");
    return serverConfigurationError(headers);
  }
  if (!rateLimitResult.allowed) {
    return rateLimited(rateLimitResult.retryAfterSeconds, headers);
  }

  let rawBody: ArrayBuffer;
  try {
    rawBody = await req.arrayBuffer();
  } catch {
    return badRequest("Request body could not be read.", headers);
  }
  if (rawBody.byteLength > MAX_BODY_BYTES) {
    return badRequest("Request body exceeds the maximum allowed size.", headers);
  }

  let body: unknown;
  try {
    body = JSON.parse(new TextDecoder().decode(rawBody));
  } catch {
    return badRequest("Request body must be valid JSON.", headers);
  }

  if (typeof body !== "object" || body === null || Array.isArray(body)) {
    return badRequest("Request body must be a JSON object.", headers);
  }
  const record = body as Record<string, unknown>;

  for (const key of Object.keys(record)) {
    if (!ALLOWED_BODY_FIELDS.has(key)) {
      return badRequest(`Unrecognized field: ${key}`, headers);
    }
  }

  const servicePackageId = record.service_package_id;
  if (typeof servicePackageId !== "string" || !UUID_RE.test(servicePackageId)) {
    return badRequest("service_package_id must be a valid UUID.", headers);
  }

  const serviceAddonIdsRaw = record.service_addon_ids;
  const serviceAddonIds = serviceAddonIdsRaw === undefined ? [] : serviceAddonIdsRaw;
  if (
    !Array.isArray(serviceAddonIds) ||
    !serviceAddonIds.every((v) => typeof v === "string" && UUID_RE.test(v))
  ) {
    return badRequest("service_addon_ids must be an array of UUIDs.", headers);
  }
  if (new Set(serviceAddonIds).size !== serviceAddonIds.length) {
    return badRequest("service_addon_ids must not contain duplicates.", headers);
  }

  const requestedStart = record.requested_start_datetime;
  const requestedEnd = record.requested_end_datetime;
  if (typeof requestedStart !== "string") {
    return badRequest(
      "requested_start_datetime must be ISO-8601 with an explicit timezone offset (Z or +HH:MM).",
      headers,
    );
  }
  if (typeof requestedEnd !== "string") {
    return badRequest(
      "requested_end_datetime must be ISO-8601 with an explicit timezone offset (Z or +HH:MM).",
      headers,
    );
  }
  const parsedStart = parseStrictIsoTimestamp(requestedStart);
  if (!parsedStart.ok) {
    return badRequest(
      "requested_start_datetime must be ISO-8601 with an explicit timezone offset (Z or +HH:MM).",
      headers,
    );
  }
  const parsedEnd = parseStrictIsoTimestamp(requestedEnd);
  if (!parsedEnd.ok) {
    return badRequest(
      "requested_end_datetime must be ISO-8601 with an explicit timezone offset (Z or +HH:MM).",
      headers,
    );
  }

  const startMs = parsedStart.ms;
  const endMs = parsedEnd.ms;
  if (endMs <= startMs) {
    return badRequest("requested_end_datetime must be after requested_start_datetime.", headers);
  }
  if (endMs - startMs > MAX_REQUEST_DURATION_MS) {
    return badRequest("Requested duration exceeds the maximum allowed.", headers);
  }

  try {
    const outcome = await withTransaction(async (tx) => {
      await lazyExpireStaleHolds(tx);

      const pkgRows = await tx<{ id: string; service_id: string }[]>`
        select id, service_id
        from service_packages
        where id = ${servicePackageId}
          and is_active = true
          and is_bookable = true
      `;
      if (pkgRows.length === 0) {
        return { kind: "invalid_package" as const };
      }
      const pkg = pkgRows[0];

      if (serviceAddonIds.length > 0) {
        const addonRows = await tx<{ id: string; applicable_service_id: string | null }[]>`
          select id, applicable_service_id
          from service_addons
          where id in ${tx(serviceAddonIds)}
            and is_active = true
            and is_bookable = true
        `;
        if (addonRows.length !== serviceAddonIds.length) {
          return { kind: "invalid_addon" as const };
        }
        const hasInapplicable = addonRows.some(
          (a) => a.applicable_service_id !== null && a.applicable_service_id !== pkg.service_id,
        );
        if (hasInapplicable) {
          return { kind: "invalid_addon" as const };
        }
      }

      const result = await resolveAvailability(tx, {
        servicePackageId,
        serviceAddonIds: serviceAddonIds as string[],
        requestedStart,
        requestedEnd,
      });
      return { kind: "resolved" as const, result };
    });

    if (outcome.kind === "invalid_package") {
      return badRequest("service_package_id does not reference an active, bookable package.", headers);
    }
    if (outcome.kind === "invalid_addon") {
      return badRequest(
        "One or more service_addon_ids are invalid, inactive, or not applicable to the selected package.",
        headers,
      );
    }

    const available = outcome.result.status === "available";
    if (!available && outcome.result.status === "unavailable") {
      // internalReason is logged server-side only -- e.g.
      // "no_resource_requirements_configured" vs "insufficient_resources"
      // -- and is never included in the response body below.
      console.warn(
        `[availability] unavailable reason=${outcome.result.internalReason} package=${servicePackageId}`,
      );
    }

    const responseBody = available
      ? {
          available: true,
          requested_start_datetime: requestedStart,
          requested_end_datetime: requestedEnd,
        }
      : {
          available: false,
          requested_start_datetime: requestedStart,
          requested_end_datetime: requestedEnd,
          reason: "unavailable",
        };

    return new Response(JSON.stringify(responseBody), {
      status: 200,
      headers: { "Content-Type": "application/json", ...headers },
    });
  } catch (err) {
    const mapped = mapError(err, "availability");
    return jsonErrorResponse(mapped, headers);
  }
});
