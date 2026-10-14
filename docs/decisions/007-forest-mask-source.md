# 007 — The pre-interval forest mask defaults to Hansen GFC, with C-CAP held for comparison

**Date:** 2026-10-14
**Status:** Accepted (provisional — no comparison run yet)
**Bears on:** §2.11 pre-interval land cover mask, §3.2 forest type
classification, [covariates-plan.md](../covariates-plan.md)

## Decision

The forest/non-forest mask is built from Hansen Global Forest Change: forest
where `treecover2000` is at or above a threshold (30% as a placeholder, chosen
at analysis time) and `lossyear` records no loss through 2016. NOAA C-CAP for
Puerto Rico 2010 — the only vintage before Maria — is downloaded alongside it and
compared later. The mask and the forest-type classification come from separate
products: the mask needs recency, forest type needs ecologically meaningful
classes, and one product does not serve both.

## Alternatives considered

*PR GAP land cover (~2000) as both mask and forest type.* One product, internally
consistent. Rejected as the mask because it leaves 17 years of land-use change
before the 2017 acquisitions unmasked. It remains a forest-type candidate.

*C-CAP alone.* Captures regrowth up to its vintage (2010, if that is the latest),
but misses clearing between then and 2017.

*Union of C-CAP and Hansen 2000, minus Hansen loss through 2016.* Closes both
holes at the cost of a composite rule to defend in the methods. Deferred: both
inputs are downloaded, so this can be built if the comparison shows it is needed.

*10 m post-2017 products (ESA WorldCover, Esri/Impact Observatory annual).*
Rejected under §2.11: a post-Maria classification labels defoliated forest as
non-forest and removes the most heavily damaged pixels.

## Evidence

None measured yet. The known weakness is structural: Hansen's baseline is 2000
and it records gain poorly (the gain layer covers only 2000–2012). Puerto Rico
has been reforesting through farm abandonment, so a Hansen-only mask will label
young secondary forest that closed after 2000 as non-forest — biasing the sample
toward older stands within every forest type.

## Consequences

The Hansen/C-CAP comparison should quantify how much forest the default mask
drops that C-CAP calls forest, and where. If that area is substantial or
concentrated in particular forest types, switch to the union rule. The
threshold choice needs checking against south-coast dry forest, whose open
canopy may fall below 30% cover.
