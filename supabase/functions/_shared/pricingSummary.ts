// supabase/functions/_shared/pricingSummary.ts
//
// Computes a safe, non-fabricated pricing summary for a hold-creation
// response, using catalog values only -- this does not redesign pricing.
// A total is returned only when the catalog's pricing_type and the
// already-validated request unambiguously determine one:
//   fixed        -> exact total
//   hourly       -> total, but only using validatedHourUnits from
//                   bookingPolicy.validateRequestedDuration (never a
//                   guessed/rounded duration)
//   starting_at  -> a floor, explicitly never presented as a total
//   custom_quote -> no figure at all
//   per_unit / hourly add-ons -> unit price only, since the current
//                   request shape carries no per-add-on quantity
//   unpriced     -> structurally unreachable here (unpriced items are
//                   never is_bookable, so validation rejects them first)
//
// Every branch below throws rather than fabricates a shape if a schema
// invariant it depends on turns out to be violated -- e.g. a 'fixed'
// row with a NULL retail_price_cents should never exist given
// Migration 001's own CHECK constraints, but if it somehow did, this
// module refuses to guess rather than silently emitting a wrong price.

export type CatalogPricingType =
  | "fixed"
  | "hourly"
  | "starting_at"
  | "custom_quote"
  | "per_unit"
  | "unpriced";

export interface PackagePricingInput {
  pricingType: CatalogPricingType;
  retailPriceCents: number | null;
  currency: string;
  unitLabel: string | null;
  validatedHourUnits: number | null;
}

export interface AddonPricingInput {
  id: string;
  pricingType: CatalogPricingType;
  retailPriceCents: number | null;
  currency: string;
  unitLabel: string | null;
}

export type PackagePricingSummary =
  | { type: "fixed"; currency: string; total_cents: number }
  | {
      type: "hourly";
      currency: string;
      unit_price_cents: number;
      unit_label: string | null;
      units: number;
      total_cents: number;
    }
  | { type: "starting_at"; currency: string; starting_at_cents: number }
  | { type: "custom_quote" };

export type AddonPricingSummary =
  | { id: string; type: "fixed"; currency: string; total_cents: number }
  | { id: string; type: "hourly"; currency: string; unit_price_cents: number; unit_label: string | null }
  | { id: string; type: "starting_at"; currency: string; starting_at_cents: number }
  | { id: string; type: "custom_quote" }
  | { id: string; type: "per_unit"; currency: string; unit_price_cents: number; unit_label: string | null };

export function buildPackagePricingSummary(pkg: PackagePricingInput): PackagePricingSummary {
  switch (pkg.pricingType) {
    case "fixed": {
      if (pkg.retailPriceCents === null) {
        throw new Error("catalog_invariant_violated: fixed package missing retail_price_cents");
      }
      return { type: "fixed", currency: pkg.currency, total_cents: pkg.retailPriceCents };
    }
    case "hourly": {
      if (pkg.retailPriceCents === null || pkg.validatedHourUnits === null) {
        throw new Error(
          "catalog_or_validation_invariant_violated: hourly package missing retail_price_cents or validated units",
        );
      }
      return {
        type: "hourly",
        currency: pkg.currency,
        unit_price_cents: pkg.retailPriceCents,
        unit_label: pkg.unitLabel,
        units: pkg.validatedHourUnits,
        total_cents: pkg.retailPriceCents * pkg.validatedHourUnits,
      };
    }
    case "starting_at": {
      if (pkg.retailPriceCents === null) {
        throw new Error("catalog_invariant_violated: starting_at package missing retail_price_cents");
      }
      return { type: "starting_at", currency: pkg.currency, starting_at_cents: pkg.retailPriceCents };
    }
    case "custom_quote":
      return { type: "custom_quote" };
    default:
      // per_unit / unpriced packages are not expected to reach this
      // function: no seeded package uses per_unit, and an unpriced
      // package can never be is_bookable (Migration 001 CHECK).
      throw new Error(`unexpected_package_pricing_type: ${pkg.pricingType}`);
  }
}

export function buildAddonPricingSummary(addon: AddonPricingInput): AddonPricingSummary {
  switch (addon.pricingType) {
    case "fixed":
      if (addon.retailPriceCents === null) {
        throw new Error("catalog_invariant_violated: fixed add-on missing retail_price_cents");
      }
      return { id: addon.id, type: "fixed", currency: addon.currency, total_cents: addon.retailPriceCents };
    case "starting_at":
      if (addon.retailPriceCents === null) {
        throw new Error("catalog_invariant_violated: starting_at add-on missing retail_price_cents");
      }
      return {
        id: addon.id,
        type: "starting_at",
        currency: addon.currency,
        starting_at_cents: addon.retailPriceCents,
      };
    case "custom_quote":
      return { id: addon.id, type: "custom_quote" };
    case "hourly":
      if (addon.retailPriceCents === null) {
        throw new Error("catalog_invariant_violated: hourly add-on missing retail_price_cents");
      }
      // No per-add-on quantity/hours exists in the current request
      // shape -- unit price only, never a fabricated total.
      return {
        id: addon.id,
        type: "hourly",
        currency: addon.currency,
        unit_price_cents: addon.retailPriceCents,
        unit_label: addon.unitLabel,
      };
    case "per_unit":
      if (addon.retailPriceCents === null) {
        throw new Error("catalog_invariant_violated: per_unit add-on missing retail_price_cents");
      }
      // No quantity captured in the current request shape -- unit price only.
      return {
        id: addon.id,
        type: "per_unit",
        currency: addon.currency,
        unit_price_cents: addon.retailPriceCents,
        unit_label: addon.unitLabel,
      };
    case "unpriced":
    default:
      // Structurally unreachable: unpriced add-ons are is_bookable=false
      // and rejected during add-on validation before pricing is ever
      // considered.
      throw new Error(`unexpected_addon_pricing_type: ${addon.pricingType}`);
  }
}
