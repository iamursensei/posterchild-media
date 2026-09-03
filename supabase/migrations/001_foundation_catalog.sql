-- =====================================================================
-- Posterchild Media — Migration 001: Foundation + Catalog
-- =====================================================================
-- Greenfield migration. Live audit confirmed every target table missing
-- from the Posterchild Supabase project, including the legacy
-- `booking_resources` and `availability_dates` concepts — neither is
-- created here or anywhere in this migration; both are superseded by
-- the `resource_reservations` model planned for Migration 002.
--
-- Scope: exactly the 8 tables approved for this migration —
--   clients, services, service_packages, service_addons,
--   service_package_resource_requirements, products, product_variants,
--   product_collection_items
-- — plus only the supporting types/functions/triggers/indexes/views/
-- grants/RLS these 8 tables require. No Migration 002+ tables
-- (resources, bookings, orders, memberships, payments, notifications,
-- calendar) are created here.
--
-- Money is stored as integer cents (never floating point). Unpriced /
-- unapproved catalog items are seeded with retail_price_cents = NULL
-- and is_bookable / is_purchasable = false — no price is invented
-- anywhere in this file.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Extensions
-- ---------------------------------------------------------------------
create extension if not exists pgcrypto;   -- gen_random_uuid()
create extension if not exists citext;     -- case-insensitive email handling

-- ---------------------------------------------------------------------
-- Shared types
-- ---------------------------------------------------------------------
-- Single shared pricing-type vocabulary across service_packages,
-- service_addons, and products, matching the approved architecture:
--   fixed        — definitive, non-negotiable price
--   hourly       — per-hour rate, quantity supplied at booking time
--   starting_at  — a real minimum price; final total may exceed it
--   custom_quote — the offering is INTENTIONALLY sold through a quote
--                  workflow, not computed checkout; retail_price_cents
--                  stays NULL by design, not by omission
--   per_unit     — priced per a named unit (e.g. "per image", "per 2-page spread")
--   unpriced     — Posterchild has not yet approved a customer-facing
--                  price/scope; retail_price_cents stays NULL until it
--                  is. Distinct from custom_quote: this is a temporary
--                  "not ready," not an intentional pricing model.
create type public.pricing_type as enum (
  'fixed', 'hourly', 'starting_at', 'custom_quote', 'per_unit', 'unpriced'
);

-- Resource roles are intentionally a plain TEXT + CHECK constraint,
-- not a Postgres ENUM. An ENUM value can't be removed and can only be
-- added outside a transaction block in older Postgres versions, which
-- makes it a poor fit for a role vocabulary explicitly called out as
-- needing to grow later (future team resources) without churn. Widening
-- this CHECK is a one-line migration; widening a Postgres enum is not.
-- No `resources` table exists yet (Migration 002), so this column is
-- deliberately not an FK — it names a ROLE, not a specific resource row.

-- ---------------------------------------------------------------------
-- Reusable updated_at trigger function (used by every mutable table
-- below instead of duplicating a trigger function per table)
-- ---------------------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- =====================================================================
-- 1. clients — canonical customer record
-- =====================================================================
create table public.clients (
  id            uuid primary key default gen_random_uuid(),
  auth_user_id  uuid references auth.users(id) on delete set null,
  first_name    text not null,
  last_name     text not null,
  email         citext not null,
  phone         text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint clients_email_unique unique (email),
  -- One auth.users account maps to at most one clients row. Postgres
  -- UNIQUE constraints treat NULL as distinct from every other value
  -- (including other NULLs), so any number of guest clients with
  -- auth_user_id = NULL remains valid -- only a second row pointing at
  -- the SAME non-null auth account is rejected.
  constraint clients_auth_user_id_unique unique (auth_user_id)
);

comment on table public.clients is
  'Canonical customer record. auth_user_id is nullable — guest bookings never require an account, and the unique constraint on it allows unlimited NULLs while still enforcing at most one clients row per auth account. ON DELETE SET NULL on auth_user_id preserves client/order/booking history if an auth account is ever removed.';

-- No separate index needed: the UNIQUE constraint above creates its own
-- backing btree index on auth_user_id, which already serves lookups.

create trigger trg_clients_set_updated_at
  before update on public.clients
  for each row execute function public.set_updated_at();

-- RLS: enabled, no public policies at all in Migration 001. Client
-- creation/lookup happens exclusively via the service role until a
-- booking backend exists. One forward-compatible policy is added now
-- since it costs nothing and needs no future migration: once a client
-- has a linked auth account, they may read their own row.
alter table public.clients enable row level security;

create policy clients_select_own
  on public.clients
  for select
  using (auth.uid() = auth_user_id);

revoke all on public.clients from anon, authenticated;
grant select on public.clients to authenticated;  -- RLS policy above still governs which rows

-- No public directory view is created for clients, by design.

