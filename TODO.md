# TODO

## Blocking

- [ ] **Fix drive-deletion sync.** `DriveHistorySyncService` merges local and
      server drives as a union and never calls `DELETE /api/drives/:id`, which
      the backend already supports. Delete a drive on the phone and it comes
      back on the next pull. Needs a local tombstone set that gets pushed as
      deletes and excluded from the merge until confirmed.
- [ ] **Render free plan expires 2026-09-05.** Render *deletes* the instance, it
      isn't merely suspended. Upgrade or recreate `roam-db` before then.
- [ ] **Rotate `CLERK_SECRET_KEY`.** The current `sk_test_` key was pasted into a
      chat transcript on 2026-08-06. Roll it from Clerk's API Keys page and
      update `backend/.env.local` and the `roam-data-api` env vars.

## Before production

- [ ] Register the native app in Clerk (Configure → Native applications): bundle
      ID `com.akhil.roam`, App ID prefix `6RT6KBS4G9`. No API reports whether
      this is done — check the dashboard.
- [ ] Swap Google OAuth off Clerk's shared dev credentials. The instance is
      currently `test_mode: true`.
- [ ] Add a `cloudbuild.yaml` whose first step runs `npm test --prefix backend`,
      so a failing commit aborts before it reaches Cloud Run. Today the trigger
      deploys whether the tests pass or not.

## Verification

- [ ] End-to-end sync check on a device: sign up through `AuthView`, confirm the
      user appears in Clerk, record a drive of 30+ seconds (`DriveHistoryPolicy`
      discards shorter ones), delete and reinstall, sign in. The drive coming
      back is the only real proof sync works.
- [ ] `SharedRouteImportChecks` FIFO ordering assertion failed once with no
      source changes, then passed repeatedly. Worth a look.

## Nice to have

- [ ] Replace `CLGeocoder`/`reverseGeocodeLocation` in
      `RoutePlanningLocationCoordinator` with MapKit's
      `MKReverseGeocodingRequest`. The current calls are deprecated but work;
      the warnings surface on every check run.
- [ ] `render.yaml`'s `services:` block predates the backend split and should
      probably be trimmed to just the data API.

## Known bounds

- Snapshot persistence can lose up to 10 s of samples on termination: the 1 Hz
  timer calls `persistInProgressSnapshot()`, which throttles to once per 10 s.
  Intended trade-off, recorded so it isn't mistaken for a bug.
