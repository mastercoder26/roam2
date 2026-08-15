# Handoff — design overhaul + codebase cleanup (2026-08-08)

Two things are happening in this effort: a visual overhaul of every tab, and a
cleanup pass to strip machine-generated residue out of the source and the root
docs. Functionality is explicitly out of scope — no state logic, network calls,
computed values, or accessibility labels change.

## Design direction

The app read as competent but flat: every screen was a vertical stack of
identically-weighted `premiumCard()` blocks on a canvas, each with a 1px stroke,
and no element on any screen claimed to be the important one. Target is the
vocabulary large consumer apps use — Uber Eats and Airbnb were the reference
points:

- One hero surface per screen instead of uniform card weight
- Shadow-forward elevation, hairline strokes only where a border does work
- A real type hierarchy with a large tight display face at the top
- Number-first metric grids in place of long label/value lists
- Pill badges and selectable chips instead of inline prose for status
- Illustrated empty states and skeleton placeholders

### Foundation — done, committed

`ios/Roam/Utilities/DesignSystem.swift` was rewritten first so the screen work
had something to build on. Everything previously exported is still exported, so
existing call sites compile untouched. Added:

| Addition | Purpose |
|---|---|
| `Typography.display` / `railTitle` / `microLabel` | 34pt tight display face, carousel headers, all-caps micro-labels |
| `cornerRadiusHero` (28), `Elevation.hero` | Focal surfaces |
| `space2`, `space32`, `tabBarClearance` | Missing rungs the code was faking with literals |
| `accentWash` | Gradient behind hero surfaces |
| `.heroCard()`, `.surfaceFrame(radius:elevated:)` | Featured surface; rounded frame for content that pads itself (maps, charts) |
| `HeroCardModifier`, `RailHeader`, `StatusBadge`, `FilterChip`, `MetricTile`, `SkeletonBlock`, `EmptyStateView`, `SecondaryActionButton` | Shared components the screens were each hand-rolling |
| `ScreenHeader(subtitle:)`, `IconTile(size:)` | Additive params on existing views |

Radius ladder moved up (`cornerRadius` 16 → 18, large 20 → 24) and stroke widths
dropped to 0.75 where a card also carries a shadow. `Elevation` tiers got
larger, softer radii.

Commit: `refactor(ios): expand design tokens and shared components`.

### Screens — five agents in flight

Split across disjoint file sets so they can't collide. Each was told to use only
existing tokens, keep the `@ObservedObject private var theme = ThemeManager.shared`
invalidation pattern, and verify with a real `xcodebuild` before finishing.

| Scope | Files |
|---|---|
| Routes / Home | `Features/Home/HomeView.swift`, `Components/AddressSearchField.swift` |
| Results | `Features/Results/ResultsView.swift`, `ResultsSupportingViews.swift` |
| Drive | `Features/Drive/DriveView.swift`, `DriveDetailViews.swift`, `DrivePlanningSupportingViews.swift` |
| Progress + Profile | `Features/Progress/DriverProgressView.swift`, `Features/Profile/ProfileView.swift`, `ProfileSupportingViews.swift` |
| Shared components | `Components/ScoreGaugeView.swift`, `AlternateRouteCard.swift`, `RouteEvidenceCard.swift`, `RouteAnalysisLoadingView.swift` |

`DesignSystem.swift`, `Theme.swift`, `AnimationConstants.swift`, `RouteMapView.swift`
and everything under `Services/` were fenced off from all five.

The components agent was additionally barred from changing any initializer
signature or property name on those four views, since the screens that call them
were being edited at the same time.

Three specific density problems were called out as targets, all previously
recorded in `FINDINGS.md`:

1. `ResultsView` is one flat scroll of up to eleven stacked cards; the readiness
   card alone nests a summary, a history block, an expandable insight list, a
   practice plan, a CTA and a disclaimer.
2. `DriverProgressView.overallScoreCard` carries seven pieces of information
   about a single number.
3. Progress and Profile visibly duplicate metrics — after-dark miles, 45+ mph
   miles, longest continuous trace, the eight-week chart, the /100 score.

Note that (3) is an information-architecture question, not a layout one. If it
still looks duplicated after this pass, it needs a product decision about which
tab owns those metrics, not more styling.

## Cleanup pass

### Source comments

The dominant machine-generated tell in this codebase is not comment volume, it
is comment *register*: comments that argue with a previous revision instead of
explaining the code. `deliberately` appears 37 times across `ios/` and
`backend/`; there are dozens of variants of "The old implementation used…",
"Replaces `Color(.systemGray3)`…", "which crashed launch", "A real rung on the
ladder, not an ad-hoc literal", "Do not delete it as unused".

Rule applied: a comment earns its place by explaining something non-obvious
about the code as it stands. It does not narrate the diff that produced it, and
it does not defend a choice against an alternative the reader can't see.
`DesignSystem.swift` has been converted; the rest of `Models/`, `Services/` and
`backend/src/` still need the same pass.

### Root docs

Four overlapping status files at the repository root — `FINDINGS.md`,
`HANDOFF.md`, `REMAINING.md`, `TODO.md`, 752 lines total — each written as a
per-session narrative, with the same open items restated in three of them.

Durable content has been extracted:

- `docs/deployment.md` — split-backend topology, the reason it's split, both
  deploy paths, the Cloud Run migration hazard, local setup.
- `TODO.md` — rewritten as deduplicated open items under Blocking / Before
  production / Verification / Nice to have / Known bounds.

The original four are still present and unmodified apart from `TODO.md`. Merging
or removing them is the obvious next step but wasn't taken.

`README.md` is stale independently of any of this: it still documents Render as a
single combined deploy target and references `JWT_SECRET`, which the Clerk
migration removed. It also runs long in the same explanatory register as the
comments, and claims eighteen checks against a table that should be verified
against `ios/tests/`.

## Verification

- `npm test --prefix backend` — 132 passing across 18 files, run on the
  foundation commit via the pre-push hook
- `tsc --noEmit` — clean
- `xcodebuild -scheme Roam -destination 'platform=iOS Simulator,name=iPhone 17'`
  — each screen agent runs this itself; a full build over all five merged
  results still has to be run before this work is trusted

`ios/tests/run-checks.sh` covers the pure engines, none of which this effort
touches, so it isn't a meaningful signal here.

SourceKit reports phantom errors on single files in this project — "Cannot find
'ThemeManager' in scope", "No such module 'UIKit'". They're an indexing artifact
of reading a file without the project context and don't reproduce under
`xcodebuild`. Trust the build, not the editor diagnostics.

## Next

1. Collect the five agent results, merge, run one full `xcodebuild`.
2. Screenshot every tab in the simulator. Nothing here has been looked at yet —
   a clean build says the layout compiles, not that it looks right.
3. Finish the comment register pass across `Models/`, `Services/`, `backend/src/`.
4. Rewrite `README.md`, and decide whether `FINDINGS.md` / `HANDOFF.md` /
   `REMAINING.md` fold into `docs/` or go.
