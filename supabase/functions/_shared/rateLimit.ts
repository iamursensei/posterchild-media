// supabase/functions/_shared/rateLimit.ts
//
// Durable, database-backed rate limiting shared by every public Edge
// Function. Deliberately NOT an instance-local Map/counter: Edge
// Function instances cold-start independently, scale horizontally, and
// share no process memory, so only a store both sides can see -- the
// same Postgres database the functions already use -- can provide a
// real global limit.
//
// Each policy bucket is incremented with a single atomic
// INSERT ... ON CONFLICT ... DO UPDATE statement issued on the
// module-scoped `sql` client OUTSIDE any withTransaction() call, so it
// commits immediately and independently of whatever business
// transaction the caller runs afterward. This is deliberate: if the
// increment happened inside the hold-creation transaction, a rejected or
// failed hold would roll the increment back along with everything else,
// letting an abusive caller retry a failing request indefinitely without
// ever being counted. An over-limit request still increments its
// buckets and that increment is never reversed.

import { sql } from "./db.ts";

const RATE_LIMIT_HMAC_SECRET = Deno.env.get("RATE_LIMIT_HMAC_SECRET");

if (!RATE_LIMIT_HMAC_SECRET) {
  // Fails fast at module load (cold start), before any request is
  // served -- the same pattern _shared/db.ts already uses for
  // SUPABASE_DB_URL. Never logs the value itself, only that it is
  // absent.
  throw new Error(
    "Server configuration error: RATE_LIMIT_HMAC_SECRET is not set. " +
      "Configure it as a Supabase Edge Function secret before this " +
      "function can serve requests.",
  );
}

export const RATE_LIMIT_SECRET: string = RATE_LIMIT_HMAC_SECRET;

// Opaque, constant, never derived from any client-supplied value --
// distinct in shape from any real HMAC-SHA-256 digest (64 hex chars),
// so it can never collide with a real client fingerprint. Used for every
// global-scope bucket instead of a per-client identifier.
const GLOBAL_FINGERPRINT = "global";

export type RateLimitEndpoint = "availability" | "hold";

interface RateLimitPolicy {
  scope: string;
  windowSeconds: number;
  limit: number;
  isGlobal: boolean;
}

// Infrastructure safety defaults, not business/pricing rules. Centralized
// here so no handler ever hard-codes a threshold of its own.
const AVAILABILITY_POLICIES: RateLimitPolicy[] = [
  { scope: "availability:client:60", windowSeconds: 60, limit: 60, isGlobal: false },
  { scope: "availability:client:900", windowSeconds: 900, limit: 300, isGlobal: false },
  { scope: "availability:global:60", windowSeconds: 60, limit: 600, isGlobal: true },
  { scope: "availability:global:900", windowSeconds: 900, limit: 3000, isGlobal: true },
];

const HOLD_POLICIES: RateLimitPolicy[] = [
  { scope: "hold:client:60", windowSeconds: 60, limit: 10, isGlobal: false },
  { scope: "hold:client:900", windowSeconds: 900, limit: 30, isGlobal: false },
  { scope: "hold:global:60", windowSeconds: 60, limit: 100, isGlobal: true },
  { scope: "hold:global:900", windowSeconds: 900, limit: 300, isGlobal: true },
];

export type RateLimitResult =
  | { allowed: true }
  | { allowed: false; retryAfterSeconds: number };

/**
 * Atomically increments the fixed-time bucket for one policy and returns
 * its resulting count for the CURRENT window, creating the bucket row on
 * first use. bucket_start is computed in Postgres from Postgres's own
 * clock (never the Edge Function's), so it's authoritative and
 * consistent across every concurrent caller regardless of instance
 * clock drift.
 */
async function incrementBucket(
  policy: RateLimitPolicy,
  fingerprint: string,
): Promise<{ requestCount: number; bucketStart: Date }> {
  const rows = await sql<{ request_count: number; bucket_start: Date }[]>`
    insert into public.edge_rate_limit_buckets
      (scope, fingerprint, bucket_start, window_seconds, request_count)
    values (
      ${policy.scope},
      ${fingerprint},
      to_timestamp(floor(extract(epoch from now()) / ${policy.windowSeconds}) * ${policy.windowSeconds}),
      ${policy.windowSeconds},
      1
    )
    on conflict (scope, fingerprint, bucket_start)
    do update set
      request_count = edge_rate_limit_buckets.request_count + 1,
      updated_at = now()
    returning request_count, bucket_start
  `;
  return { requestCount: rows[0].request_count, bucketStart: rows[0].bucket_start };
}

const CLEANUP_PROBABILITY = 0.01;
const CLEANUP_RETENTION_HOURS = 48;
const CLEANUP_BATCH_LIMIT = 500;

/**
 * Best-effort, bounded deletion of buckets old enough that no live
 * window could still reference them (the longest configured window here
 * is 900s = 15min, so 48h retention is generous). Never awaited by the
 * caller and never allowed to affect the rate-limit decision that has
 * already completed by the time this runs -- a cleanup failure must
 * never disable rate limiting itself. LIMIT + the bucket_start index
 * keep this bounded rather than a full-table scan, and it only runs
 * probabilistically so it is never on the critical path of most
 * requests.
 */
function cleanupOldBucketsBestEffort(): void {
  sql`
    delete from public.edge_rate_limit_buckets
    where id in (
      select id from public.edge_rate_limit_buckets
      where bucket_start < now() - make_interval(hours => ${CLEANUP_RETENTION_HOURS})
      order by bucket_start asc
      limit ${CLEANUP_BATCH_LIMIT}
    )
  `.catch(() => {
    console.warn("[rateLimit] lazy bucket cleanup failed (non-fatal)");
  });
}

/**
 * Checks and increments every policy bucket for `endpoint` on behalf of
 * `clientFingerprint` (already HMAC-hashed by the caller -- this module
 * never sees a raw IP). Every bucket is incremented regardless of the
 * final allow/deny outcome, and that increment is never rolled back.
 * When multiple buckets are simultaneously over limit, the returned
 * Retry-After reflects the LONGEST remaining violated window -- the
 * binding constraint -- not the soonest one to reset.
 */
export async function checkRateLimit(
  endpoint: RateLimitEndpoint,
  clientFingerprint: string,
): Promise<RateLimitResult> {
  const policies = endpoint === "availability" ? AVAILABILITY_POLICIES : HOLD_POLICIES;
  const nowMs = Date.now();

  const results = await Promise.all(
    policies.map(async (policy) => {
      const fingerprint = policy.isGlobal ? GLOBAL_FINGERPRINT : clientFingerprint;
      const { requestCount, bucketStart } = await incrementBucket(policy, fingerprint);
      return { policy, requestCount, bucketStart };
    }),
  );

  let worstRetryAfterSeconds = 0;
  for (const { policy, requestCount, bucketStart } of results) {
    if (requestCount > policy.limit) {
      const resetMs = bucketStart.getTime() + policy.windowSeconds * 1000;
      const retryAfterSeconds = Math.max(1, Math.ceil((resetMs - nowMs) / 1000));
      if (retryAfterSeconds > worstRetryAfterSeconds) {
        worstRetryAfterSeconds = retryAfterSeconds;
      }
    }
  }

  if (Math.random() < CLEANUP_PROBABILITY) {
    cleanupOldBucketsBestEffort();
  }

  if (worstRetryAfterSeconds > 0) {
    return { allowed: false, retryAfterSeconds: worstRetryAfterSeconds };
  }
  return { allowed: true };
}