-- =====================================================================
-- 2. services — top-level bookable/service catalog
-- =====================================================================
create table public.services (
  id                 uuid primary key default gen_random_uuid(),
  slug               text not null unique,
  name               text not null,
  public_description text,
  internal_notes     text,
  is_active          boolean not null default true,
  is_bookable        boolean not null default true,
  sort_order         integer not null default 0,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

comment on table public.services is
  'Top-level service categories (Portraits & Milestones, Events, Studio Rental, ...). Pricing lives on service_packages, never here.';

create index services_active_sort_idx on public.services (is_active, sort_order);

create trigger trg_services_set_updated_at
  before update on public.services
  for each row execute function public.set_updated_at();

alter table public.services enable row level security;
revoke all on public.services from anon, authenticated;
-- No direct public policy — public reads go through public_services (below).

-- =====================================================================
-- 3. service_packages — priced tiers under a service
-- =====================================================================
create table public.service_packages (
  id                     uuid primary key default gen_random_uuid(),
  service_id             uuid not null references public.services(id) on delete cascade,
  slug                   text not null,
  name                   text not null,
  pricing_type           public.pricing_type not null,
  retail_price_cents     integer,
  currency               text not null default 'USD',
  unit_label             text,
  duration_minutes       integer,
  minimum_units          numeric,
  is_limited_release     boolean not null default false,
  is_active              boolean not null default true,
  is_bookable            boolean not null default true,
  sort_order             integer not null default 0,
  public_description     text,
  internal_notes         text,
  -- Payment-policy seam for Migration 005 — not implemented/enforced here.
  payment_policy_type    text not null default 'retainer_percentage',
  retainer_percentage    numeric(4,3),
  checkout_hold_minutes  integer not null default 10,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),

  constraint service_packages_service_slug_unique unique (service_id, slug),
  constraint service_packages_currency_format_check
    check (currency ~ '^[A-Z]{3}$'),
  constraint service_packages_duration_positive_check
    check (duration_minutes is null or duration_minutes > 0),
  constraint service_packages_minimum_units_positive_check
    check (minimum_units is null or minimum_units > 0),
  constraint service_packages_checkout_hold_positive_check
    check (checkout_hold_minutes > 0),
  constraint service_packages_retainer_percentage_range_check
    check (retainer_percentage is null or (retainer_percentage > 0 and retainer_percentage <= 1)),
  constraint service_packages_payment_policy_type_check
    check (payment_policy_type in ('retainer_percentage', 'full_payment', 'custom_schedule')),
  -- No invented prices: fixed/hourly packages must carry a real price;
  -- custom_quote and unpriced packages must never carry a fabricated one.
  constraint service_packages_priced_when_fixed_or_hourly_check
    check (pricing_type not in ('fixed', 'hourly') or retail_price_cents is not null),
  constraint service_packages_no_price_when_unresolved_check
    check (pricing_type not in ('custom_quote', 'unpriced') or retail_price_cents is null),
  -- is_bookable means "selectable through the booking experience," not
  -- "computed checkout eligible" — a custom_quote package may be
  -- bookable with no price (it routes to an inquiry/quote workflow).
  -- An unpriced package may NOT be bookable under any circumstance
  -- until Posterchild approves its price/scope.
  constraint service_packages_bookable_requires_price_or_quote_check
    check (retail_price_cents is not null or is_bookable = false or pricing_type = 'custom_quote')
);

comment on table public.service_packages is
  'Priced, bookable tiers under a service (e.g. Power Session, Studio Rental Half Day). is_bookable means selectable through the booking experience, not "computed checkout eligible" -- pricing_type determines the actual pricing workflow (fixed/hourly/starting_at route to computed checkout; custom_quote routes to an inquiry/quote workflow and may still be bookable with no price; unpriced must never be bookable until a price/scope is approved).';

create index service_packages_service_id_idx on public.service_packages (service_id);
create index service_packages_active_sort_idx on public.service_packages (is_active, sort_order);

create trigger trg_service_packages_set_updated_at
  before update on public.service_packages
  for each row execute function public.set_updated_at();

alter table public.service_packages enable row level security;
revoke all on public.service_packages from anon, authenticated;

-- =====================================================================
-- 4. service_addons — optional priced extras on a service
-- =====================================================================
create table public.service_addons (
  id                     uuid primary key default gen_random_uuid(),
  slug                   text not null unique,
  name                   text not null,
  applicable_service_id  uuid references public.services(id) on delete cascade,
  pricing_type           public.pricing_type not null,
  retail_price_cents     integer,
  currency               text not null default 'USD',
  unit_label             text,
  duration_minutes       integer,
  production_cost_cents  integer,  -- INTERNAL ONLY — never selected by any public view
  requires_approval      boolean not null default false,
  is_active              boolean not null default true,
  is_bookable            boolean not null default false,
  sort_order             integer not null default 0,
  public_description     text,
  internal_notes         text,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),

  constraint service_addons_currency_format_check
    check (currency ~ '^[A-Z]{3}$'),
  constraint service_addons_duration_positive_check
    check (duration_minutes is null or duration_minutes > 0),
  -- No invented prices: custom_quote and unpriced add-ons must never
  -- carry a fabricated retail price.
  constraint service_addons_no_price_when_unresolved_check
    check (pricing_type not in ('custom_quote', 'unpriced') or retail_price_cents is null),
  -- is_bookable means "selectable through the booking experience," not
  -- "computed checkout eligible." A custom_quote add-on may be bookable
  -- with no price (it routes to an inquiry/quote workflow). An unpriced
  -- add-on may NOT be bookable until Posterchild approves its price/scope.
  constraint service_addons_bookable_requires_price_or_quote_check
    check (retail_price_cents is not null or is_bookable = false or pricing_type = 'custom_quote')
);

