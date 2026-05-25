# NekoTribe Flutter

Flutter client for NekoTribe. The app targets Web, Windows desktop, and mobile-width responsive layouts while reusing the existing `/api/v2/**`, `/_ws`, and `/storage/**` backend contracts.

## Current Status

Verified on 2026-05-25, branch `Flutter`:

- `flutter analyze` passes.
- `flutter test` passes, 80 tests.
- `flutter build web` passes. The JS build is valid; the Wasm dry run still warns that `flutter_secure_storage_web` uses `dart:html` / `dart:js_util`.
- `flutter build windows` passes and emits `build/windows/x64/runner/Release/nekotribe.exe`.
- Flutter Web screenshots were captured at 390px, 800px, and 1280px under `build/visual-check/`.
- Backend source includes a first middleware CORS layer for Flutter Web preview origins; the local `30001` app container has been redeployed with that fix active.
- Flutter Web static preview login was smoke-tested against `http://localhost:30001` with the `edge` test account. Login reaches `#/feed`, persists access/refresh tokens through Flutter secure storage, and loads the home feed.
- The v2 auth API now returns token strings in JSON for Flutter/Web clients that cannot read `HttpOnly Set-Cookie`; refresh also accepts a JSON `refresh_token` body when the cookie is unavailable.
- Compose/edit post parity now covers the web composer metadata path: 280-character limit, `mentioned` visibility, location, hash/manual tag extraction, and `tag_names` API payloads.
- Group create/manage parity now covers avatar/cover media upload, privacy, category, tags, join approval, post permission, invite limits, pending member approval/rejection, member search, ownership transfer, delete confirmation, and matching v2 group metadata API payloads.
- Channel chat parity now covers attachment upload, reply targets, message edit/delete, reaction summaries with toggle, pin/unpin, and an `edge` live API smoke for media + reply + edit + reaction + pin + cleanup.

## Implemented Parity Surface

- Public routes: feed, discover, post detail/edit, tags, numeric user profiles, terms, and about.
- Account routes: overview, profile edit, settings, appearance, billing, pro, security, sessions, statements, posts, likes, bookmarks, and endpoint switching.
- Content APIs: `page_size` pagination, plural likes/bookmarks, replies, retweets, comments, reports, recommendation feedback, and delete/edit flows.
- Composer/editor: text, media, visibility, location, and tags are wired to the v2 post create/update contracts.
- Groups: slug lookup via `/groups/by-slug/{slug}`, numeric-ID member/post/invite actions, group post details, comments, likes, pinning, invites, create/manage avatar/cover media and metadata, invite limits, pending member approval/rejection, member search, ownership transfer, and delete confirmation.
- Chat: direct conversations, group channel route, attachment upload, reply preview/send, message send/edit/delete/react/pin, reaction summaries, and channel read/mute APIs.
- Notifications: unread count, filters, single/all read, delete/restore, resource navigation.
- Moderation: overview, content actions, reports, users actions, appeals, and settings.
- SentimentFlow: backend-proxy based config and prediction UI.
- Web display hardening: compact connection-error copy, Web-safe Chinese font fallback, media lightbox, avatar upload action, and mobile-safe feed tabs.

## Local Run

```powershell
cd C:\Code\NekoTribe\frontend_flutter
flutter pub get
flutter run -d windows
```

For Web, the build succeeds normally:

```powershell
flutter build web
```

When serving Flutter Web from a different local port than the backend entry (`30001`), use an app image built from this branch so the source CORS middleware and JSON token compatibility are active. A stale prebuilt app image may still answer preflight requests without `Access-Control-Allow-Origin` and may omit token strings from auth responses.

## Verification Commands

```powershell
flutter analyze
flutter test
flutter build web
flutter build windows
node --test ..\server\utils\auth-token-response.test.ts ..\server\utils\cors.test.ts
```
