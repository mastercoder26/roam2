# Handoff — auth + persistence work (2026-08-06)

Context for whoever picks this up next. Covers the architecture, what changed,
what is verified, and what still has to be done by a human.

## Architecture — split backend

The backend is deployed **twice** from the same `backend/` codebase, with each
deployment doing one job:

```
            ┌─> Cloud Run `roam-backend` (us-central1)
            │     route difficulty + departure comparison
            │     stateless: no database, no Clerk credentials
iOS app ────┤
            └─> Render `roam-data-api`
                  accounts, drive history, profiles, saved routes
                  ──SSL──> Render Postgres `roam-db`
```

This works with **no code changes** because `server.ts` degrades by design: when
`DATABASE_URL` and `CLERK_SECRET_KEY` are absent it warns at boot and the account
endpoints return `503`, while route analysis keeps working. That absence is
exactly the Cloud Run configuration.

`POST /api/route/difficulty` is not behind `requireAuth` — only rate limited —
which is why Cloud Run needs no Clerk credentials at all.

Why the data API needs both secrets:
- `CLERK_SECRET_KEY` — verifies Clerk session tokens, and calls Clerk's admin API
  to delete the Clerk user in `DELETE /api/account`.
- `DATABASE_URL` — unrelated to auth; it is how the API reads and writes drives,
  profiles, and saved routes.

An iOS app cannot talk to Postgres directly: it would have to ship database
credentials in the app binary, where they can be extracted to read or drop every
user's data. A service you control must sit in between. That service is
`roam-data-api`.

### Render database

- Instance `roam-db`, Postgres 17, **free plan**, region `oregon`.
- Colocated with `roam-data-api`, so there is no cross-region hop. (An earlier
  revision of this file worried about Oregon vs `us-central1`; that only mattered
  when Cloud Run held the database connection, which it no longer does.)
- **The free plan expires 2026-09-05** — Render *deletes* it, it is not merely
  suspended. Upgrade or recreate before then.
- A `roam-db` instance was created manually (id `dpg-d9qbkm1t0dsc73fq6820-a`) and
  is now redundant: `render.yaml` declares its own `roam-db`. **Delete the manual
  one before deploying the blueprint** or Render will provision a duplicate. It
  holds no data.

## What changed

### Drive history persistence (complete, verified)

Drive history previously lived only in iOS `UserDefaults` under
`recorded-drives-v1`, so reinstalling the app destroyed it.

- `backend/src/db/migrations/002_drives.sql` — `drives` and `saved_routes`.
  Indexed scalar columns for sorting/filtering plus a `payload jsonb` holding
  the full `RecordedDrive`. Deliberately **not** normalized: `RecordedDrive` is
  a deep, still-changing `Codable` tree with legacy-decode accommodations. This
  follows the existing `driver_profiles.payload` precedent.
- `backend/src/db/repositories/drives.ts`, `backend/src/handlers/drives.ts` —
  every query is scoped to the authenticated user. The batch upsert carries
  `WHERE drives.user_id = EXCLUDED.user_id` so a client cannot overwrite another
  user's row by guessing its uuid.
- `ios/Roam/Services/DriveHistorySyncService.swift` — local-first sync. Union
  merge by drive id, server `updatedAt` wins, undecodable payloads are skipped
  rather than failing the sync. Synced-id markers live in a separate
  `drive-history-sync-v1` key so existing `recorded-drives-v1` data still
  decodes.

Note: the client marks a drive synced only when the **server echoes its id
back**, not on HTTP 200. That matters because the upsert guard above silently
returns nothing for a rejected row; marking on 200 would lose drives.

### Clerk auth (complete, verified)

Replaced the hand-rolled email/password + JWT + refresh-token stack with Clerk,
as a **full replacement**, using Clerk's **prebuilt** views.

