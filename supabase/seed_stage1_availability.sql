-- =====================================================================
-- Posterchild Media — Stage 1C Draft: Availability Window Seed
-- =====================================================================
-- STATUS: DRAFT FOR REVIEW. NOT EXECUTED. NOT A MIGRATION.
--
-- This is operational scheduling data, not schema. It does not alter any
-- table, constraint, or RLS policy, and does not touch
-- supabase/migrations/001_foundation_catalog.sql or
-- supabase/migrations/002_scheduling_bookings.sql in any way.
--
-- It materializes the LOCKED weekly schedule as concrete
-- block_type = 'available_window' rows across a rolling 90-local-date
-- horizon in America/New_York:
--
--   Posterchild Photographer (role=photographer): 10:00 AM - 10:00 PM
--   Posterchild Studio       (role=studio):       10:00 AM -  8:00 PM
--   applied to all 90 dates, Day 1 = today in America/New_York through
--   Day 90 = Day 1 + 89 calendar days.
--
-- Expected result on an empty table: 90 photographer rows + 90 studio
-- rows = 180 rows total.
--
-- It deliberately does NOT:
--   - insert any blackout row
--   - delete, update, or overwrite any existing row (past or future)
--   - assume any table is currently empty -- every insert is guarded so
--     rerunning this script (e.g. 30 days from now, to roll the horizon
--     forward) leaves already-materialized overlapping dates untouched
--     and only adds the newly-in-range dates
--
-- =====================================================================
-- TIMEZONE / DST CORRECTNESS -- READ BEFORE RUNNING
-- =====================================================================
-- Every local wall-clock instant below is constructed as:
--   (local_date + time 'HH:MM:SS') at time zone 'America/New_York'
-- `date + time` produces a naive `timestamp` (e.g. 2026-09-20 10:00:00,
-- no zone attached). `AT TIME ZONE 'America/New_York'` then interprets
-- THAT naive value as Eastern local time and converts it to the correct
-- timestamptz, using whichever UTC offset actually applies to that
-- SPECIFIC calendar date -- Postgres's own timezone database resolves
-- this per-row, automatically correct on both sides of a DST transition.
-- No single hard-coded UTC offset (-04:00 or -05:00) is used anywhere in
-- this file, exactly as required.
--
-- "Today" in America/New_York is computed as
-- `(now() at time zone 'America/New_York')::date` rather than the bare
-- `current_date`, because `current_date` reflects the database SESSION's
-- timezone setting, not necessarily America/New_York -- using `now()`
-- (a zone-independent instant) and converting explicitly is the only way
-- to get the correct Eastern calendar date regardless of session config.
--
-- Note: this same `(now() at time zone 'America/New_York')::date`
-- expression is evaluated independently by the insert statements and
-- again by the validation block below. Both run within the same fast
-- transaction (well under a second in practice), so a mismatch would
-- require this script's own execution to span a local midnight boundary
-- -- a theoretical, not practical, concern for a script this size. Not
-- engineered around further to avoid introducing a temporary table for
-- a practically-impossible race.
--
-- DST transition dates themselves are not a special case here: the
-- transition always occurs at 2:00 AM local time, and every window in
-- this file starts no earlier than 10:00 AM -- always an unambiguous,
-- always-existing wall-clock time regardless of which side of the
-- transition a given date falls on. The window's ABSOLUTE (UTC) duration
-- legitimately differs by one hour on the actual transition dates --
-- that is correct, expected behavior for a locally-defined schedule, not
-- a bug.
-- =====================================================================
-- ROLLING-HORIZON / RERUN BEHAVIOR
-- =====================================================================
-- Safe to rerun later to extend the horizon. Every candidate row is
-- guarded by a correlated NOT EXISTS matching on (resource_id,
-- block_type, start_datetime, end_datetime) -- the same fields a real
-- unique constraint would likely use, per the same honest idempotency
-- model as seed_stage1_resources.sql (no such constraint exists or is
-- created here; this minimizes duplicate risk for a manually-run script,
-- it does not guarantee correctness under truly concurrent execution).
-- Re-running 30 days from now recomputes "today" as of that run, so the
-- 90-date window shifts forward accordingly: the ~60 already-materialized
-- overlapping dates are skipped (exact match found), and the ~30 newly
-- in-range dates are inserted. Past dates are never touched, updated, or
-- deleted by this script -- expired-row cleanup is left as a separate,
-- future maintenance concern, not addressed here.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- Early gate: exactly one active resource per role must exist BEFORE
-- any insert is attempted. A missing or duplicated resource must abort
-- the whole operation, not silently insert zero rows or double rows.
-- ---------------------------------------------------------------------
do $$
declare
  photographer_resource_count integer;
  studio_resource_count integer;