comment on table public.service_addons is
  'Optional priced extras (extra hours, dedicated videography, drone, mic/audio, rush, props, etc.). production_cost_cents is internal-only and must never appear in a public view. Prints/books/wall art are NOT modeled here — they are products.';

create index service_addons_applicable_service_id_idx on public.service_addons (applicable_service_id);
create index service_addons_active_sort_idx on public.service_addons (is_active, sort_order);

create trigger trg_service_addons_set_updated_at
  before update on public.service_addons
  for each row execute function public.set_updated_at();

alter table public.service_addons enable row level security;
revoke all on public.service_addons from anon, authenticated;

-- =====================================================================
-- 5. service_package_resource_requirements — required resource ROLES
-- =====================================================================
create table public.service_package_resource_requirements (
  id                  uuid primary key default gen_random_uuid(),
  service_package_id  uuid references public.service_packages(id) on delete cascade,
  service_addon_id    uuid references public.service_addons(id) on delete cascade,
  resource_role       text not null,
  quantity            integer not null default 1,
  is_required         boolean not null default true,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),

  constraint service_package_resource_requirements_role_check
    check (resource_role in ('photographer', 'videographer', 'studio', 'drone_operator')),
  constraint service_package_resource_requirements_quantity_positive_check
    check (quantity > 0),
  -- Exactly one requirement source: a package OR an add-on, never both,
  -- never neither.
  constraint service_package_resource_requirements_exactly_one_source_check
    check (
      (service_package_id is not null and service_addon_id is null)
      or
      (service_package_id is null and service_addon_id is not null)
    )
);

comment on table public.service_package_resource_requirements is
  'Which resource role(s) a service_package or service_addon requires (e.g. Studio Portrait -> photographer + studio). Deliberately has no FK to a resources table (none exists until Migration 002) and no rows are seeded here yet — this migration only creates the structure. resource_role is TEXT+CHECK rather than a Postgres ENUM specifically so future roles can be added with a lightweight constraint change instead of enum-type surgery.';

create index spr_requirements_package_id_idx on public.service_package_resource_requirements (service_package_id);
create index spr_requirements_addon_id_idx on public.service_package_resource_requirements (service_addon_id);

create trigger trg_spr_requirements_set_updated_at
  before update on public.service_package_resource_requirements
  for each row execute function public.set_updated_at();

alter table public.service_package_resource_requirements enable row level security;
revoke all on public.service_package_resource_requirements from anon, authenticated;
-- Internal booking-engine table — no public view. The wizard doesn't
-- need this data; the booking backend does.

-- =====================================================================
-- 6. products — physical/print catalog
-- =====================================================================
create table public.products (
  id                  uuid primary key default gen_random_uuid(),
  slug                text not null unique,
  name                text not null,
  category            text not null,
  pricing_type        public.pricing_type not null,
  retail_price_cents  integer,
  currency            text not null default 'USD',
  unit_label          text,
  is_active           boolean not null default true,
  is_purchasable      boolean not null default false,
  sort_order          integer not null default 0,
  public_description  text,
  internal_notes      text,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),

  constraint products_category_check
    check (category in ('a_la_carte_print', 'print_collection', 'wall_art', 'photo_book', 'book_addon')),
  constraint products_currency_format_check
    check (currency ~ '^[A-Z]{3}$'),
  constraint products_purchasable_requires_price_check
    check (retail_price_cents is not null or is_purchasable = false),
  constraint products_no_price_when_custom_quote_check
    check (pricing_type <> 'custom_quote' or retail_price_cents is null)
);

comment on table public.products is
  'Physical/print catalog (a la carte prints, print collections, wall art, photo books, book add-ons). is_purchasable=false is used for items publicly marketed at a starting-at price but not yet ready for a computed checkout (Wall Art without size variants, Story/Gallery Collection, Wallet Print Set pending quantity decision).';

create index products_active_sort_idx on public.products (is_active, sort_order);
create index products_category_idx on public.products (category);

create trigger trg_products_set_updated_at
  before update on public.products
  for each row execute function public.set_updated_at();

alter table public.products enable row level security;
revoke all on public.products from anon, authenticated;

-- =====================================================================
-- 7. product_variants — size/configuration-specific pricing
-- =====================================================================
create table public.product_variants (
  id                     uuid primary key default gen_random_uuid(),
  product_id             uuid not null references public.products(id) on delete cascade,
  variant_name           text not null,
  sku                    text,
  attributes             jsonb not null default '{}'::jsonb,
  retail_price_cents     integer,
  currency               text not null default 'USD',
  production_cost_cents  integer,  -- INTERNAL ONLY — never selected by any public view
  is_active              boolean not null default true,
  is_purchasable         boolean not null default false,
  sort_order             integer not null default 0,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),

  constraint product_variants_product_name_unique unique (product_id, variant_name),
  constraint product_variants_currency_format_check
    check (currency ~ '^[A-Z]{3}$'),
  constraint product_variants_purchasable_requires_price_check
    check (retail_price_cents is not null or is_purchasable = false)
);

