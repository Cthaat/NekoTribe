# NekoTribe Flutter

Flutter client for NekoTribe. The app targets Web, Windows desktop, and mobile-width responsive layouts while reusing the existing `/api/v2/**`, `/_ws`, and `/storage/**` backend contracts.

## Current Status

Verified on 2026-05-24, branch `Flutter`:

- `flutter analyze` passes.
- `flutter test` passes, 20 tests.
- `flutter build web` passes.
- `flutter build windows` passes and emits `build/windows/x64/runner/Release/nekotribe.exe`.
- Flutter Web screenshots were captured at 390px, 800px, and 1280px under `build/visual-check/`.

## Implemented Parity Surface

- Public routes: feed, discover, post detail/edit, tags, numeric user profiles, terms, and about.
- Account routes: overview, profile edit, settings, appearance, billing, pro, security, sessions, statements, posts, likes, bookmarks, and endpoint switching.
- Content APIs: `page_size` pagination, plural likes/bookmarks, replies, retweets, comments, reports, recommendation feedback, and delete/edit flows.
- Groups: slug lookup via `/groups/by-slug/{slug}`, numeric-ID member/post/invite actions, group post details, comments, likes, pinning, invites, create/edit/manage screens.
- Chat: direct conversations, group channel route, message send/edit/delete/react/pin, channel read/mute APIs.
- Notifications: unread count, filters, single/all read, delete/restore, resource navigation.
- Moderation: overview, content actions, reports, users actions, appeals, and settings.
- SentimentFlow: backend-proxy based config and prediction UI.

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

When serving Flutter Web from a different local port than the backend entry (`30001`), the browser may block API calls with CORS. Serve the built Web app from the same origin as the backend reverse proxy, or provide a local proxy, for authenticated end-to-end browser testing.

## Verification Commands

```powershell
flutter analyze
flutter test
flutter build web
flutter build windows
```
