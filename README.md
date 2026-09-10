# NekoTribe Flutter

Flutter client for NekoTribe. The app targets Web, Windows desktop, and mobile-width responsive layouts while reusing the existing `/api/v2/**`, `/_ws`, and `/storage/**` backend contracts.

## Current Status

Verified on 2026-07-13, branch `Flutter`:

- `flutter analyze` passes.
- `flutter test` passes, 111 tests.
- `flutter build web` passes. The JS build is valid; the Wasm dry run still warns that `flutter_secure_storage_web` uses `dart:html` / `dart:js_util`.
- `flutter build windows` passes and emits `build/windows/x64/runner/Release/nekotribe.exe`.
- Flutter Web screenshots were captured at 390px, 800px, and 1280px under `build/visual-check/`.
- Backend source includes a first middleware CORS layer for Flutter Web preview origins; the local `30001` app container has been redeployed with that fix active.
- Flutter Web static preview login was smoke-tested against `http://localhost:30001` with the `edge` test account. Login reaches `#/feed`, persists access/refresh tokens through Flutter secure storage, and loads the home feed.
- The v2 auth API now returns token strings in JSON for Flutter/Web clients that cannot read `HttpOnly Set-Cookie`; refresh also accepts a JSON `refresh_token` body when the cookie is unavailable.
- Raw SentimentFlow proxy responses are decoded without v2-envelope assumptions, so the standalone sentiment page and post AI analysis dialog show labels, confidence, and probability rows from the live backend response.
- SentimentFlow prediction requests forward the normalized runtime `model` (`bert` / `lstm`) together with `model_id`, so choosing BERT no longer silently falls back to the keyword baseline path.
- Post card bookmark toggles preserve the current liked state, preventing home-feed bookmark actions from clearing a like.
- The desktop shell publish button opens the post composer (`/meow`), home post cards expose retweet counts/actions, and the post overflow menu is fixed to the card's right edge.
- Compose/edit post parity now covers the web composer metadata path: 280-character limit, `mentioned` visibility, location, hash/manual tag extraction, and `tag_names` API payloads.
- Group create/manage parity now covers avatar/cover media upload, privacy, category, tags, join approval, post permission, invite limits, pending member approval/rejection, member search, ownership transfer, delete confirmation, and matching v2 group metadata API payloads.
- Channel chat parity now covers attachment/image toolbar actions, emoji/mention/channel/sticker insertion, attachment upload, reply targets, message edit/delete, reaction summaries with toggle, pin/unpin, and an `edge` live API smoke for media + reply + edit + reaction + pin + cleanup.
- Channel realtime parity now consumes the backend/Nuxt event shapes for message create/update/delete and reaction updates.
- Chat channel management parity now covers channel category input, mute/unmute, edit, delete, matching v2 API payloads, and an `edge` live API smoke for create + update + mute + delete cleanup.

## Implemented Parity Surface

- Public routes: feed, discover, post detail/edit, tags, numeric user profiles, terms, and about.
- Account routes: overview, profile edit, settings, appearance, billing, pro, security, sessions, statements, posts, likes, bookmarks, and endpoint switching.
- Content APIs: `page_size` pagination, plural likes/bookmarks, replies, retweets, comments, reports, recommendation feedback, and delete/edit flows.
- Composer/editor: text, media, visibility, location, and tags are wired to the v2 post create/update contracts.
- Groups: slug lookup via `/groups/by-slug/{slug}`, numeric-ID member/post/invite actions, group post details, comments, likes, pinning, invites, create/manage avatar/cover media and metadata, invite limits, pending member approval/rejection, member search, ownership transfer, and delete confirmation.
- Chat: direct conversations, group channel route, channel create/edit/delete/mute, attachment/image upload controls, emoji/mention/channel/sticker composer actions, reply preview/send, message send/edit/delete/react/pin, reaction summaries, channel realtime sync, and channel read/mute APIs.
- DM conversations: list/detail rewrite with stable widget keys for reliable updates.
- Notifications: unread count, filters, single/all read, delete/restore, resource navigation, realtime hooks, stable keys, and shell unread badge.
- Empty states: `EmptyView` action buttons for common recovery paths.
- Moderation: overview, content actions, reports (resolved reopen + pending status), users actions, appeals, and settings.
- Billing / Pro: demo notices (no payment APIs); static demo data aligned with web.
- SentimentFlow: backend-proxy based config, model-aware prediction requests, and prediction UI.
- Web display hardening: compact connection-error copy, Web-safe Chinese font fallback, media lightbox, avatar upload action, and mobile-safe feed tabs.
- Android debug networking: `INTERNET` permission, cleartext traffic in debug, and `android-emulator` API preset (`10.0.2.2:30001`).

## Design & plan

- Design: [`docs/superpowers/specs/2026-07-13-flutter-web-parity-design.md`](../docs/superpowers/specs/2026-07-13-flutter-web-parity-design.md)
- Plan: [`docs/superpowers/plans/2026-07-13-flutter-web-parity.md`](../docs/superpowers/plans/2026-07-13-flutter-web-parity.md)

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

### Android emulator API

On the Android emulator, `localhost` points at the emulator itself. Use the endpoint preset **Android Emulator → host 30001**, which maps the host machine via `10.0.2.2`:

- API: `http://10.0.2.2:30001`
- WebSocket: `ws://10.0.2.2:30001`
- Storage: `http://10.0.2.2:30001`

Debug builds allow cleartext HTTP (`usesCleartextTraffic`) so local `http://` backends work without TLS.

### QA account

Smoke tests use a local QA account (e.g. username `edge`). Credentials are environment-local and are **not** stored in this repository or docs.

## Verification Commands

```powershell
flutter analyze
flutter test
flutter build web
flutter build windows
node --test ..\server\utils\auth-token-response.test.ts ..\server\utils\cors.test.ts
```