comment on table public.product_variants is
  'Size/finish/configuration-specific retail pricing (primarily Wall Art). No rows are seeded in Migration 001 — no size x price matrix has been approved yet. Mini Memory Book is intentionally NOT modeled with variants here: its 4x4/4x6 choice carries an identical locked price, so a variant row would add structure with no pricing benefit.';

create index product_variants_product_id_idx on public.product_variants (product_id);

create trigger trg_product_variants_set_updated_at
  before update on public.product_variants
  for each row execute function public.set_updated_at();

alter table public.product_variants enable row level security;
revoke all on public.product_variants from anon, authenticated;

-- =====================================================================
-- 8. product_collection_items — bundle composition
-- =====================================================================
create table public.product_collection_items (
  id                     uuid primary key default gen_random_uuid(),
  collection_product_id  uuid not null references public.products(id) on delete cascade,
  included_product_id    uuid references public.products(id) on delete restrict,
  quantity               integer not null default 1,
  note                   text,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),

  constraint product_collection_items_unique_component
    unique (collection_product_id, included_product_id),
  constraint product_collection_items_quantity_positive_check
    check (quantity > 0),
  constraint product_collection_items_no_self_reference_check
    check (collection_product_id <> included_product_id)
);

comment on table public.product_collection_items is
  'Bundle contents for collection-category products (e.g. The Keepsake = 2x 5x7 + 1x 8x10). included_product_id is nullable to allow a documented-but-unresolved component line; none are seeded that way in Migration 001. The unique constraint on (collection_product_id, included_product_id) prevents accidental duplicate component rows from silently corrupting a bundle''s composition — use quantity to represent multiples of the same component, not repeated rows.';

create index product_collection_items_collection_id_idx on public.product_collection_items (collection_product_id);
create index product_collection_items_included_id_idx on public.product_collection_items (included_product_id);

create trigger trg_product_collection_items_set_updated_at
  before update on public.product_collection_items
  for each row execute function public.set_updated_at();

alter table public.product_collection_items enable row level security;
revoke all on public.product_collection_items from anon, authenticated;

-- =====================================================================
-- Public-safe catalog views
-- =====================================================================
-- Every view below EXPLICITLY declares security_invoker = false rather
-- than relying on it as an unstated default. This is the security
-- boundary that lets a view owned by the migration-running role read
-- past RLS on the locked-down base tables (definer/owner-privilege
-- execution) and apply its own explicit column allowlist and WHERE
-- filtering. Do NOT change any of these to security_invoker = true —
-- that would make the view execute as the QUERYING role instead, and
-- RLS would then block it entirely, since the base tables carry no
-- public policies by design.
--
-- Every column list below is an explicit allowlist. production_cost_cents
-- and internal_notes are never referenced in any view in this file.

create view public.public_services
  with (security_invoker = false)
as
select
  id, slug, name, public_description, sort_order
from public.services
where is_active = true;

create view public.public_service_packages
  with (security_invoker = false)
as
select
  id, service_id, slug, name, pricing_type, retail_price_cents, currency,
  unit_label, duration_minutes, minimum_units, is_limited_release,
  is_bookable, sort_order, public_description
from public.service_packages
where is_active = true;

create view public.public_service_addons
  with (security_invoker = false)
as
select
  id, slug, name, applicable_service_id, pricing_type, retail_price_cents,
  currency, unit_label, duration_minutes, requires_approval, is_bookable,
  sort_order, public_description
from public.service_addons
where is_active = true;

create view public.public_products
  with (security_invoker = false)
as
select
  id, slug, name, category, pricing_type, retail_price_cents, currency,
  unit_label, is_purchasable, sort_order, public_description
from public.products
where is_active = true;

create view public.public_product_variants
  with (security_invoker = false)
as
select
  v.id, v.product_id, v.variant_name, v.attributes, v.retail_price_cents,
  v.currency, v.is_purchasable, v.sort_order
from public.product_variants v
join public.products p on p.id = v.product_id
where v.is_active = true and p.is_active = true;

create view public.public_product_collection_items
  with (security_invoker = false)
as
select
  ci.id, ci.collection_product_id, ci.included_product_id, ci.quantity
from public.product_collection_items ci
join public.products collection on collection.id = ci.collection_product_id
left join public.products included on included.id = ci.included_product_id
where collection.is_active = true
  and (ci.included_product_id is null or included.is_active = true);

grant usage on schema public to anon, authenticated;
grant select on
  public.public_services,
  public.public_service_packages,
  public.public_service_addons,
  public.public_products,
  public.public_product_variants,
  public.public_product_collection_items
to anon, authenticated;

-- =====================================================================
-- Seed data — approved pricing only, upsert-safe (idempotent on slug)
-- =====================================================================

-- ---------------------------------------------------------------------
-- Services
-- ---------------------------------------------------------------------
insert into public.services (slug, name, is_active, is_bookable, sort_order)
values
  ('portraits-milestones',        'Portraits & Milestones',            true, true, 10),
  ('events',                      'Events',                            true, true, 20),
  ('corporate-commercial',        'Corporate & Commercial',            true, true, 30),
  ('creative-direction-production','Creative Direction & Production',  true, true, 40),
  ('real-estate-media',           'Real Estate Media',                 true, true, 50),
  ('studio-rental',               'Studio Rental',                     true, true, 60)