begin
  select count(*) into photographer_resource_count
  from public.resources
  where name = 'Posterchild Photographer' and role = 'photographer' and is_active = true;

  if photographer_resource_count <> 1 then
    raise exception 'Stage 1C seed validation failed: expected exactly 1 active Posterchild Photographer resource, found %.', photographer_resource_count;
  end if;

  select count(*) into studio_resource_count
  from public.resources
  where name = 'Posterchild Studio' and role = 'studio' and is_active = true;

  if studio_resource_count <> 1 then
    raise exception 'Stage 1C seed validation failed: expected exactly 1 active Posterchild Studio resource, found %.', studio_resource_count;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Photographer: 90 windows, 10:00 AM - 10:00 PM America/New_York
-- ---------------------------------------------------------------------
insert into public.resource_availability_blocks
  (resource_id, block_type, start_datetime, end_datetime)
select
  ph.id,
  'available_window',
  (horizon.local_date + time '10:00:00') at time zone 'America/New_York',
  (horizon.local_date + time '22:00:00') at time zone 'America/New_York'
from (
  select ((now() at time zone 'America/New_York')::date + n) as local_date
  from generate_series(0, 89) as n
) horizon
cross join (
  select id from public.resources
  where name = 'Posterchild Photographer' and role = 'photographer' and is_active = true
) ph
where not exists (
  select 1 from public.resource_availability_blocks existing
  where existing.resource_id = ph.id
    and existing.block_type = 'available_window'
    and existing.start_datetime = (horizon.local_date + time '10:00:00') at time zone 'America/New_York'
    and existing.end_datetime = (horizon.local_date + time '22:00:00') at time zone 'America/New_York'
);

-- ---------------------------------------------------------------------
-- Studio: 90 windows, 10:00 AM - 8:00 PM America/New_York
-- ---------------------------------------------------------------------
insert into public.resource_availability_blocks
  (resource_id, block_type, start_datetime, end_datetime)
select
  st.id,
  'available_window',
  (horizon.local_date + time '10:00:00') at time zone 'America/New_York',
  (horizon.local_date + time '20:00:00') at time zone 'America/New_York'
from (
  select ((now() at time zone 'America/New_York')::date + n) as local_date
  from generate_series(0, 89) as n
) horizon
cross join (
  select id from public.resources
  where name = 'Posterchild Studio' and role = 'studio' and is_active = true
) st
where not exists (
  select 1 from public.resource_availability_blocks existing
  where existing.resource_id = st.id
    and existing.block_type = 'available_window'
    and existing.start_datetime = (horizon.local_date + time '10:00:00') at time zone 'America/New_York'
    and existing.end_datetime = (horizon.local_date + time '20:00:00') at time zone 'America/New_York'
);

-- =====================================================================
-- FAIL-FAST VALIDATION -- runs before commit, inside the same
-- transaction. Checks each of the 180 EXACT intended (resource, start,
-- end) combinations individually -- never a blind total-table count,
-- since unrelated legitimate rows (other horizons, manually-added
-- windows, blackouts) may coexist and must not affect this check either
-- way. A count of exactly 1 per intended row is required: 0 means
-- missing (silent partial insert), more than 1 means an undetected
-- duplicate (resource_availability_blocks has no unique constraint to
-- prevent this at the database level). Blackout rows are never queried
-- here at all -- this validation only ever counts block_type =
-- 'available_window' rows, so a legitimate blackout overlapping an
-- available_window (an intentional override, not an error) can never
-- cause this validation to fail.
-- =====================================================================
do $$
declare
  bad_count integer;
begin
  select count(*) into bad_count
  from (
    select
      ((horizon.local_date + time '10:00:00') at time zone 'America/New_York') as expected_start,
      ((horizon.local_date + time '22:00:00') at time zone 'America/New_York') as expected_end
    from (
      select ((now() at time zone 'America/New_York')::date + n) as local_date
      from generate_series(0, 89) as n
    ) horizon
  ) expected
  where (
    select count(*)
    from public.resource_availability_blocks b
    join public.resources r on r.id = b.resource_id
    where r.name = 'Posterchild Photographer' and r.role = 'photographer'
      and b.block_type = 'available_window'
      and b.start_datetime = expected.expected_start
      and b.end_datetime = expected.expected_end
  ) <> 1;

  if bad_count > 0 then
    raise exception 'Stage 1C seed validation failed: % of the 90 intended Photographer windows are missing or duplicated.', bad_count;
  end if;

  select count(*) into bad_count
  from (
    select
      ((horizon.local_date + time '10:00:00') at time zone 'America/New_York') as expected_start,
      ((horizon.local_date + time '20:00:00') at time zone 'America/New_York') as expected_end
    from (
      select ((now() at time zone 'America/New_York')::date + n) as local_date
      from generate_series(0, 89) as n
    ) horizon
  ) expected
  where (
    select count(*)
    from public.resource_availability_blocks b
    join public.resources r on r.id = b.resource_id
    where r.name = 'Posterchild Studio' and r.role = 'studio'
      and b.block_type = 'available_window'
      and b.start_datetime = expected.expected_start
      and b.end_datetime = expected.expected_end
  ) <> 1;

  if bad_count > 0 then
    raise exception 'Stage 1C seed validation failed: % of the 90 intended Studio windows are missing or duplicated.', bad_count;
  end if;
