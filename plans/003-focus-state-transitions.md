# 003 — Stage major state changes through focus

- **Status**: DONE
- **Commit**: 7f3a4b7
- **Severity**: MEDIUM
- **Category**: Physicality & origin
- **Estimated scope**: 4 files, ~90 lines

## Problem

Several major content swaps either use a generic side move or a plain opacity
fade, so they feel like stock SwiftUI navigation rather than one authored
motion language:

```swift
// ios/Roam/Features/Results/ResultsView.swift — current
reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .trailing))
```

```swift
// ios/Roam/Features/Home/HomeView.swift — current loading overlay
.transition(.opacity)
```

## Target

Add a shared transition modifier for rare, major state changes: active state at
`opacity 0`, `scale 0.975`, `y 10`, and `blur 8`; identity at full opacity,
scale 1, zero offset, zero blur. Use a strong ease-out / critically damped
spring under 300ms. Reduced Motion uses a 180ms opacity-only transition.

## Repo conventions to follow

- Shared transitions and animation tokens live in `DesignSystem.swift` and `AnimationConstants.swift`.
- Existing view-local `accessibilityReduceMotion` branching remains the caller's responsibility.
- Transitions must enter and leave along the same path.

## Steps

1. Add a reusable animatable focus-transition modifier and helper.
2. Replace the Results Overview/Details trailing slide with the focus transition.
3. Use the focus transition for route-analysis overlay arrival/departure.
4. Keep the active Drive surface excluded so its information stays visually stable.

## Boundaries

- Do NOT apply blur transitions to scrolling list rows or tab switches.
- Do NOT exceed 8px blur.
- Do NOT change navigation or data flow.

## Verification

- **Mechanical**: full Swift checks and simulator build pass.
- **Feel check**: toggle Results pages rapidly and start route analysis. Confirm transitions retarget without flashes or double exposure. Enable Reduce Motion and confirm all movement/blur disappears while the fade remains.
- **Done when**: only high-value state changes use the focus treatment and repeated navigation stays fast.
