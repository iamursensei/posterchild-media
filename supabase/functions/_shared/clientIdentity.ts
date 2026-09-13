// supabase/functions/_shared/clientIdentity.ts
//
// Extracts a normalized client identity from an explicit, ordered list of
// candidate proxy headers and produces a deterministic, opaque
// HMAC-SHA-256 fingerprint from it -- never the raw IP/header value
// itself, which never leaves extractRawClientIdentity() and is never
// logged or persisted anywhere.
//
// TRUST BOUNDARY -- read before relying on this in production: these
// headers are only as trustworthy as whatever actually sits in front of
// this function at request time, and a caller can send any of them
// directly unless something upstream strips/overwrites client-supplied
// values first. Locally, nothing adds any of these headers, so every
// local request resolves to the UNKNOWN_CLIENT_SENTINEL fallback --
// confirmed by direct testing, not assumed. Whether Supabase's hosted
// gateway adds one of these headers reliably (and strips a
// caller-forged one first) is a PRE-DEPLOY verification item; nothing
// here claims that has been proven.

const CANDIDATE_HEADERS = ["x-forwarded-for", "x-real-ip", "cf-connecting-ip"];

const UNKNOWN_CLIENT_SENTINEL = "unknown-client";

/**
 * Returns the raw (unhashed) normalized client identity string. Never
 * exported -- every external caller goes through
 * fingerprintClientIdentity() instead, which returns only the HMAC
 * digest.
 */
function extractRawClientIdentity(req: Request): string {
  for (const headerName of CANDIDATE_HEADERS) {
    const raw = req.headers.get(headerName);
    if (!raw) continue;
    // x-forwarded-for may be a comma-separated proxy chain
    // (client, proxy1, proxy2, ...) -- the first entry is the original
    // client per that header's own convention, applied consistently here
    // regardless of which candidate header actually matched. An entry
    // that is empty/whitespace-only after trimming is treated as absent
    // rather than used as-is.
    const first = raw.split(",")[0].trim();
    if (first.length > 0) return first;
  }
  return UNKNOWN_CLIENT_SENTINEL;
}

async function hmacSha256Hex(secret: string, message: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(message),
  );
  return Array.from(new Uint8Array(signature))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

/**
 * Returns a deterministic, opaque fingerprint for the requesting client.
 * The raw IP/header value is used only as HMAC input and is never
 * returned, logged, or otherwise exposed. Every unidentified client (no
 * recognized header present) maps to the SAME hashed sentinel, so
 * unidentified traffic still shares one rate-limit bucket rather than
 * bypassing limiting entirely.
 */
export async function fingerprintClientIdentity(
  req: Request,
  hmacSecret: string,
): Promise<string> {
  const raw = extractRawClientIdentity(req);
  return await hmacSha256Hex(hmacSecret, raw);
}
