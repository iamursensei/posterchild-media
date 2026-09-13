// supabase/functions/_shared/cors.ts
//
// Explicit origin allowlist. No wildcard "*" is ever used -- an
// unrecognized Origin receives no Access-Control-Allow-Origin header at
// all, and the browser enforces the block on its own.

const ALLOWED_ORIGINS = new Set<string>([
  // Production
  "https://posterchild-media.vercel.app",
  // Development
  "http://localhost:8080",
  "http://127.0.0.1:8080",
]);

// To support a future production custom domain, add it to
// ALLOWED_ORIGINS above only -- nothing else in this module needs to
// change.

const ALLOWED_METHODS = "POST, OPTIONS";
const ALLOWED_HEADERS = "authorization, x-client-info, apikey, content-type";

export function isOriginAllowed(origin: string | null): boolean {
  return origin !== null && ALLOWED_ORIGINS.has(origin);
}

/**
 * Headers to attach to EVERY response (success, error, and preflight)
 * from a given origin. Vary: Origin is always set, since the response
 * varies by request origin even when no permissive header is granted.
 * Access-Control-Allow-* headers are included only when the origin is on
 * the allowlist -- for a disallowed origin this returns just { Vary:
 * "Origin" }, never a permissive header of any kind.
 */
export function corsHeaders(origin: string | null): HeadersInit {
  const headers: Record<string, string> = {
    Vary: "Origin",
  };
  if (isOriginAllowed(origin)) {
    headers["Access-Control-Allow-Origin"] = origin as string;
    headers["Access-Control-Allow-Methods"] = ALLOWED_METHODS;
    headers["Access-Control-Allow-Headers"] = ALLOWED_HEADERS;
  }
  return headers;
}

/**
 * Call at the top of every function handler. Returns a 204 response for
 * an OPTIONS preflight request (with CORS headers already applied), or
 * null if the request is not a preflight and the handler should continue
 * normally.
 */
export function handlePreflight(req: Request): Response | null {
  if (req.method !== "OPTIONS") return null;
  const origin = req.headers.get("Origin");
  return new Response(null, {
    status: 204,
    headers: corsHeaders(origin),
  });
}
