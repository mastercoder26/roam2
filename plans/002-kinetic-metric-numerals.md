# 002 — Give hero metrics rolling depth

- **Status**: DONE
- **Commit**: 7f3a4b7
- **Severity**: MEDIUM
- **Category**: Missed opportunitiessd
- **Estimated scope**: 4 files, ~130 lines

## Problem

Pusher's central count is a large rolling numeral with a soft mirrored echo,
while Roam's most important completed-result values use a plain numeric crossfade:

```swift
// ios/Roam/Components/ScoreGaugeView.swift — current
Text(String(format: "%.1f", score))
    .contentTransition(.numericText())
```

## Target

Create a reusable `KineticMetricText` that keeps SwiftUI's interruptible
`numericText` transition, adds a vertically flipped reflection limited by a
short gradient mask, and applies a brief blur of at most 2px while a value
settles. The score may use the full entrance treatment because it appears
rarely. Off-drive measured mileage uses the quieter version. Live speed is
explicitly excluded so a frequent safety-critical update never becomes
distracting. Reduce Motion uses an immediate value change with no reflection.

## Repo conventions to follow

- Use `AppAnimation` tokens and monospaced rounded system numerals.
- Preserve existing accessibility labels that speak score and speed.
- Keep animation to transform, opacity, and blur below 20px.

## Steps

1. Add shared kinetic-number motion constants with separate hero/live variants.
2. Build `KineticMetricText` in `DesignSystem.swift`.
3. Use the hero treatment in `ScoreGaugeView` without changing the ring semantics.
4. Use the quieter treatment for off-drive measured mileage in Profile.
5. Add pure checks for bounded blur, reflection opacity, and reduced-motion behavior.

## Boundaries

- Do NOT replace the split-flap timer.
- Do NOT animate dashboard rows or every small number in the app.
- Do NOT apply blur, reflection, or added feedback to live speed updates.

## Verification

- **Mechanical**: targeted checks and iPhone simulator build pass.
- **Feel check**: inspect a Results score reveal and Profile measured mileage. The reflection must feel like depth, not duplicated text. Reduce Motion must show stable numbers.
- **Done when**: completed-result metrics share a coherent numeric language without affecting the active-drive surface or split-flap timer.
