// catalog.js
//
// Posterchild Media -- Stage 3B catalog data foundation.
//
// Loads the six public, RLS-safe Supabase catalog views (read-only,
// anon-key access -- see supabase/migrations/001_foundation_catalog.sql)
// into a small normalized in-memory shape for the future booking wizard
// (Stage 3C+). Nothing in this file touches the DOM, replaces an
// existing booking.html global, or auto-runs on page load -- it is
// purely a reusable loader that Stage 3C will call explicitly. Until
// then, including this script has zero effect on the current page.
//
// POSTERCHILD_SUPABASE_URL and POSTERCHILD_SUPABASE_ANON_KEY are public,
// browser-safe identifiers by Supabase's own design -- protection is
// enforced entirely by RLS and the explicit view grants audited in
// Migration 001, not by keeping these values secret. Never place a
// service-role key, database URL, or any Edge Function secret in this
// file.

const POSTERCHILD_SUPABASE_URL = 'https://xbtitaawwslmibfvndxu.supabase.co';
const POSTERCHILD_SUPABASE_ANON_KEY = 'sb_publishable_9RIbU59AyXdhv0whvcFmKw_XrK8a6y6';

const POSTERCHILD_CATALOG_VIEWS = [
  'public_services',
  'public_service_packages',
  'public_service_addons',
  'public_products',
  'public_product_variants',
  'public_product_collection_items',
];

async function fetchPosterchildCatalogView(view) {
  const res = await fetch(`${POSTERCHILD_SUPABASE_URL}/rest/v1/${view}?select=*`, {
    headers: {
      apikey: POSTERCHILD_SUPABASE_ANON_KEY,
      Authorization: `Bearer ${POSTERCHILD_SUPABASE_ANON_KEY}`,
    },
  });
  if (!res.ok) {
    throw new Error(`catalog view ${view} responded with ${res.status}`);
  }
  return res.json();
}

function groupBy(rows, key) {
  const out = {};
  for (const row of rows) {
    const k = row[key];
    if (k === null || k === undefined) continue;
    (out[k] = out[k] || []).push(row);
  }
  return out;
}

function indexBy(rows, key) {
  const out = {};
  for (const row of rows) out[row[key]] = row;
  return out;
}

/**
 * Normalizes the six raw view responses into lookup-friendly shape.
 * Every field is passed through unchanged from the public catalog views
 * -- no pricing, duration, or other business value is invented or
 * recomputed here.
 */
function normalizePosterchildCatalog(raw) {
  const [services, servicePackages, serviceAddons, products, productVariants, productCollectionItems] = raw;

  return {
    services,
    servicesById: indexBy(services, 'id'),
    servicesBySlug: indexBy(services, 'slug'),
    servicePackages,
    packagesByServiceId: groupBy(servicePackages, 'service_id'),
    serviceAddons,
    // Add-ons with applicable_service_id === null apply generally
    // (Photo Retouching, Video Editing, Additional Revisions) and are
    // kept in their own bucket rather than attached to every service,
    // since they are not actually service-specific rows.
    addonsByApplicableServiceId: groupBy(
      serviceAddons.filter((a) => a.applicable_service_id !== null),
      'applicable_service_id',
    ),
    generalAddons: serviceAddons.filter((a) => a.applicable_service_id === null),
    products,
    productsById: indexBy(products, 'id'),
    productsBySlug: indexBy(products, 'slug'),
    productsByCategory: groupBy(products, 'category'),
    productVariants,
    variantsByProductId: groupBy(productVariants, 'product_id'),
    productCollectionItems,
    collectionItemsByCollectionProductId: groupBy(productCollectionItems, 'collection_product_id'),
  };
}

/**
 * Loads and normalizes the full public catalog. Resolves to `null` on
 * any failure (network error, non-2xx response, malformed JSON) instead
 * of rejecting -- callers must treat `null` as "catalog unavailable
 * right now" and degrade gracefully. Never logs response bodies,
 * request headers, or the anon key; only a fixed, generic warning.
 */
async function loadPosterchildCatalog() {
  try {
    const raw = await Promise.all(POSTERCHILD_CATALOG_VIEWS.map(fetchPosterchildCatalogView));
    return normalizePosterchildCatalog(raw);
  } catch (err) {
    console.warn('[posterchild-catalog] catalog load failed; continuing without it');
    return null;
  }
}

// Exposed for Stage 3C to call explicitly (e.g.
// `const catalog = await window.loadPosterchildCatalog();`). Not
// auto-invoked here -- the current booking.html has no consumer for
// this data yet, and firing six extra network requests on every legacy
// page load with nothing to show for it would be an unrequested
// behavior change.
window.loadPosterchildCatalog = loadPosterchildCatalog;