on conflict (slug) do update set
  name = excluded.name,
  is_active = excluded.is_active,
  is_bookable = excluded.is_bookable,
  sort_order = excluded.sort_order;

-- ---------------------------------------------------------------------
-- Service packages: Portraits & Milestones
-- ---------------------------------------------------------------------
insert into public.service_packages
  (service_id, slug, name, pricing_type, retail_price_cents, duration_minutes,
   is_limited_release, is_active, is_bookable, sort_order, public_description)
select s.id, v.slug, v.name, v.pricing_type::public.pricing_type, v.retail_price_cents,
       v.duration_minutes, v.is_limited_release, true, true, v.sort_order, v.public_description
from public.services s
join (values
  ('power-session',      'Power Session',      'fixed', 15000, 60,  true,  10,
    'Photographer only, 1 location, 3 edited images, 72-hour delivery. Limited-release session.'),
  ('essential-portrait',  'Essential Portrait', 'fixed', 20000, 60,  false, 20,
    'Up to 1 look, 1 location, 5 edited images.'),
  ('signature-portrait',  'Signature Portrait', 'fixed', 30000, 90,  false, 30,
    'Up to 3 looks, 10 edited images.'),
  ('editorial-experience','Editorial Experience','fixed', 45000, 120, false, 40,
    'Up to 4 looks, 15 edited images, enhanced creative direction / editorial treatment.')
) as v(slug, name, pricing_type, retail_price_cents, duration_minutes, is_limited_release, sort_order, public_description)
  on true
where s.slug = 'portraits-milestones'
on conflict (service_id, slug) do update set
  name = excluded.name,
  pricing_type = excluded.pricing_type,
  retail_price_cents = excluded.retail_price_cents,
  duration_minutes = excluded.duration_minutes,
  is_limited_release = excluded.is_limited_release,
  is_active = excluded.is_active,
  is_bookable = excluded.is_bookable,
  sort_order = excluded.sort_order,
  public_description = excluded.public_description;

-- ---------------------------------------------------------------------
-- Service packages: Studio Rental
-- ---------------------------------------------------------------------
insert into public.service_packages
  (service_id, slug, name, pricing_type, retail_price_cents, unit_label,
   duration_minutes, is_active, is_bookable, sort_order, public_description)
select s.id, v.slug, v.name, v.pricing_type::public.pricing_type, v.retail_price_cents,
       v.unit_label, v.duration_minutes, true, true, v.sort_order, v.public_description
from public.services s
join (values
  ('hourly',   'Hourly Studio Rental', 'hourly', 6500,  'per hour', null::integer, 10, 'Studio rental billed per hour.'),
  ('half-day', 'Half-Day Studio Rental','fixed',  25000, null,       240,           20, 'Up to 4 hours.'),
  ('full-day', 'Full-Day Studio Rental','fixed',  50000, null,       480,           30, 'Up to 8 hours.')
) as v(slug, name, pricing_type, retail_price_cents, unit_label, duration_minutes, sort_order, public_description)
  on true
where s.slug = 'studio-rental'
on conflict (service_id, slug) do update set
  name = excluded.name,
  pricing_type = excluded.pricing_type,
  retail_price_cents = excluded.retail_price_cents,
  unit_label = excluded.unit_label,
  duration_minutes = excluded.duration_minutes,
  is_active = excluded.is_active,
  is_bookable = excluded.is_bookable,
  sort_order = excluded.sort_order,
  public_description = excluded.public_description;

-- ---------------------------------------------------------------------
-- Service packages: Events
-- ---------------------------------------------------------------------
insert into public.service_packages
  (service_id, slug, name, pricing_type, retail_price_cents, unit_label,
   minimum_units, is_active, is_bookable, sort_order, public_description)
select s.id, 'hourly', 'Event Coverage', 'hourly'::public.pricing_type, 12500, 'per hour',
       3, true, true, 10, '3-hour minimum. Full event coverage, 72-hour delivery, private online gallery.'
from public.services s
where s.slug = 'events'
on conflict (service_id, slug) do update set
  name = excluded.name,
  pricing_type = excluded.pricing_type,
  retail_price_cents = excluded.retail_price_cents,
  unit_label = excluded.unit_label,
  minimum_units = excluded.minimum_units,
  is_active = excluded.is_active,
  is_bookable = excluded.is_bookable,
  sort_order = excluded.sort_order,
  public_description = excluded.public_description;

-- ---------------------------------------------------------------------
-- Service packages: Corporate & Commercial
-- ---------------------------------------------------------------------
insert into public.service_packages
  (service_id, slug, name, pricing_type, retail_price_cents, duration_minutes,
   is_active, is_bookable, sort_order, public_description)
select s.id, v.slug, v.name, v.pricing_type::public.pricing_type, v.retail_price_cents,
       v.duration_minutes, true, true, v.sort_order, v.public_description
from public.services s
join (values
  ('half-day', 'Half Day', 'starting_at', 75000,  240, 10, 'Up to 4 hours. Commercial usage/licensing quoted separately.'),
  ('full-day', 'Full Day', 'starting_at', 125000, 480, 20, 'Up to 8 hours. Commercial usage/licensing quoted separately.')
) as v(slug, name, pricing_type, retail_price_cents, duration_minutes, sort_order, public_description)
  on true
