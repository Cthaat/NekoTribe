# T09 standalone Flutter validation

Historical migration validation was recorded on Windows on 2026-09-10 with Flutter 3.41.9 and Dart 3.11.5. The results below describe that checkpoint, not a fresh acceptance run of all later changes.

## Scope

The `Flutter` branch now has its own Flutter root. The mechanical commit moved 166 tracked client files without changing their working-tree SHA256 values. It removed inherited Nuxt/backend/Node/Docker source and CI from this branch. The subsequent configuration change corrects endpoint descriptions, removes the unsupported Rust-direct preset, removes a reference to a nonexistent asset schema, and replaces monorepo instructions with standalone commands.

All 163 original client files outside the deliberately updated README, gitignore, and endpoint JSON retained their original bytes after local checks, including the three Windows generated plugin files. Git attributes pin those generated files to their original LF format. Android Gradle relative paths still resolve inside the Flutter project.

## Historical T09 results

| Check | Result |
| --- | --- |
| `flutter pub get` | Passed using the committed lockfile |
| `flutter analyze` | Passed, no issues |
| `flutter test --no-pub --concurrency=2` | Passed, 123 tests |
| `flutter build web --no-pub` | Passed, JavaScript output in `build/web` |
| `flutter build windows --no-pub` | Attempted; blocked by missing suitable Visual Studio toolchain |
| Contract snapshot | Canonical LF SHA256 and Git blob match the Nuxt authority recorded in `contracts/source.json` |
| Original generated files | All three SHA256 values preserved |

The Web build reports Wasm dry-run incompatibilities in `flutter_secure_storage_web` (`dart:html`, `dart:js_util`, and `package:js`). JavaScript Web output passed; Wasm output was not produced or accepted. The dependency resolver reports newer versions outside current constraints; this boundary migration does not upgrade dependencies.

## Acceptance limits

These results establish static, mocked-test, and JavaScript-build validity. They do not establish live Flutter login, WebSocket behavior, uploads, or acceptance of every feature against a running Nuxt service. Android builds, Android devices, Windows executable launch, and performance/load tests were not completed. The user selected Web first and deferred Windows until the C++ toolchain is installed; no Visual Studio installation was performed. No iOS/macOS platform project is supplied.

An independent clone should use the same root commands above without copying sibling sources or generated build directories. Its final commit and command evidence are retained in the migration audit; local evidence is intentionally ignored under `.codex-logs/t09/`. Backend deployment and backend tests remain owned by the Nuxt project.

## T11 client compatibility follow-up

The client previously attempted GET `/api/v2/notifications/read-status`, while the Nuxt service supplies only write operations at that route. The unread badge now requests GET `/api/v2/notifications?unread_only=true&page=1&page_size=1` and reads the pagination total. Regression cases cover a total larger than the one-item page and zero unread notifications; both failed before the fix and passed afterward. Static analysis and the full 125-test suite passed after this change. These two changed Dart files are additional to the three configuration/documentation files counted in the T09 byte-preservation check above.

Local endpoint defaults now target the independent Nuxt service at `127.0.0.1:3000`; Flutter Web development uses fixed port `30004` with explicit backend CORS origins. Older Docker `30001`/`30002` presets remain labeled optional existing deployments. This changes defaults, not saved user overrides.

## Current static development follow-up (2026-10-25)

Added a Windows double-click Web launcher (`start-web.cmd` and `scripts/start-web.ps1`) and a Linux launcher (`bash scripts/start-web.sh`). They check the Flutter command, dependency metadata, endpoint origin format, and port `30004`, then run Flutter's `web-server` device with `--no-pub`. Linux additionally needs Python 3 for URL and port validation. They read the asset defaults, accept optional API/WS/storage environment variables, and preserve the app's saved-setting priority. README instructions distinguish first-time dependency downloads from later launches and use browser-reachable backend addresses for cross-machine builds.

Static checks passed: PowerShell parser, `bash -n`, embedded Python AST parsing, Windows missing-SDK and invalid-origin error paths, and `git diff --check`. The Windows guard checks also verified that the Chinese UTF-8 asset configuration loads correctly under Windows PowerShell. A source scan found no remaining `frontend_flutter` or sibling Nuxt/frontend source references; the original generated Windows files have no diff.

This follow-up is limited to source and script validation. The local Flutter entry point writes SDK lock/cache files under `C:/flutter`, outside the permitted project write scope, so analyze/test/build were not rerun for these edits. No application, browser, Docker service, or Windows C++ installer was launched. Live launcher startup on Windows/Linux, backend login/WebSocket/upload flows, and any cross-machine Web deployment remain to be tested. Native Windows build/launch remains deferred until the Visual Studio C++ workload is available; the historical blocked build is not a successful native acceptance result.
