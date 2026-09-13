-- =====================================================================
-- Posterchild Media — Migration 004: Durable Rate Limiting
-- =====================================================================
-- Adds a server-only counter table backing durable, database-persisted
-- rate limiting for the public availability and hold Edge Functions.
-- Does not touch Migration 001, 002, or 003 in any way.
--
-- Why a table instead of an in-process counter: Edge Function instances
-- cold-start independently, scale horizontally, and share no process
-- memory, so only a store every instance can see -- this database --
-- can provide a real, global abuse limit. See
-- supabase/functions/_shared/rateLimit.ts for the algorithm that reads
-- and writes this table.
--
-- No raw IP address, email, client name, or user-agent is ever stored
-- here -- `fingerprint` is an opaque HMAC-SHA-256 digest computed by the
-- Edge Function (supabase/functions/_shared/clientIdentity.ts), never
-- the underlying header value itself.
-- =====================================================================

create table public.edge_rate_limit_buckets (
  id uuid primary key default gen_random_uuid(),

  -- Named policy identifier, e.g. 'hold:client:60' or
  -- 'availability:global:900' -- centrally defined in
  -- _shared/rateLimit.ts, never client-controlled.
  scope text not null,

  -- Opaque HMAC-SHA-256 digest of the normalized client identity, or the
  -- fixed literal 'global' for a global-scope bucket. Never a raw IP.
  fingerprint text not null,

  -- Start of this bucket's fixed time window, computed in Postgres from
  -- Postgres's own clock (floor(epoch / window_seconds) * window_seconds)
  -- so every concurrent caller agrees on the same bucket regardless of
  -- Edge Function instance clock drift.
  bucket_start timestamptz not null,

  window_seconds integer not null,
  request_count integer not null default 0,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint edge_rate_limit_buckets_count_positive
    check (request_count > 0),
  constraint edge_rate_limit_buckets_window_positive
    check (window_seconds > 0),

  -- The uniqueness key IS the bucket key. INSERT ... ON CONFLICT
  -- (scope, fingerprint, bucket_start) DO UPDATE ... against this
  -- constraint is what makes the increment atomic under concurrency --
  -- two simultaneous requests for the same bucket serialize at the
  -- database row level rather than racing in application code.
  constraint edge_rate_limit_buckets_bucket_key
    unique (scope, fingerprint, bucket_start)
);

-- Supports the lazy cleanup sweep in _shared/rateLimit.ts
-- (bucket_start < now() - 48h), which is a bounded, indexed range scan
-- rather than a full-table scan.
create index edge_rate_limit_buckets_bucket_start_idx
  on public.edge_rate_limit_buckets (bucket_start);

create or replace function set_edge_rate_limit_buckets_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger trg_edge_rate_limit_buckets_set_updated_at
before update on public.edge_rate_limit_buckets
for each row execute function set_edge_rate_limit_buckets_updated_at();

-- ---------------------------------------------------------------------
-- Access control: server-only.
-- ---------------------------------------------------------------------
-- RLS is enabled with ZERO policies defined -- by Postgres's own RLS
-- semantics that means no row is visible or writable via any role that
-- RLS actually applies to (anon/authenticated through PostgREST).
-- The Edge Functions' direct Postgres connection
-- (supabase/functions/_shared/db.ts) authenticates as the table owner,
-- which bypasses RLS entirely by default, exactly as it already does
-- for every other Stage 2 table -- no policy is added here to grant
-- that access explicitly, since none is needed.
alter table public.edge_rate_limit_buckets enable row level security;