where s.slug = 'corporate-commercial'
on conflict (service_id, slug) do update set
  name = excluded.name,
  pricing_type = excluded.pricing_type,
  retail_price_cents = excluded.retail_price_cents,
  duration_minutes = excluded.duration_minutes,
  is_active = excluded.is_active,
  is_bookable = excluded.is_bookable,
  sort_order = excluded.sort_order,
  public_description = excluded.public_description;

-- ---------------------------------------------------------------------
-- Service packages: Creative Direction & Production
-- ---------------------------------------------------------------------
insert into public.service_packages
  (service_id, slug, name, pricing_type, retail_price_cents, unit_label,
   duration_minutes, minimum_units, is_active, is_bookable, sort_order, public_description)
select s.id, v.slug, v.name, v.pricing_type::public.pricing_type, v.retail_price_cents,
       v.unit_label, v.duration_minutes, v.minimum_units, true, v.is_bookable, v.sort_order, v.public_description
from public.services s
join (values
  ('hourly',          'Hourly Direction',        'hourly',       10000, 'per hour', null::integer, 2::numeric, true,  10, '2-hour minimum.'),
  ('half-day',        'Half Day',                'starting_at',  50000, null,       240,           null,       true,  20, 'Up to 4 hours.'),
  ('full-day',        'Full Day',                'starting_at',  90000, null,       480,           null,       true,  30, 'Up to 8 hours.'),
  ('team-campaign',   'Team / Campaign Production','custom_quote', null, null,      null,           null,       true,  40, 'Custom quote required -- selectable now; routes to a quote workflow instead of computed checkout.')
) as v(slug, name, pricing_type, retail_price_cents, unit_label, duration_minutes, minimum_units, is_bookable, sort_order, public_description)
  on true
where s.slug = 'creative-direction-production'
on conflict (service_id, slug) do update set
  name = excluded.name,
  pricing_type = excluded.pricing_type,
  retail_price_cents = excluded.retail_price_cents,
  unit_label = excluded.unit_label,
  duration_minutes = excluded.duration_minutes,
  minimum_units = excluded.minimum_units,
  is_active = excluded.is_active,
  is_bookable = excluded.is_bookable,
  sort_order = excluded.sort_order,
  public_description = excluded.public_description;

-- ---------------------------------------------------------------------
-- Service packages: Real Estate Media
-- Deliverable definitions (sq ft, image counts, Standard vs Luxury
-- scope) remain unresolved and are NOT invented here — only the
-- approved starting prices are seeded.
-- ---------------------------------------------------------------------
insert into public.service_packages
  (service_id, slug, name, pricing_type, retail_price_cents,
   is_active, is_bookable, sort_order, public_description)
select s.id, v.slug, v.name, v.pricing_type::public.pricing_type, v.retail_price_cents,
       true, true, v.sort_order, v.public_description
from public.services s
join (values
  ('standard-property', 'Standard Property', 'starting_at', 35000, 10, 'Final pricing depends on scope.'),
  ('luxury-property',   'Luxury Property',   'starting_at', 65000, 20, 'Final pricing depends on scope.')
) as v(slug, name, pricing_type, retail_price_cents, sort_order, public_description)
  on true
where s.slug = 'real-estate-media'
on conflict (service_id, slug) do update set
  name = excluded.name,
  pricing_type = excluded.pricing_type,
  retail_price_cents = excluded.retail_price_cents,
  is_active = excluded.is_active,
  is_bookable = excluded.is_bookable,
  sort_order = excluded.sort_order,
  public_description = excluded.public_description;

-- ---------------------------------------------------------------------
-- Service add-ons
-- Post-production add-ons are priced/bookable. Real Estate media
-- add-ons (Videography, Drone, Mic/Audio) are pricing_type='unpriced'
-- and NOT bookable — Posterchild has not yet approved a customer-facing
-- price/scope for any of them. This is distinct from custom_quote,
-- which means an offering is INTENTIONALLY sold through a quote
-- workflow (see Team/Campaign under Creative Direction & Production,
-- which is custom_quote and IS bookable).
-- Only Videography's internal production-cost FLOOR is recorded
-- (production_cost_cents), and it is never selected by any public view.
-- "Extra edited images / extra production hours / extra studio time"
-- are NOT seeded here — no name, scope, or price has ever been
-- approved for them, so there is nothing non-speculative to insert.
-- ---------------------------------------------------------------------
insert into public.service_addons
  (slug, name, applicable_service_id, pricing_type, retail_price_cents, unit_label,
   production_cost_cents, requires_approval, is_active, is_bookable, sort_order, public_description)
values
  ('photo-retouching',    'Photo Retouching',     null, 'per_unit', 4000, 'per image', null, false, true, true, 10,
    'Custom gallery pricing available.'),
  ('video-editing',       'Video Editing',        null, 'hourly',   10000, 'per hour', null, false, true, true, 20,
    'Flat project pricing available based on scope.'),
  ('additional-revisions','Additional Revisions', null, 'hourly',   10000, 'per hour', null, false, true, true, 30,
    'One-hour minimum after included revisions are exhausted.')
