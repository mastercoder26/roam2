# Roam — open audit findings

Original audit: 4 August 2026, against `19bf5a9`.
Remediation pass: 5 August 2026. All CRITICAL, HIGH, MEDIUM and LOW code
findings from the original audit are now fixed in the working tree.

This file lists what was found and **deliberately not fixed**. Everything that
was fixed is in the working tree, not here.

Verification at time of writing: iOS `** BUILD SUCCEEDED **`; backend 103/103;
**17 of 17** standalone Swift checks pass via `ios/tests/run-checks.sh`.

Accessibility and reduce-motion were excluded from scope throughout.

---

## Coverage warning — read first

One area remains unaudited. Absence of findings below is not evidence of
correctness:

- **Backend scoring arithmetic** (`backend/src/scoring/*.ts`) beyond the
  availability gating that was verified by hand. Mitigating context: this area
  carries 103 passing tests.

---

## Open — accepted bounds, not defects

### Snapshot persistence loses at most 10 s on termination

The 1 Hz timer calls `persistInProgressSnapshot()`, which throttles to once per
10 s, so a termination can still lose up to 10 s of the newest samples. That is
the documented, intended trade-off — recorded here so it is a known bound
rather than a surprise.

---

## Open — structural clutter (copy was tightened; layout was not)

A copy pass unified terminology to the README's vocabulary and removed redundant
text. These four are density problems in the *layout*, which shorter words
cannot fix — each needs a product/IA decision, so none was made mechanically:

1. **`ResultsView` is one very long flat scroll** — up to eleven stacked
   `premiumCard()` sections. The readiness card alone nests a summary, a history
   block, an expandable insight list, a practice plan, a CTA, and a disclaimer.
   Wants grouping or progressive disclosure.
2. **Progress and Profile now visibly duplicate content.** After-dark miles,
   45+ mph miles, longest continuous trace, the eight-week chart, and the /100
   score appear on both tabs. Unifying the labels was the right copy fix, but it
   exposes that neither tab clearly owns these metrics.
3. **`ReadinessHistorySummary`** packs a `·`-joined line plus three label/value
   pairs into an already-nested card — the "8 PM–6 AM" definition had to be
   dropped for space. If that window matters there, the row needs a detail line
   like the Progress coverage rows have.
4. **`DriverProgressView.overallScoreCard`** carries seven pieces of information
   about a single number (icon, title, evidence tier, 40 pt score, progress bar,
   `ViewThatFits` signal row, detail paragraph).

---

## Open — LOW

### Off-ladder spacing literals

The token sweep converted 66 exact-value matches. These near-misses remain
deliberately unconverted because changing them is a design decision, not a
mechanical edit:

- `spacing: 10` — 22 occurrences (between `space8` and `space12`)
- `spacing: 14` — 17 occurrences (between `space12` and `space16`)
- `spacing:` 1, 2, 3, 5, 6, 7, 9, 18, 26, 28 — long tail
- `DriveView.swift:509, :513` — `cornerRadius: 24`; no token exists
  (`cornerRadiusLarge` is 20)

`AppDesign.space4/space16/space24` still have zero uses. The declared 4 pt
ladder and the app's actual 2 pt-granular practice remain unreconciled.

---

## Corrections to the original audit

Recorded so the same ground is not re-litigated:

- The `VerifiedDemandExposure` row of the Decodable finding was cited as
  `DrivingScore.swift:134-146` under the name `DrivingScore`. The type at those
  lines is `VerifiedDemandExposure`; `DrivingScore` itself has no hand-written
  init and was never affected.
- `LayoutResponsivenessChecks` was attributed to a runner gap needing "SwiftUI
  context". It actually asserted `LayoutResponsiveness.usesCompactTabBar`, an
  API removed in `aa3fcc2` when tab bar minimize behavior was reverted. The
  assertions had outlived the API and were deleted; the file's own source
  dependency is `CoreGraphics` only.
- The three checks said to fail "only under an ad-hoc runner" were a runner
  problem, now resolved — see below.

---

## Test runner — resolved

`ios/tests/run-checks.sh` is now in the repo and all seventeen checks are
documented in `README.md`. Every check compiles against one shared source set
declared at the top of the runner. Per-check source lists were the previous
approach and they rotted: a check silently stopped compiling when an engine
gained a dependency, and a missing source read as a broken test rather than a
stale runner. The runner fails loudly on a missing source instead.

---

## Verified clean

Checked and sound — recorded so this ground is not re-audited.

- **Theming.** Zero hardcoded colors in the view layer; every surface resolves
  through `AppDesign` → `ThemeManager.cachedPalette`.
- **Corner-radius ladder.** Genuinely adopted (53 token uses vs 5 literals
  before the sweep).
- **Backend outbound calls.** All four fetches (`google/routes.ts:147`,
  `google/roads.ts:79`, `enrichment/weather.ts:145`, `enrichment/osm.ts:216`)
  are bounded by an `AbortController` timeout.
- **Backend degradation.** `enrichRoute` uses `Promise.allSettled` with
  per-source `available` flags; `neutralConditions()` carries `sources: []`; and
  every demand in `scoring/demands.ts` gates on both before contributing. A
  weather or OSM outage yields reduced coverage, not a confident wrong answer.
- **Request validation.** Strict Zod schemas on both endpoints, bounded lengths,
  finite/ranged coordinates, a correct ISO-8601 validator, duplicate-candidate
  detection, and failures mapped through `publicFailure()` with no internal
  detail leaked.
- **iOS memory/lifecycle.** Two force unwraps total, both safe. Every `Timer`
  and sensor callback uses `[weak self]`.
- **Re-entrancy.** `startDrive()`/`endDrive()` cannot double-enter;
  `DriveLiveActivityManager`'s `requestedDriveID` handshake correctly resolves a
  fast start→end race; CarPlay connect/disconnect does not disturb an active
  recording.
- `ChartContent.cornerRadius` is **not** deprecated — only `View.cornerRadius`
  is. An earlier draft of this file claimed otherwise.
