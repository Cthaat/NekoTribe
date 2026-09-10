# NekoTribe Flutter

Standalone Flutter client for the NekoTribe Nuxt service. This branch builds from its repository root and does not contain the backend, Docker deployment, Node package, or Nuxt CI.

## Requirements and commands

Use Flutter 3.41.9 / Dart 3.11.5 or a compatible SDK satisfying `pubspec.yaml`. Run from the directory containing `pubspec.yaml`:

```powershell
flutter pub get
flutter analyze
flutter test
flutter build web
flutter build windows
flutter run -d windows
```

Windows builds require the Visual Studio C++ desktop workload. Android sources are included; Android and device acceptance require their own SDK/device validation. No iOS or macOS project is included.

## Backend connection

Start the Nuxt service separately. The endpoint settings page selects a preset or custom API, WebSocket, and storage origins:

| Preset | API / storage origin | WebSocket origin |
| --- | --- | --- |
| Nuxt application | `http://localhost:30001` | `ws://localhost:30001` |
| Nginx proxy | `http://localhost:30002` | `ws://localhost:30002` |
| Android emulator to host | `http://10.0.2.2:30001` | `ws://10.0.2.2:30001` |

These are configurable local deployment defaults, not an assumption that the backend is already running. The client appends `/api/v2/**`, `/_ws`, and `/storage/**`; enter origins without these suffixes. HTTPS deployments require HTTPS API/storage and WSS WebSocket origins. Android debug builds permit local cleartext HTTP; validate release networking separately.

Persisted endpoint settings take precedence over `--dart-define=API_BASE_URL=...`, `WS_BASE_URL`, and `STORAGE_BASE_URL`; compile-time values otherwise override asset defaults. Clear the saved custom endpoint to apply new build defaults.

For Flutter Web, configure the Nuxt service to allow the exact preview origin with credentials. The service must provide the v2 JSON access/refresh token contract; backend CORS and token tests belong to the backend project and are not prerequisites for this client's unit tests. Use an environment-local test account without committing credentials.

## Project boundary

- `lib/`: client networking, authentication, feature screens, routing, and shared UI.
- `test/`: Flutter unit, contract-shape, and widget tests using local fixtures.
- `assets/config/app_config.json`: selectable endpoint defaults.
- `android/`, `web/`, `windows/`: supported platform source projects.
- `contracts/v2.openapi.json`: Nuxt API snapshot with canonical LF line endings. [Source revision and SHA256](contracts/source.json) identify its authority; update deliberately with backend contract changes.
- `pubspec.yaml`, `pubspec.lock`, `.metadata`: SDK/dependencies and Flutter project metadata.

The client includes posts, groups, chat, notifications, account/security, moderation, and SentimentFlow proxy UI. Billing/Pro screens contain demonstrations, not implemented payment services. A successful build or mocked test run does not establish live acceptance of every feature.

Current migration validation and remaining gaps are recorded in [T09 validation](docs/t09-validation.md). Prior monorepo validation claims are not treated as evidence for this standalone root.