on conflict (slug) do update set
  name = excluded.name,
  applicable_service_id = excluded.applicable_service_id,
  pricing_type = excluded.pricing_type,
  retail_price_cents = excluded.retail_price_cents,
  unit_label = excluded.unit_label,
  production_cost_cents = excluded.production_cost_cents,
  requires_approval = excluded.requires_approval,
  is_active = excluded.is_active,
  is_bookable = excluded.is_bookable,
  sort_order = excluded.sort_order,
  public_description = excluded.public_description;

insert into public.service_addons
  (slug, name, applicable_service_id, pricing_type, retail_price_cents,
   production_cost_cents, requires_approval, is_active, is_bookable, sort_order, public_description, internal_notes)
select 'real-estate-videography', 'Property Video', s.id, 'unpriced', null,
       25000, false, true, false, 10,
       'Dedicated property video. Customer-facing pricing not yet approved.',
       'Internal production-cost floor: $250/hr videographer cost. NEVER expose this figure or vendor identity publicly.'
from public.services s where s.slug = 'real-estate-media'
on conflict (slug) do update set
  name = excluded.name,
  applicable_service_id = excluded.applicable_service_id,
  pricing_type = excluded.pricing_type,
  retail_price_cents = excluded.retail_price_cents,
  production_cost_cents = excluded.production_cost_cents,
  requires_approval = excluded.requires_approval,
  is_active = excluded.is_active,
  is_bookable = excluded.is_bookable,
  sort_order = excluded.sort_order,
  public_description = excluded.public_description,
  internal_notes = excluded.internal_notes;

insert into public.service_addons
  (slug, name, applicable_service_id, pricing_type, retail_price_cents,
   requires_approval, is_active, is_bookable, sort_order, public_description)
select 'real-estate-drone', 'Drone Coverage', s.id, 'unpriced', null,
       true, true, false, 20,
       'Availability depends on location, airspace restrictions, weather, and operator availability. Customer-facing pricing not yet approved.'
from public.services s where s.slug = 'real-estate-media'
on conflict (slug) do update set
  name = excluded.name,
  applicable_service_id = excluded.applicable_service_id,
  pricing_type = excluded.pricing_type,
  retail_price_cents = excluded.retail_price_cents,
  requires_approval = excluded.requires_approval,
  is_active = excluded.is_active,
  is_bookable = excluded.is_bookable,
  sort_order = excluded.sort_order,
  public_description = excluded.public_description;

insert into public.service_addons
  (slug, name, applicable_service_id, pricing_type, retail_price_cents,
   requires_approval, is_active, is_bookable, sort_order, public_description)
select 'real-estate-mic-audio', 'Professional Mic / On-Camera Audio', s.id, 'unpriced', null,
       false, true, false, 30,
       'Professional audio capture for on-camera narration, interviews, or spoken content. Customer-facing pricing not yet approved.'
from public.services s where s.slug = 'real-estate-media'
on conflict (slug) do update set
  name = excluded.name,
  applicable_service_id = excluded.applicable_service_id,
  pricing_type = excluded.pricing_type,
  retail_price_cents = excluded.retail_price_cents,
  requires_approval = excluded.requires_approval,
  is_active = excluded.is_active,
  is_bookable = excluded.is_bookable,
  sort_order = excluded.sort_order,
  public_description = excluded.public_description;

-- ---------------------------------------------------------------------
-- Products: a la carte prints
-- ---------------------------------------------------------------------
insert into public.products (slug, name, category, pricing_type, retail_price_cents, is_active, is_purchasable, sort_order, public_description)
values
  ('print-4x6', '4x6 Premium Print', 'a_la_carte_print', 'fixed', 800,  true, true, 10, null),
  ('print-5x7', '5x7 Premium Print', 'a_la_carte_print', 'fixed', 1500, true, true, 20, null),
  ('print-6x8', '6x8 Premium Print', 'a_la_carte_print', 'fixed', 1800, true, true, 30, null),
  ('print-8x8', '8x8 Premium Print', 'a_la_carte_print', 'fixed', 2000, true, true, 40, null),
  ('print-8x10','8x10 Premium Print','a_la_carte_print', 'fixed', 2500, true, true, 50, null),
  ('wallet-print-set', 'Wallet Print Set', 'a_la_carte_print', 'fixed', 1000, true, false, 60,
    'Quantity per set to be confirmed before this product is purchasable.')
on conflict (slug) do update set
  name = excluded.name,
  category = excluded.category,
  pricing_type = excluded.pricing_type,
  retail_price_cents = excluded.retail_price_cents,
  is_active = excluded.is_active,
  is_purchasable = excluded.is_purchasable,
  sort_order = excluded.sort_order,
  public_description = excluded.public_description;