end $$;

commit;

-- =====================================================================
-- OPTIONAL, READ-ONLY -- for manual verification after running the
-- block above. Not part of the transaction; safe to run separately.
-- Deliberately scoped to the CURRENT run's 90-day horizon only (via the
-- same "today" expression used by the seed itself), never a blind
-- historical total -- older rows from a prior run, or rows from any
-- other source, must not affect these results either way.
-- =====================================================================

-- 1) Full listing, local time displayed for a human eyeball scan.
--    A clean result is 90 rows from each, reading 10:00/22:00 and
--    10:00/20:00 respectively (the stored UTC offset differs by one
--    hour across a DST boundary within the horizon -- that is correct;
--    the LOCAL times shown here should not).
-- select b.start_datetime at time zone 'America/New_York' as local_start,
--        b.end_datetime at time zone 'America/New_York' as local_end
-- from public.resource_availability_blocks b
-- join public.resources r on r.id = b.resource_id
-- where r.name = 'Posterchild Photographer' and b.block_type = 'available_window'
-- order by b.start_datetime;
--
-- select b.start_datetime at time zone 'America/New_York' as local_start,
--        b.end_datetime at time zone 'America/New_York' as local_end
-- from public.resource_availability_blocks b
-- join public.resources r on r.id = b.resource_id
-- where r.name = 'Posterchild Studio' and b.block_type = 'available_window'
-- order by b.start_datetime;

-- 2) Exact current-horizon match counts. EXPECT: photographer=90,
--    studio=90 (two rows returned by this single query).
-- select 'photographer' as resource, count(*) as matched_current_horizon
-- from (
--   select
--     ((horizon.local_date + time '10:00:00') at time zone 'America/New_York') as expected_start,
--     ((horizon.local_date + time '22:00:00') at time zone 'America/New_York') as expected_end
--   from (
--     select ((now() at time zone 'America/New_York')::date + n) as local_date
--     from generate_series(0, 89) as n
--   ) horizon
-- ) expected
-- join public.resource_availability_blocks b
--   on b.start_datetime = expected.expected_start and b.end_datetime = expected.expected_end
-- join public.resources r on r.id = b.resource_id
-- where r.name = 'Posterchild Photographer' and r.role = 'photographer' and b.block_type = 'available_window'
-- union all
-- select 'studio', count(*)
-- from (
--   select
--     ((horizon.local_date + time '10:00:00') at time zone 'America/New_York') as expected_start,
--     ((horizon.local_date + time '20:00:00') at time zone 'America/New_York') as expected_end
--   from (
--     select ((now() at time zone 'America/New_York')::date + n) as local_date
--     from generate_series(0, 89) as n
--   ) horizon
-- ) expected
-- join public.resource_availability_blocks b
--   on b.start_datetime = expected.expected_start and b.end_datetime = expected.expected_end
-- join public.resources r on r.id = b.resource_id
-- where r.name = 'Posterchild Studio' and r.role = 'studio' and b.block_type = 'available_window';
-- -- Sum the two `matched_current_horizon` values by hand -- EXPECT: 180 total.

-- 3) Exact-duplicate detection within the current horizon only.
--    EXPECT: zero rows from this query, for both resources.
-- select r.name, b.start_datetime, b.end_datetime, count(*) as duplicate_count
-- from (
--   select
--     ((horizon.local_date + time '10:00:00') at time zone 'America/New_York') as expected_start,
--     ((horizon.local_date + time '22:00:00') at time zone 'America/New_York') as expected_end
--   from (
--     select ((now() at time zone 'America/New_York')::date + n) as local_date
--     from generate_series(0, 89) as n
--   ) horizon
-- ) expected
-- join public.resource_availability_blocks b
--   on b.start_datetime = expected.expected_start and b.end_datetime = expected.expected_end
-- join public.resources r on r.id = b.resource_id
-- where r.name = 'Posterchild Photographer' and r.role = 'photographer' and b.block_type = 'available_window'
-- group by r.name, b.start_datetime, b.end_datetime
-- having count(*) > 1
-- union all
-- select r.name, b.start_datetime, b.end_datetime, count(*)
-- from (
--   select
--     ((horizon.local_date + time '10:00:00') at time zone 'America/New_York') as expected_start,
--     ((horizon.local_date + time '20:00:00') at time zone 'America/New_York') as expected_end
--   from (
--     select ((now() at time zone 'America/New_York')::date + n) as local_date
--     from generate_series(0, 89) as n
--   ) horizon
-- ) expected
-- join public.resource_availability_blocks b
--   on b.start_datetime = expected.expected_start and b.end_datetime = expected.expected_end
-- join public.resources r on r.id = b.resource_id
-- where r.name = 'Posterchild Studio' and r.role = 'studio' and b.block_type = 'available_window'
-- group by r.name, b.start_datetime, b.end_datetime
-- having count(*) > 1;
