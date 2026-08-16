# Roam

Roam helps families plan for a drive and practise safer driving. The app is
organized around four tabs:

- **Routes** scores a planned route's driving difficulty, compares the returned
  choices against privately recorded experience, offers guided practice plans,
  and compares nearby departure times when the conditions are available.
- **Drive** is a manually started, on-device session that combines GPS speed
  changes with phone motion to flag hard braking, rapid acceleration, sharp
  corners, and abrupt phone movement. Elapsed time and measured stats appear in
  a Live Activity while a drive is active.
- **Progress** shows an evidence-weighted, route-adjusted coaching score plus
  measured local evidence — validated miles, after-dark miles, 45+ mph miles,
  continuous-trace coverage, and an eight-week chart.
- **Profile** shows the driver's name, licensing stage, and lifetime record from
  locally recorded drives, plus appearance controls. It makes no network calls
  and stores only the display name and licensing stage, both self-declared and
  excluded from every score.

This is a prototype, not a safety system or an emergency service. A drive score
is coaching feedback, not a guarantee that a person or route is safe.

## How scoring uses data

Route difficulty is a **driver task-demand estimate**, not a crash-risk
prediction. It combines Google Routes geometry, maneuvers, and traffic-aware ETA
with best-effort enrichment from Open-Meteo and OpenStreetMap/Overpass.

Posted speed limits are assigned only to the sampled portion of a route they
actually match; without that coverage, scoring falls back to per-step route
timing rather than a route-wide average. After-dark exposure estimates sunrise
and sunset from the route location, travel date, and local departure time, with
a clock-time fallback. Every OSM field is ignored unless its lookup succeeded.
Each result lists the live sources that contributed and shows an uncertainty
band.

Manual driving scores stay on the device. Roam rejects poor GPS fixes, derives
braking and acceleration from changes in accepted GPS speed, uses course change
for sharp corners, and transforms gravity-free Core Motion readings into a
vertical reference frame. Possible phone handling requires a sustained
acceleration-and-rotation pattern while fresh GPS shows the vehicle moving, so a
single bump or a parked-phone nudge is ignored. Scores are normalized to
distance; short or sparse drives are labelled **Preliminary**.

A queued or active practice route keeps its address and planned polyline in
memory only. The saved route context retains stable demand IDs, numeric
coverage, goal status, and local timestamps. The local drive record separately
keeps its GPS trace and coaching events for private replay.

After a completed drive with a continuous trace, Roam sends only the measured
start and end coordinates to the route-analysis service and stores the resulting
compact difficulty snapshot locally — never the sent endpoint text or the
returned geometry. Analysis uses conditions available after the drive ends, so
it doesn't reconstruct historical traffic or weather. A failed analysis never
removes the drive or its local score.

The first minute of a drive can show a non-blocking sensor-placement advisory,
and only once fresh GPS shows the car moving and the high-confidence motion
detector has seen two separate episodes. It never identifies handheld use and
stores only the final advisory status.

## Run the iOS app

Open [Roam.xcodeproj](ios/Roam.xcodeproj), pick an iPhone simulator or a device,
and Run. The Drive tab needs a physical iPhone for meaningful accelerometer and
location readings; the Simulator is useful for UI only.

On the first manual drive iOS asks for location and motion permissions, used
only while a drive is running. If a drive continues with the phone locked, iOS
may also ask for **Always Allow** — location updates are enabled for the active
session only.

Device setup and API host configuration are in [docs/deployment.md](docs/deployment.md).

## Live Activity and CarPlay

The Live Activity starts only after a driver manually starts a drive, shows
elapsed time, speed, distance and event count, and ends with the drive. It
carries no route, address, or raw location data.

There's also a CarPlay information dashboard mirroring the active drive.
Starting and ending drives stays iPhone-only. Appearing on a real head unit
requires the app's Apple Developer identifier to be approved for the relevant
CarPlay category — normally the Maps entitlement. That entitlement is not
enabled in this repository, so adding the project to an iPhone won't fail for
developers who don't have it.

## Backend

The backend is deployed as two services: Cloud Run handles route analysis, while
Render handles authenticated accounts, profiles, drive history, and saved
routes. See [docs/deployment.md](docs/deployment.md) for the service boundary
and configuration details.

```bash
npm run dev    # http://localhost:3000
npm test       # backend scoring tests
```

Setup, environment variables, and both deploy targets are in
[docs/deployment.md](docs/deployment.md).

## iOS tests

The engines are covered by standalone Swift command-line checks in `ios/tests/`.
They compile with `swiftc` alone — no Xcode scheme, simulator, or XCTest bundle —
and exercise the pure local engines separately from the app target.

```bash
ios/tests/run-checks.sh              # all of them
ios/tests/run-checks.sh Theme Readiness   # name filters
```

The runner exits non-zero if any check fails to compile or fails an assertion.

Every check compiles against one shared source set declared at the top of
`run-checks.sh`. If a check stops compiling because an engine gained a
dependency, add the source there rather than giving that check its own list.

| Check | Covers |
|---|---|
| `APIClientChecks` | Backend error text, and the request time budget across candidate hosts |
| `AuthChecks` | Session token handling |
| `DepartureComparisonChecks` | Departure-time comparison |
| `DriveHistoryPolicyChecks` | Drive-history retention and pruning |
| `DriveHistorySyncChecks` | Local-first drive sync and merge |
| `DriveInsightEngineChecks` | Per-drive insights |
| `DrivePresentationChecks` | Drive summary presentation |
| `DriveScoringEngineChecks` | Manual-drive scoring, and the confidence tier a drive may claim |
| `DriverPerformanceEngineChecks` | Overall driver performance |
| `DriverProfileInsightsChecks` | Profile-level insights |
| `DriverProfileStoreChecks` | Profile persistence |
| `DriverReadinessEngineChecks` | Route readiness assessment |
| `LaunchIntroChoreographyChecks` | Launch intro timing and wordmark docking |
| `LayoutResponsivenessChecks` | Compact-width and large-text layout thresholds |
| `ProfileFolderChecks` | Profile folder order and navigation copy |
| `RouteAnalysisChecks` | Route analysis request and result handling |
| `RouteAnalysisStallChecks` | Analysis stall recovery |
| `RoutePlanningLocationChecks` | Route-entry state, including a coarse or slow GPS fix |
| `RoutePlanningPresentationChecks` | Route planning presentation |
| `RoutePracticeEnginesChecks` | Practice plans, route matching, untrusted-input hardening |
| `SharedRouteImportChecks` | Shared-route import, inbox durability, retriable vs permanent link failures |
| `ThemeCatalogChecks` | Theme catalog |

## Open source and attribution

Roam is available under the [MIT License](LICENSE).

The manual-drive feature is an original implementation built with Apple
CoreLocation and CoreMotion. Its scope and product direction were informed by
[DriveSense](https://github.com/wuisabel-gif/Drive-Sense), an MIT-licensed
project. No DriveSense source is included here. If any is incorporated later,
its copyright and license notice will be retained with the copied code.

## Privacy and safety

- Don't operate the app while driving. Start a session before leaving and end it
  after safely parking.
- **Get help** explains that Roam cannot detect crashes or call for help
  automatically. It can only open the phone's emergency-call flow when tapped.
- Never commit API keys. Local backend keys belong in `backend/.env.local`.