-- ---------------------------------------------------------------------
-- Products: print collections
-- Story Collection and Gallery Collection are seeded with their
-- approved starting-at price ONLY — no component contents are created,
-- and both are explicitly not purchasable.
-- ---------------------------------------------------------------------
insert into public.products (slug, name, category, pricing_type, retail_price_cents, is_active, is_purchasable, sort_order, public_description)
values
  ('keepsake-collection', 'The Keepsake',           'print_collection', 'fixed',       3500,  true, true,  10, '2x 5x7 prints, 1x 8x10 print.'),
  ('signature-collection','The Signature',          'print_collection', 'fixed',       6000,  true, true,  20, '2x 5x7 prints, 2x 8x10 prints.'),
  ('story-collection',    'The Story Collection',   'print_collection', 'starting_at', 9500,  true, false, 30, 'Contents to be finalized — statement print size/configuration pending.'),
  ('gallery-collection',  'The Gallery Collection', 'print_collection', 'starting_at', 15000, true, false, 40, 'Contents to be finalized.')
on conflict (slug) do update set
  name = excluded.name,
  category = excluded.category,
  pricing_type = excluded.pricing_type,
  retail_price_cents = excluded.retail_price_cents,
  is_active = excluded.is_active,
  is_purchasable = excluded.is_purchasable,
  sort_order = excluded.sort_order,
  public_description = excluded.public_description;

insert into public.product_collection_items (collection_product_id, included_product_id, quantity)
select c.id, i.id, q.quantity
from (values
  ('keepsake-collection', 'print-5x7', 2),
  ('keepsake-collection', 'print-8x10', 1),
  ('signature-collection', 'print-5x7', 2),
  ('signature-collection', 'print-8x10', 2)
) as q(collection_slug, included_slug, quantity)
join public.products c on c.slug = q.collection_slug
join public.products i on i.slug = q.included_slug
on conflict (collection_product_id, included_product_id) do update set
  quantity = excluded.quantity;

-- ---------------------------------------------------------------------
-- Products: wall art
-- All starting-at, all NOT purchasable — no size x price variant
-- matrix has been approved. Displayed publicly as starting-at tiles.
-- ---------------------------------------------------------------------
insert into public.products (slug, name, category, pricing_type, retail_price_cents, is_active, is_purchasable, sort_order)
values
  ('wall-art-tilepix',        'TilePix',              'wall_art', 'starting_at', 4500,  true, false, 10),
  ('wall-art-wood-panel',     'Wood Panel',           'wall_art', 'starting_at', 5500,  true, false, 20),
  ('wall-art-standard-canvas','Standard Canvas',      'wall_art', 'starting_at', 8500,  true, false, 30),
  ('wall-art-framed-print',   'Framed Print',         'wall_art', 'starting_at', 11000, true, false, 40),
  ('wall-art-floating-frame', 'Floating Frame',       'wall_art', 'starting_at', 11000, true, false, 50),
  ('wall-art-framed-matted',  'Framed Matted Print',  'wall_art', 'starting_at', 12500, true, false, 60),
  ('wall-art-framed-canvas',  'Framed Canvas',        'wall_art', 'starting_at', 13500, true, false, 70)
on conflict (slug) do update set
  name = excluded.name,
  category = excluded.category,
  pricing_type = excluded.pricing_type,
  retail_price_cents = excluded.retail_price_cents,
  is_active = excluded.is_active,
  is_purchasable = excluded.is_purchasable,
  sort_order = excluded.sort_order;

-- ---------------------------------------------------------------------
-- Products: photo books
-- Mini Memory Book intentionally has no variants: the 4x4/4x6 choice
-- carries an identical locked price, noted in the description only.
-- ---------------------------------------------------------------------
insert into public.products (slug, name, category, pricing_type, retail_price_cents, is_active, is_purchasable, sort_order, public_description)
values
  ('mini-memory-book',    'Mini Memory Book',              'photo_book', 'fixed', 3500,  true, true, 10, '4x4 or 4x6, softcover / compact format.'),
  ('classic-photo-book',  'Classic Photo Book',            'photo_book', 'fixed', 8500,  true, true, 20, '8.5x11, 20 pages, standard format.'),
  ('signature-layflat-book','Signature Layflat Book',      'photo_book', 'fixed', 11000, true, true, 30, '8.5x11, 20 pages, layflat presentation.'),
  ('editorial-custom-cover-book','Editorial Custom-Cover Book','photo_book','fixed', 13500, true, true, 40, '8.5x11, 20 pages, custom-cover presentation.')
on conflict (slug) do update set
  name = excluded.name,
  category = excluded.category,
  pricing_type = excluded.pricing_type,
  retail_price_cents = excluded.retail_price_cents,
  is_active = excluded.is_active,
  is_purchasable = excluded.is_purchasable,
  sort_order = excluded.sort_order,
  public_description = excluded.public_description;

insert into public.products (slug, name, category, pricing_type, retail_price_cents, unit_label, is_active, is_purchasable, sort_order, public_description)
values
  ('additional-book-pages', 'Additional Book Pages', 'book_addon', 'per_unit', 1000, 'per 2-page spread', true, true, 50, 'No maximum page count is defined; a future cap is a configurable rule, not a hard-coded limit.')
on conflict (slug) do update set
  name = excluded.name,
  category = excluded.category,
  pricing_type = excluded.pricing_type,
  retail_price_cents = excluded.retail_price_cents,
  unit_label = excluded.unit_label,
  is_active = excluded.is_active,
  is_purchasable = excluded.is_purchasable,
  sort_order = excluded.sort_order,
  public_description = excluded.public_description;
