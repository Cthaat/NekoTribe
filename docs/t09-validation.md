# T09 standalone Flutter validation

Validated on Windows on 2026-09-10 with Flutter 3.41.9 and Dart 3.11.5.

## Scope

The `Flutter` branch now has its own Flutter root. The mechanical commit moved 166 tracked client files without changing their working-tree SHA256 values. It removed inherited Nuxt/backend/Node/Docker source and CI from this branch. The subsequent configuration change corrects endpoint descriptions, removes the unsupported Rust-direct preset, removes a reference to a nonexistent asset schema, and replaces monorepo instructions with standalone commands.

All 163 original client files outside the deliberately updated README, gitignore, and endpoint JSON retained their original bytes after local checks, including the three Windows generated plugin files. Git attributes pin those generated files to their original LF format. Android Gradle relative paths still resolve inside the Flutter project.

## Results

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

These results establish static, mocked-test, and JavaScript-build validity. They do not establish live Flutter login, WebSocket behavior, uploads, or acceptance of every feature against a running Nuxt service. Android builds, Android devices, Windows executable launch, and performance/load tests were not completed. No iOS/macOS platform project is supplied.

An independent clone should use the same root commands above without copying sibling sources or generated build directories. Its final commit and command evidence are retained in the migration audit; local evidence is intentionally ignored under `.codex-logs/t09/`. Backend deployment and backend tests remain owned by the Nuxt project.
