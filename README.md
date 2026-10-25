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
flutter run -d chrome --web-port 30004
```

Windows builds require the Visual Studio C++ desktop workload. Android sources are included; Android and device acceptance require their own SDK/device validation. No iOS or macOS project is included.

## Web development launchers

Install Flutter, put its `bin` directory on `PATH`, and run `flutter pub get` from this root once before launching (also rerun it after dependency changes). Dependency downloads need network access and may write Flutter/Pub caches outside this checkout. The launchers use `--no-pub` and do not install dependencies. Windows Web development does not need the Visual Studio C++ workload.

- Windows: double-click `start-web.cmd`, or run `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/start-web.ps1`.
- Linux: install Bash and Python 3, then run `bash scripts/start-web.sh`.

Both launchers check Flutter availability, downloaded dependency metadata, endpoint origins, and local port `30004` before invoking Flutter's `web-server` device. They print `http://127.0.0.1:30004`; open it manually once Flutter reports that the server is ready. The server stays in the terminal until Ctrl+C. They start only the Flutter development server; start Nuxt separately. Web-server debugging is more limited than the direct Chrome device shown above.

The launchers read asset defaults and accept optional `API_BASE_URL`, `WS_BASE_URL`, and `STORAGE_BASE_URL` environment variables. Set all three when switching backend hosts. For example, when Nuxt is reachable from your browser at the example LAN address `192.168.1.50:3000` (replace it with your actual server address):

```powershell
$env:API_BASE_URL = 'http://192.168.1.50:3000'
$env:WS_BASE_URL = 'ws://192.168.1.50:3000'
$env:STORAGE_BASE_URL = 'http://192.168.1.50:3000'
.\scripts\start-web.ps1
```

```bash
API_BASE_URL=http://192.168.1.50:3000 \
WS_BASE_URL=ws://192.168.1.50:3000 \
STORAGE_BASE_URL=http://192.168.1.50:3000 bash scripts/start-web.sh
```

For a Web build used from other machines, embed addresses reachable by those browsers. Replace these example domains with your deployed service and configure CORS for the frontend's actual origin:

```bash
flutter build web --dart-define=API_BASE_URL=https://api.example.com \
  --dart-define=WS_BASE_URL=wss://api.example.com \
  --dart-define=STORAGE_BASE_URL=https://api.example.com
```

The launchers' environment variables become build defaults only. Saved settings still win; use the endpoint settings page to reset or select the intended configuration. They do not append API, WebSocket, or storage path suffixes.

## Backend connection

Start the Nuxt service separately. The endpoint settings page selects a preset or custom API, WebSocket, and storage origins:

| Preset | API / storage origin | WebSocket origin |
| --- | --- | --- |
| Local Nuxt (default) | `http://127.0.0.1:3000` | `ws://127.0.0.1:3000` |
| Existing Docker application | `http://localhost:30001` | `ws://localhost:30001` |
| Existing Docker Nginx proxy | `http://localhost:30002` | `ws://localhost:30002` |
| Android emulator to host | `http://10.0.2.2:3000` | `ws://10.0.2.2:3000` |

These are configurable local deployment defaults, not an assumption that the backend is already running. The client appends `/api/v2/**`, `/_ws`, and `/storage/**`; enter origins without these suffixes. HTTPS deployments require HTTPS API/storage and WSS WebSocket origins. Android debug builds permit local cleartext HTTP; validate release networking separately.

Persisted endpoint settings take precedence over `--dart-define=API_BASE_URL=...`, `WS_BASE_URL`, and `STORAGE_BASE_URL`; compile-time values otherwise override asset defaults. Clear the saved custom endpoint to apply new build defaults.

For Flutter Web, use fixed preview port `30004` and configure the Nuxt service to allow `http://localhost:30004` and `http://127.0.0.1:30004` with credentials. The default API target is the separate local Nuxt service on `127.0.0.1:3000`; ports `30001`/`30002` describe optional existing Docker deployments. The service must provide the v2 JSON access/refresh token contract; backend CORS and token tests belong to the backend project and are not prerequisites for this client's unit tests. Use an environment-local test account without committing credentials.

## Project boundary

- `lib/`: client networking, authentication, feature screens, routing, and shared UI.
- `test/`: Flutter unit, contract-shape, and widget tests using local fixtures.
- `assets/config/app_config.json`: selectable endpoint defaults.
- `android/`, `web/`, `windows/`: supported platform source projects.
- `contracts/v2.openapi.json`: Nuxt API snapshot with canonical LF line endings. [Source revision and SHA256](contracts/source.json) identify its authority; update deliberately with backend contract changes.
- `pubspec.yaml`, `pubspec.lock`, `.metadata`: SDK/dependencies and Flutter project metadata.

The client includes posts, groups, chat, notifications, account/security, moderation, and SentimentFlow proxy UI. Billing/Pro screens contain demonstrations, not implemented payment services. A successful build or mocked test run does not establish live acceptance of every feature.

Current migration validation and remaining gaps are recorded in [T09 validation](docs/t09-validation.md). Prior monorepo validation claims are not treated as evidence for this standalone root.
