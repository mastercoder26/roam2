# 001 — Replace the cursive mark with a sliced Roam wordmark

- **Status**: DONE
- **Commit**: 7f3a4b7
- **Severity**: HIGH
- **Category**: Cohesion & tokens
- **Estimated scope**: 4 files, ~140 lines

## Problem

The permanent header and launch handoff use a conventional italic serif mark,
while the requested Pusher reference uses a heavy sans wordmark split into
slightly displaced horizontal bands. The current mark is defined twice:

```swift
// ios/Roam/Utilities/DesignSystem.swift — current
Text("Roam")
    .font(.custom("Baskerville-SemiBoldItalic", size: 23))
```

```swift
// ios/Roam/Features/Root/LaunchIntroView.swift — current
Text("Roam")
    .font(.custom("Baskerville-SemiBoldItalic", size: choreography.wordmarkHeroFontSize))
```

## Target

Create one reusable heavy system-sans `RoamWordmark` drawn in four horizontal
bands. Each band covers part of the full glyph height and offsets horizontally
by no more than 3% of the font size. The compact header uses the settled sliced
state; the rare launch reveal begins with wider separation and resolves to that
same mark using the existing critically damped launch choreography. Reduce
Motion renders the settled mark with an opacity reveal only.

## Repo conventions to follow

- Shared visual primitives live in `ios/Roam/Utilities/DesignSystem.swift`.
- Motion tokens live in `ios/Roam/Utilities/AnimationConstants.swift`.
- Launch geometry/timing stays pure in `ios/Roam/Models/LaunchIntroChoreography.swift`.
- The header frame remains measured through `HeaderWordmarkFrameKey`.

## Steps

1. Add pure slice specifications and validation-friendly geometry to a model file.
2. Add a shared wordmark primitive that masks the resolved text into those bands.
3. Replace `BrandWordmark`'s serif `Text` while preserving layout, accessibility, and theme color.
4. Replace the launch overlay's duplicate serif text with the same primitive at hero size.
5. Add a test proving slices cover the mark, stay ordered, and settle within the offset budget.

## Boundaries

- Do NOT add a font dependency.
- Do NOT alter the launch video's timing or the live header frame handoff.
- Do NOT animate the persistent compact header.

## Verification

- **Mechanical**: `ios/tests/run-checks.sh PremiumMotion LaunchIntro`; simulator build must pass.
- **Feel check**: launch the app at normal speed and 10% speed. Confirm the hero mark resolves into the exact header mark without a jump. Enable Reduce Motion and confirm the mark fades without slice travel.
- **Done when**: no Baskerville/cursive wordmark remains in header or intro, and both use the same sliced mark.
