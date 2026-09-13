-- =====================================================================
-- Posterchild Media — Migration 003: Stage 2 Catalog Corrections
-- =====================================================================
-- DATA CORRECTION ONLY. No schema change: no table, column, constraint,
-- extension, or index is created, dropped, or altered here. Builds on
-- the live Migration 001 + 002 foundation -- neither is touched.
--
-- Locked Stage 2 business decision: Studio Rental Hourly's minimum
-- booking duration is 1 hour. Migration 001 seeded this package with
-- pricing_type = 'hourly' but left minimum_units NULL -- an hourly
-- package with no configured minimum -- which the Edge Function's
-- duration-validation logic (_shared/bookingPolicy.ts) correctly
-- refuses to guess, failing every hold attempt against this package
-- closed with a generic 500 (policy_misconfigured) rather than silently
-- assuming 1. This migration supplies the now-locked value.
--
-- Scope: exactly one row, exactly one column
-- (service_packages.minimum_units for studio-rental/hourly), identified
-- by service slug + package slug, never a hard-coded UUID. No other
-- package, and no other column (retail_price_cents, duration_minutes,
-- checkout_hold_minutes, pricing_type, is_active, is_bookable) on this
-- or any other row is touched. No global constraint is added requiring
-- every hourly package to share this minimum -- events (3) and
-- creative-direction-production (2) legitimately differ and are left
-- exactly as Migration 001 seeded them.
-- =====================================================================

do $$
declare
  target_id uuid;
  target_count integer;
  target_pricing_type text;
begin
  select count(*)
    into target_count
  from public.service_packages sp
  join public.services s on s.id = sp.service_id
  where s.slug = 'studio-rental' and sp.slug = 'hourly';

  if target_count = 0 then
    raise exception 'Migration 003 failed: no service_package found for service_slug=studio-rental, package_slug=hourly.';
  end if;
  if target_count > 1 then
    raise exception 'Migration 003 failed: % service_packages matched service_slug=studio-rental, package_slug=hourly -- expected exactly 1 (ambiguous target).', target_count;
  end if;

  select sp.id, sp.pricing_type
    into target_id, target_pricing_type
  from public.service_packages sp
  join public.services s on s.id = sp.service_id
  where s.slug = 'studio-rental' and sp.slug = 'hourly';

  if target_pricing_type <> 'hourly' then
    raise exception 'Migration 003 failed: studio-rental/hourly has pricing_type=% -- expected hourly. Refusing to set minimum_units on a non-hourly package.', target_pricing_type;
  end if;

  -- Idempotent: a value already equal to 1 (e.g. a rerun, or an
  -- environment where this was already corrected) is left untouched
  -- rather than rewritten, so updated_at only changes when the value
  -- actually changes.
  update public.service_packages
  set minimum_units = 1
  where id = target_id
    and minimum_units is distinct from 1;
end $$;

-- =====================================================================
-- FAIL-FAST VALIDATION -- runs after the update, inside the same
-- implicit migration transaction. Confirms the exact intended
-- end-state, not merely that the UPDATE ran without error.
-- =====================================================================
do $$
declare
  final_value integer;
begin
  select sp.minimum_units into final_value
  from public.service_packages sp
  join public.services s on s.id = sp.service_id
  where s.slug = 'studio-rental' and sp.slug = 'hourly';

  if final_value is distinct from 1 then
    raise exception 'Migration 003 validation failed: studio-rental/hourly minimum_units=% after correction, expected 1.', final_value;
  end if;
end $$;
