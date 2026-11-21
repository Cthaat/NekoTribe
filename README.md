# NekoTribe Flutter

Standalone Flutter client for the NekoTribe Nuxt, Go, or Rust backend. Build from this branch's repository root.

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

Both launchers check Flutter availability, downloaded dependency metadata, endpoint base URLs, and local port `30004` before invoking Flutter's `web-server` device. Open `http://127.0.0.1:30004` once Flutter reports that the server is ready. The server stays in the terminal until Ctrl+C. Start the selected backend or gateway separately. Web-server debugging is more limited than the direct Chrome device shown above.

The launchers read asset defaults and accept optional `API_BASE_URL`, `WS_BASE_URL`, and `STORAGE_BASE_URL` environment variables. Realtime and media addresses can be omitted when they follow the API base. Base URLs may include a reverse-proxy prefix such as `https://example.com/community`. Supply separate addresses as needed. For example, when the backend is reachable from your browser at `192.168.1.50:3000`:

```powershell
$env:API_BASE_URL = 'http://192.168.1.50:3000'
.\scripts\start-web.ps1
```

```bash
API_BASE_URL=http://192.168.1.50:3000 bash scripts/start-web.sh
```

For a Web build used from other machines, embed addresses reachable by those browsers. Replace these example domains with your deployed service and configure CORS for the frontend's actual origin:

```bash
flutter build web --dart-define=API_BASE_URL=https://api.example.com
```

The launchers' environment variables become build defaults only. Saved settings still win. Reset the endpoint settings to apply the current build defaults. Switching endpoints closes the old HTTP and realtime clients. A saved session can be used by backends that share the same Oracle session and signing keys.

## Publish the Web client

After `flutter pub get`, use the project SDK to build a static directory with local rendering assets and without a Flutter service worker.

```text
flutter build web --no-pub --no-web-resources-cdn --pwa-strategy=none
```

Package the JavaScript build and its local CanvasKit files for transfer with:

```text
node scripts/package-web.mjs build/web --out flutter-web-release
```

Copy the release directory to the target machine. Publish its `site` directory as the document root of IIS on Windows, Nginx on Linux, or another static server. The release includes `configure-web.mjs` and a README outside the document root. The hosting machine needs only the Web output and the static server. For a subdirectory, build with the corresponding `--base-href`, for example `/community/`.

For local preview, install Node.js and double-click the release's `start.cmd` on Windows or run `sh start.sh` on Linux. Open the printed loopback URL. The default port is `30004`. Use `node serve-web.mjs --port 31004` to change it. The preview uses the build's configured base path and reads the published endpoint configuration on request.

Set `defaults.apiBaseUrl` in the published `assets/assets/config/app_config.json` to the browser-accessible base URL. The shipped defaults derive realtime and media from that address. Set `wsBaseUrl` or `storageBaseUrl` explicitly for split deployments. Serve this public file with cache revalidation. Saved endpoint settings and endpoint `--dart-define` values take priority over asset defaults.

An API-only entry also works in `presets` and in previously saved settings. Flutter derives missing realtime and media bases from the API address, including the port and reverse-proxy prefix, and preserves explicitly configured bases.

Flutter Web revalidates the public configuration on each page load, resolving it below the page's configured base path. The static host must allow revalidation for this file. Avoid immutable caching for it. The rest of the build can use its usual caching rules.

On Windows or Linux, use Node.js to update a built copy without editing JSON by hand. From the Flutter worktree, run the commands below. From a transferred release directory, use `node configure-web.mjs site --api URL` and `node configure-web.mjs site --check`. The script uses Node.js built-in modules.

```text
node scripts/configure-web.mjs build/web --api https://api.example.com/community
node scripts/configure-web.mjs build/web --check
```

Pass `--realtime wss://socket.example.com` and `--media https://media.example.com` for split services. Omitted addresses follow the API base, including its port and proxy prefix. `--share-site https://community.example.com` updates the public frontend used for shared links. If omitted, the previous share site is retained. The command changes only the built public configuration and prints the effective endpoints without contacting them.

For group post links, optionally set the top-level `groupPostShareBaseUrl` to the public Nuxt frontend address for the same data, such as `https://community.example.com` (or its deployed locale/base path). It is independent of the API endpoint and is also available in the native client's bundled configuration. Without it, Flutter Web shares its current hosted entry and group post route; native clients need the configured frontend address for copying public links.

When the static site uses a different origin from the backend, allow the site's actual origin in the selected backend's CORS configuration. An HTTPS site needs HTTPS for the API and files, and WSS for realtime. The endpoint settings page can check `/api/ready` before switching.

For sign-in from another machine, open the Flutter site over HTTPS. Flutter Web needs a secure browser context with Web Crypto for session storage. Browsers generally support HTTP on localhost for local development. When secure storage is unavailable, Flutter shows the deployment requirement before sending sign-in credentials.

The endpoint settings page detects remote HTTP or WS addresses on an HTTPS site before probing or saving them. Use HTTPS for the remote API and media, and WSS for the realtime endpoint. Loopback addresses remain available for local development.

## Backend connection

Start the selected backend or gateway separately. The endpoint settings page accepts a preset or custom HTTP(S) and WS(S) base URLs. Editing the API address updates the realtime and file fields that already follow it, including the port and proxy path prefix. Split service addresses stay in place. Use **Use API origin for realtime and files** to switch both fields back to the API base, then save.

If the default backend is unavailable, open **Server endpoint** from the sign-in page before entering credentials. After changing the backend, any password already typed on the sign-in page is cleared.

Use **Check backend readiness** before saving to check the entered API origin without sending account credentials or changing the active endpoint. The check needs a backend with `/api/ready` and a permitted browser origin on Flutter Web.

| Preset | API / storage origin | WebSocket origin |
| --- | --- | --- |
| Local Nuxt (default) | `http://127.0.0.1:3000` | `ws://127.0.0.1:3000` |
| Local Go | `http://127.0.0.1:30006` | `ws://127.0.0.1:30006` |
| Local Rust | `http://127.0.0.1:30003` | `ws://127.0.0.1:30003` |
| Local gateway | `http://127.0.0.1:30005` | `ws://127.0.0.1:30005` |
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