- Clerk instance `capable-swan-35`, Frontend API
  `capable-swan-35.clerk.accounts.dev`. Apple and Google OAuth are both enabled
  (confirmed via `/v1/environment`).
- Backend: `@clerk/backend` token verification replacing `src/auth/*`; migration
  `003_clerk_auth.sql` adds `users.clerk_user_id` and drops `refresh_tokens` and
  `auth_identities`; signup/login/refresh/logout routes removed.
- iOS: `clerk-ios` SPM (`ClerkKit` + `ClerkKitUI`), `UserButton(signedOutContent:)`
  plus `AuthView()` in a sheet, replacing `LoginView`/`SignUpView`/
  `ForgotPasswordView`, `TokenStore`, and `AuthClient`.

Two invariants that were required of both agents:

1. `users.id` stays a local uuid and `clerk_user_id` is only a mapping column.
   `drives`, `saved_routes`, and `driver_profiles` keep their existing foreign
   keys. Repointing them at Clerk's string ids would orphan the drive history.
2. `AuthSessionStore.performAuthenticated(_:)` keeps its name and signature, with
   only its internals swapped to return a Clerk session token, so
   `DriveHistorySyncService` survives the auth swap untouched.

## Verified

Everything below was checked directly (build + tests + a real
`xcodebuild`/simulator run), not taken from agent self-reports — several agent
reports in this effort claimed success their own sandbox couldn't actually
observe (no simulator, no npm registry access), so nothing here was trusted
without an independent run.

- `cd backend && npm run build` — clean (`tsc --noEmit`)
- `cd backend && npm test` — 124 tests / 18 files (Clerk auth + drive history)
- `cd ios && ./tests/run-checks.sh` — 20/20 (Clerk auth + drive history + host
  routing)
- `xcodebuild -project ios/Roam.xcodeproj -scheme Roam -destination
  'platform=iOS Simulator,name=iPhone 17' build` — `** BUILD SUCCEEDED **`,
  run three times across the three iOS changes (drive-history sync, Clerk auth,
  host routing)
- iOS host routing spot-checked by reading `APIClient.swift` directly: only
  `api/route/difficulty` and `api/route/departure-comparison` pass `host:
  .route`; every other call (drives, profile, saved-routes, auth) falls
  through the `host: Host = .data` default — matches the intended split
  exactly.
- Cloud Run: **deployed and live**, revision `roam-backend-00008-9qn`,
  `https://roam-backend-1059769370189.us-central1.run.app`. Confirmed the new
  code is actually running (not just that the deploy succeeded) — hit
  `/api/drives` before and after: `404` (route didn't exist) → `503` (route
  exists, degrades cleanly because this instance correctly has no
  `CLERK_SECRET_KEY`/`DATABASE_URL`).
