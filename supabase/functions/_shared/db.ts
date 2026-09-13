// supabase/functions/_shared/db.ts
//
// Direct pooled Postgres connection for Edge Functions that need true
// multi-statement atomic transactions. The standard Supabase JS/PostgREST
// client cannot compose multiple .from() calls into one atomic
// transaction -- each is its own independent request -- so any operation
// requiring BEGIN/COMMIT/ROLLBACK goes through this module instead.
//
// Connects via Supabase's Supavisor pooler in TRANSACTION mode. A single
// module-scoped client (max: 1) is created once per function instance and
// reused across warm invocations; each request still gets its own,
// independent transaction via withTransaction()/sql.begin() -- never a
// transaction shared or held open across requests.

import postgres from "npm:postgres@3";

const SUPABASE_DB_URL = Deno.env.get("SUPABASE_DB_URL");

if (!SUPABASE_DB_URL) {
  // Fails fast at module load (cold start), before any request is served.
  // Never logs the value of the variable itself -- only that it is absent.
  throw new Error(
    "Server configuration error: SUPABASE_DB_URL is not set. " +
      "Configure it as a Supabase Edge Function secret before this " +
      "function can serve requests.",
  );
}

// LOCAL TESTING ONLY. Supabase's local Docker Postgres does not serve
// TLS, so a client that insists on SSL cannot connect to it at all --
// this flag is the one deliberate, explicit escape hatch for that,
// checked against the exact string "true" and nothing else. Absent,
// empty, "false", "TRUE", "1", or any other value all mean "not local"
// and leave SSL required. There is no inference from hostname,
// SUPABASE_URL, NODE_ENV, or any other ambient signal, and no fallback
// from a failed TLS handshake to a plaintext retry -- the only path to
// disabling SSL is this one variable being exactly "true".
//
// PRODUCTION MUST NEVER SET POSTERCHILD_LOCAL_DB=true. This function's
// production/deployed configuration (Supabase Edge Function secrets)
// must never define this variable at all -- its mere absence is what
// keeps production on the secure path by default, with no other
// safeguard standing behind it.
const POSTERCHILD_LOCAL_DB = Deno.env.get("POSTERCHILD_LOCAL_DB") === "true";

// max: 1 -- Supavisor already pools connections across every concurrently
// running function instance; this module must not layer a second pool on
// top of that. ssl is required, never optional, for a connection carrying
// full table-write privileges -- disabled only under the explicit local
// flag above. prepare: false avoids relying on client-side
// prepared-statement caching, which is not guaranteed to survive across
// separate logical connections handed out by a transaction-mode pooler.
export const sql = postgres(SUPABASE_DB_URL, {
  max: 1,
  ssl: POSTERCHILD_LOCAL_DB ? false : "require",
  prepare: false,
});

/**
 * Runs `fn` inside a single Postgres transaction (BEGIN ... COMMIT).
 * If `fn` throws, postgres.js issues ROLLBACK automatically and re-throws
 * the original error, including its Postgres `code` field -- which
 * _shared/errors.ts depends on for safe domain-error mapping. Callers
 * must never catch and swallow errors inside `fn` if they want the
 * transaction to roll back; let them propagate.
 */
export function withTransaction<T>(
  fn: (tx: postgres.TransactionSql) => Promise<T>,
): Promise<T> {
  // postgres.js types sql.begin<T>() as Promise<UnwrapPromiseArray<T>>,
  // since it also accepts a callback returning an array of promises (which
  // it unwraps element-by-element). TS cannot reduce that conditional type
  // back to plain T for an unconstrained generic, even though
  // UnwrapPromiseArray<T> is structurally identical to T for any non-array
  // T -- true for every caller here, since every withTransaction callback
  // in this codebase resolves to a single discriminated-union object,
  // never an array. No runtime behavior changes.
  return sql.begin(fn) as Promise<T>;
}