- Clerk: `GET /v1/instance` confirms `native_settings.api_enabled: true`
  (already on, nothing to do) and zero users exist yet (expected — the data API
  isn't live so nobody can actually sign up end-to-end yet).

## Not verified — read this first

**Migrations `002` and `003` have never executed against any Postgres,
anywhere.** There is no local Postgres running (`DATABASE_URL` in
`backend/.env.local` points at `localhost:5432/roam`, nothing listening) and no
Docker available locally. The SQL is reviewed but unexecuted. The first real run
will be when `roam-data-api` boots on Render.

**iOS points at a Render URL that does not exist yet.**
`Debug.local.xcconfig`/`Release.local.xcconfig` were set to
`https://roam-data-api.onrender.com` — a *guess* based on the service name in
`render.yaml`, made before that service was deployed. Render may assign a
different hostname. Confirm the real URL once step 2 below is done and update
both files if it differs.

## Remaining human steps

Nothing below can be done by an agent. This is the only work left — everything
else in this document is done and verified above.

1. **Delete the manual `roam-db`** (id `dpg-d9qbkm1t0dsc73fq6820-a`) in the Render
   dashboard, so the blueprint can own the database instead of provisioning a
   second one. It contains no data.

2. **Deploy the data API.** Render dashboard → New → Blueprint → this repo,
   branch `main`. It creates `roam-data-api` plus `roam-db` and prompts for the
   `sync: false` vars: `CLERK_SECRET_KEY`, and `GOOGLE_MAPS_API_KEY` only if this
   service should also answer route analysis.

   Migrations apply automatically on boot — `startCommand` is
   `npm run migrate && npm start`. That is safe on Render because the service runs
   a single instance. If a migration is broken, the deploy fails loudly instead
   of the service booting half-migrated — check the deploy logs if so.

   Do **not** copy that start command into the Dockerfile `CMD` for Cloud Run.
   Cloud Run starts concurrent instances, and `migrations/migrate.ts` does
   `SELECT version -> INSERT` inside one transaction: two instances starting
   together can both see a migration as unapplied, and the loser dies on the
   `schema_migrations` primary key. That is a crash loop on every cold start.

3. **Confirm the real `roam-data-api` URL and fix the iOS placeholder** if it
   differs from `https://roam-data-api.onrender.com`, in both
   `ios/Roam/Config/Debug.local.xcconfig` and `Release.local.xcconfig`.

4. **Cloud Run needs no further changes.** Already deployed and correctly
   serving difficulty-only with `GOOGLE_MAPS_API_KEY` only. Do not give it
   `DATABASE_URL` or `CLERK_SECRET_KEY` — the whole point of the split is that it
   holds neither.

5. **Clerk dashboard:** register the native application with Bundle ID
   `com.akhil.roam` and App ID Prefix `6RT6KBS4G9` under Configure → Native
   applications (no public API exposes whether this is already done, so check
   the dashboard directly). Apple and Google OAuth are enabled and currently
   running on Clerk's shared development credentials (`test_mode: true` on this
   instance) — fine for now, but swap in real provider credentials before
   production.

6. **Apple Developer portal:** nothing to do here anymore. Both Sign in with
   Apple and Associated Domains were removed from the iOS entitlements and
   Xcode capabilities after the user (a) dropped Apple sign-in from the Clerk
   dashboard and (b) hit an Xcode build error: Apple does not allow the
   Associated Domains capability on personal (free) development teams at all,
   regardless of entitlement config. Checked the clerk-ios SDK source directly
   — nothing in `Sources/` references associated domains; it only powers
   cross-app shared-session sync and Safari passkey/password autofill, neither
   of which Roam uses (no companion app). Sign-in works identically without
   it. Only revisit if a paid Apple Developer Program membership is added and
   cross-app session sharing becomes a real requirement.

7. **Rotate `CLERK_SECRET_KEY`.** The current dev key was pasted into a chat
   transcript on 2026-08-06. It is `sk_test_`, so only the dev instance is
   exposed, but roll it from Clerk's API Keys page and update
   `backend/.env.local` and the `roam-data-api` env vars once deployed.

8. **End-to-end check.** Sign up through `AuthView`, confirm the user appears in
   Clerk's Users list, record a drive of at least 30 seconds (`DriveHistoryPolicy`
   discards shorter ones), then delete and reinstall the app and sign in. The
   drive reappearing is the only real proof sync works.

## Known issues

- **Deleted drives resurrect.** `DriveHistorySyncService` merges local and server
  drives as a union and never calls `DELETE /api/drives/:id`, which the backend
  already implements (soft delete via `drives.deleted_at`). Delete a drive on the
  phone and the next pull brings it back. Fix with a local tombstone set that is
  pushed as deletes and excluded from the merge until confirmed.
- **`SharedRouteImportChecks` is flaky.** Its FIFO ordering assertion failed once
  and passed on the immediately following run with no source changes.
- **Stale docs.** `README.md` still documents Render as a backend deploy target
  and references `JWT_SECRET`, both of which are obsolete. `render.yaml`'s
  `services:` block should probably be deleted outright.
