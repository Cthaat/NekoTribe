# Flutter Web-Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Finish Flutter business parity with Nuxt production surface: green quality gates, Material 3 polish, DM + notifications/realtime rewrites, Windows full QA with `edge`, Android installable core path.

**Architecture:** Keep Riverpod + go_router + Dio + feature folders. Gap-driven incremental fixes on solid modules; rewrite `conversation_screen`, notifications UX + realtime consumption, and shared shell/status views. No backend contract invention; align stubs (Billing/Pro) with web.

**Tech Stack:** Flutter 3.x, `flutter_riverpod`, `go_router`, `dio`, `web_socket_channel`, `flutter_secure_storage`, `window_manager`, hand-written models.

**Design spec:** [docs/superpowers/specs/2026-07-13-flutter-web-parity-design.md](../specs/2026-07-13-flutter-web-parity-design.md)

**Working directory for Flutter commands:** `frontend_flutter/`

**QA:** Account `edge` (highest privilege). Password is local-only — never commit. API default `http://localhost:30001`.

---

## File map

| Path | Responsibility |
|------|----------------|
| `lib/features/moderation/presentation/moderation_screen.dart` | Reports tab: open/resolved filter + reopen action (W0) |
| `lib/shared/i18n/app_localizations.dart` | zh/en keys for moderation filters, DM, notifications, shell |
| `lib/shared/widgets/status_views.dart` | Shared Loading / Empty / Error (+ optional `AppListScaffold` helpers) |
| `lib/shared/routing/app_shell.dart` | Desktop rail + mobile bar + unread badge hook |
| `lib/shared/theme/app_theme.dart` | M3 polish only if needed for density/radius consistency |
| `lib/features/chat/presentation/conversation_screen.dart` | **Rewrite** DM room |
| `lib/features/chat/presentation/chat_home_screen.dart` | DM list polish / peer navigation |
| `lib/features/chat/data/chat_api.dart` | Extend only if pagination/send params missing (prefer keep) |
| `lib/features/notifications/presentation/notifications_screen.dart` | **Rewrite** mailbox UX |
| `lib/features/realtime/data/realtime_service.dart` | Keep; ensure connect lifecycle from session |
| `lib/shared/providers/providers.dart` | Wire realtime + unread badge providers if added |
| `lib/features/users/presentation/billing_screen.dart` | Aligned-stub clarity |
| `lib/features/users/presentation/pro_screen.dart` | Aligned-stub clarity |
| `assets/config/app_config.json` | Optional Android emulator preset |
| `android/**` | Cleartext/network for debug; build install |
| `test/features/moderation_screen_test.dart` | Green reopen test |
| `test/features/*` | New/updated widget tests for DM, notifications, shell |
| `frontend_flutter/README.md` | W7 parity surface update |

---

### Task 1: W0 — Fix moderation “resolved → pending” (red test)

**Files:**
- Modify: `frontend_flutter/lib/features/moderation/presentation/moderation_screen.dart` (`_ReportsTab` ~525+)
- Modify: `frontend_flutter/lib/shared/i18n/app_localizations.dart` (zh + en maps)
- Test: `frontend_flutter/test/features/moderation_screen_test.dart`

**Context:** Test taps `find.text('已处理')` then `Key('moderation-report-reopen-3001')`. UI currently only loads `status: 'open'` and has no resolved filter or reopen key.

- [ ] **Step 1: Confirm the failing test**

```powershell
cd C:\Code\NekoTribe\frontend_flutter
flutter test test/features/moderation_screen_test.dart --name "resolved reports"
```

Expected: FAIL — finder `已处理` finds 0 widgets.

- [ ] **Step 2: Add l10n keys (zh + en)**

In `app_localizations.dart` Chinese map add:

```dart
'moderation.reports.filter.open': '待处理',
'moderation.reports.filter.resolved': '已处理',
'moderation.reports.reopen': '重新打开',
'moderation.reports.empty_resolved': '暂无已处理举报',
```

In English map add matching:

```dart
'moderation.reports.filter.open': 'Open',
'moderation.reports.filter.resolved': 'Resolved',
'moderation.reports.reopen': 'Reopen',
'moderation.reports.empty_resolved': 'No resolved reports',
```

- [ ] **Step 3: Implement filter + reopen in `_ReportsTabState`**

Replace the reports tab state pattern with (adapt to existing field names in the file):

```dart
class _ReportsTabState extends ConsumerState<_ReportsTab> {
  List<V2ModerationReport> _items = [];
  bool _loading = true;
  Object? _error;
  String _status = 'open'; // 'open' | 'resolved'

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await ref.read(moderationApiProvider).reports(
            status: _status == 'open' ? 'open' : 'resolved',
          );
      if (!mounted) return;
      setState(() {
        _items = page.items;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _resolve(V2ModerationReport r, String status) async {
    await ref.read(moderationApiProvider).updateReport(
          reportId: r.reportId,
          status: status,
        );
    if (!mounted) return;
    setState(() => _items.removeWhere((x) => x.reportId == r.reportId));
  }

  Future<void> _reopen(V2ModerationReport r) async {
    await ref.read(moderationApiProvider).updateReport(
          reportId: r.reportId,
          status: 'pending',
        );
    if (!mounted) return;
    setState(() => _items.removeWhere((x) => x.reportId == r.reportId));
  }

  // In build(): above the list, add:
  // SegmentedButton or two ChoiceChips:
  // - label l10n.t('moderation.reports.filter.open') -> _status='open'; _load()
  // - label l10n.t('moderation.reports.filter.resolved') -> _status='resolved'; _load()
  // IMPORTANT: resolved chip must display Chinese '已处理' via l10n when locale is zh
  // (default app locale in tests is zh if AppLocalizations defaults to zh —
  //  wrap MaterialApp with localizations like other tests OR hard-ensure zh).
  //
  // For each resolved item, add:
  // OutlinedButton.icon(
  //   key: Key('moderation-report-reopen-${r.reportId}'),
  //   onPressed: () => _reopen(r),
  //   icon: Icon(Icons.undo),
  //   label: Text(l10n.t('moderation.reports.reopen')),
  // )
}
```

Ensure test harness still resolves Chinese: existing tests use bare `MaterialApp` without `AppLocalizations` delegate in some cases — check how other moderation tests find `审核设置`. If they pass, default locale map already serves zh strings from `AppLocalizations.of` fallback; if `已处理` still missing, set:

```dart
// In test pumpWidget MaterialApp:
locale: const Locale('zh'),
localizationsDelegates: const [AppLocalizationsDelegate(), ...],
supportedLocales: AppLocalizations.supported,
```

Prefer fixing **UI** so `l10n.t('moderation.reports.filter.resolved')` returns `已处理` under default test locale used by sibling tests in the same file.

- [ ] **Step 4: Re-run the test**

```powershell
flutter test test/features/moderation_screen_test.dart
```

Expected: All tests in file PASS.

- [ ] **Step 5: Full suite gate**

```powershell
flutter analyze
flutter test
```

Expected: No analyzer issues; all tests PASS (if other flakes appear, fix in-task before commit).

- [ ] **Step 6: Commit**

```powershell
cd C:\Code\NekoTribe
git add frontend_flutter/lib/features/moderation/presentation/moderation_screen.dart `
  frontend_flutter/lib/shared/i18n/app_localizations.dart `
  frontend_flutter/test/features/moderation_screen_test.dart
git commit -m "fix(flutter): restore moderation resolved reports reopen flow"
```

---

### Task 2: W0 — Windows login smoke (manual)

**Files:** none required (ops)

- [ ] **Step 1: Confirm backend**

```powershell
Invoke-WebRequest -Uri http://localhost:30001/api/health -UseBasicParsing
```

Expected: JSON with `"status":"ok"`.

- [ ] **Step 2: Run Windows app**

```powershell
cd C:\Code\NekoTribe\frontend_flutter
flutter run -d windows
```

- [ ] **Step 3: Login as `edge`**

Use local password (not in git). Confirm navigation to `#/feed` or `/feed`, feed loads without fatal error.

- [ ] **Step 4: Note blockers**

If login fails (CORS/token/endpoint), fix only client config/token path regressions — do not invent backend features. Endpoint screen: preset `entry` → `http://localhost:30001`.

- [ ] **Step 5: Commit only if code changed**

If no code change, skip commit and record “W0 smoke OK” in session notes.

---

### Task 3: W1 — Shared status views polish

**Files:**
- Modify: `frontend_flutter/lib/shared/widgets/status_views.dart`
- Modify: `frontend_flutter/test/shared/widgets/status_views_test.dart` (create if missing patterns)

- [ ] **Step 1: Extend `EmptyView` with optional action**

```dart
class EmptyView extends StatelessWidget {
  const EmptyView({
    super.key,
    required this.message,
    this.icon,
    this.actionLabel,
    this.onAction,
  });

  final String message;
  final IconData? icon;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon ?? Icons.inbox_outlined,
              size: 56,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge,
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 16),
              FilledButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}
```

Keep `ErrorView` / `LoadingView` API stable (call sites must still compile).

- [ ] **Step 2: Widget test for EmptyView action**

```dart
testWidgets('EmptyView shows optional action', (tester) async {
  var tapped = false;
  await tester.pumpWidget(
    MaterialApp(
      home: EmptyView(
        message: 'Nothing here',
        actionLabel: 'Retry action',
        onAction: () => tapped = true,
      ),
    ),
  );
  await tester.tap(find.text('Retry action'));
  expect(tapped, isTrue);
});
```

- [ ] **Step 3: Run tests**

```powershell
flutter test test/shared/widgets/status_views_test.dart
flutter analyze
```

Expected: PASS / clean.

- [ ] **Step 4: Commit**

```powershell
git add frontend_flutter/lib/shared/widgets/status_views.dart frontend_flutter/test/shared/widgets/
git commit -m "feat(flutter): polish shared empty/error status views"
```

---

### Task 4: W1 — AppShell unread badge + visual consistency

**Files:**
- Modify: `frontend_flutter/lib/shared/routing/app_shell.dart`
- Modify: `frontend_flutter/lib/shared/providers/providers.dart` (optional unread provider)
- Modify: `frontend_flutter/test/shared/routing/app_shell_test.dart`

- [ ] **Step 1: Add a lightweight unread count provider**

In `providers.dart` (or notifications feature file exported via providers):

```dart
final notificationsUnreadProvider =
    StateNotifierProvider<NotificationsUnreadController, int>((ref) {
  return NotificationsUnreadController(ref);
});

class NotificationsUnreadController extends StateNotifier<int> {
  NotificationsUnreadController(this.ref) : super(0);

  final Ref ref;

  Future<void> refresh() async {
    try {
      final count = await ref.read(notificationsApiProvider).unreadCount();
      state = count;
    } catch (_) {
      // keep last known
    }
  }

  void set(int value) => state = value < 0 ? 0 : value;
}
```

- [ ] **Step 2: Show badge on notifications tab**

In `AppShell` destinations, for notifications path wrap icon:

```dart
Badge(
  isLabelVisible: unread > 0,
  label: Text(unread > 99 ? '99+' : '$unread'),
  child: Icon(iconData),
)
```

Call `ref.read(notificationsUnreadProvider.notifier).refresh()` once when shell builds and session is authenticated (post-frame, avoid spam).

- [ ] **Step 3: Extend shell test**

Assert shell still builds; if badge provider overridden to `3`, `find.text('3')` or badge presence.

- [ ] **Step 4: analyze + test + commit**

```powershell
flutter analyze
flutter test test/shared/routing/app_shell_test.dart
git add frontend_flutter/lib/shared/routing/app_shell.dart frontend_flutter/lib/shared/providers/providers.dart frontend_flutter/test/shared/routing/
git commit -m "feat(flutter): show notifications unread badge on app shell"
```

---

### Task 5: W2 — Failing tests first for DM conversation rewrite

**Files:**
- Create/Modify: `frontend_flutter/test/features/conversation_screen_test.dart`
- Modify later: `frontend_flutter/lib/features/chat/presentation/conversation_screen.dart`

- [ ] **Step 1: Write widget tests against desired keys**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nekotribe/core/auth/token_store.dart';
import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/core/network/api_client.dart';
import 'package:nekotribe/core/network/api_response.dart';
import 'package:nekotribe/features/chat/data/chat_api.dart';
import 'package:nekotribe/features/chat/domain/chat_models.dart';
import 'package:nekotribe/features/chat/presentation/conversation_screen.dart';
import 'package:nekotribe/shared/providers/providers.dart';

void main() {
  testWidgets('conversation sends text and shows it', (tester) async {
    final api = _FakeChatApi();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [chatApiProvider.overrideWithValue(api)],
        child: const MaterialApp(
          home: ConversationScreen(conversationId: 11),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('hello edge'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('dm-composer-field')), 'ping');
    await tester.tap(find.byKey(const Key('dm-send-button')));
    await tester.pumpAndSettle();

    expect(api.sentContent, 'ping');
    expect(find.text('ping'), findsOneWidget);
  });

  testWidgets('conversation empty state when no messages', (tester) async {
    final api = _FakeChatApi(messages: const []);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [chatApiProvider.overrideWithValue(api)],
        child: const MaterialApp(
          home: ConversationScreen(conversationId: 11),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(EmptyView), findsOneWidget); // or text key
  });
}

// Implement _FakeChatApi mirroring chat_home_screen_test fakes:
// listDirectMessages returns seeded messages; sendDirectMessage records content.
```

Use real `V2DirectMessage` constructor fields from `chat_models.dart` (read file when implementing).

- [ ] **Step 2: Run tests — expect fail on missing keys**

```powershell
flutter test test/features/conversation_screen_test.dart
```

Expected: FAIL until rewrite adds `Key('dm-composer-field')` and `Key('dm-send-button')`.

---

### Task 6: W2 — Rewrite ConversationScreen

**Files:**
- Modify: `frontend_flutter/lib/features/chat/presentation/conversation_screen.dart`
- Optionally touch: `chat_home_screen.dart` for peer title navigation only

- [ ] **Step 1: Rewrite screen structure**

Requirements to implement in one cohesive rewrite:

1. `Scaffold` + `AppBar` title from conversation peer if available (optional fetch via existing list cache or placeholder `会话`).
2. Body: `LoadingView` / `ErrorView(onRetry: _load)` / message `ListView` reverse-friendly or chronologic with scroll-to-bottom.
3. Pagination: on scroll near top, if `has_next`, load older page via `beforeMessageId` or next `page` using existing `ChatApi.listDirectMessages`.
4. Composer row: `TextField(key: Key('dm-composer-field'))` + send `IconButton`/`FilledButton` with `key: Key('dm-send-button')`.
5. Send: trim, call `sendDirectMessage`, append, clear field, snackbar on error (keep text).
6. Empty: `EmptyView(message: l10n.t('chat.dm.empty'))` with new l10n keys.
7. Use `AppBreakpoints.contentMaxWidth` like other screens.
8. Bubble UI: align self vs other using current user id from `authSessionProvider` / users me if available; if not available, align by sender id heuristic from messages.

Add l10n:

```dart
'chat.dm.empty': '还没有私信，打个招呼吧',
'chat.dm.title': '私信',
```

English counterparts required.

- [ ] **Step 2: Pass conversation tests**

```powershell
flutter test test/features/conversation_screen_test.dart
flutter test test/features/chat_home_screen_test.dart
flutter test test/features/channel_screen_test.dart
```

Expected: all PASS (do not break channel).

- [ ] **Step 3: Commit**

```powershell
git add frontend_flutter/lib/features/chat/ frontend_flutter/lib/shared/i18n/app_localizations.dart frontend_flutter/test/features/conversation_screen_test.dart
git commit -m "feat(flutter): rewrite direct message conversation screen"
```

---

### Task 7: W3 — Notifications rewrite tests first

**Files:**
- Modify: `frontend_flutter/test/features/notifications_screen_test.dart`

- [ ] **Step 1: Add tests for filter + mark all read + delete keys**

Keep existing navigation tests green. Add:

```dart
testWidgets('unread filter and mark all read', (tester) async {
  final api = _FakeNotificationsApi([/* one unread, one read */]);
  // pump NotificationsScreen with overrides + l10n
  await tester.tap(find.byKey(const Key('notifications-filter-unread')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('notifications-mark-all-read')));
  await tester.pumpAndSettle();
  expect(api.markAllReadCalled, isTrue);
});
```

Extend `_FakeNotificationsApi` with `markAllReadCalled` flag.

- [ ] **Step 2: Run — may fail until keys exist**

```powershell
flutter test test/features/notifications_screen_test.dart
```

---

### Task 8: W3 — Rewrite NotificationsScreen + realtime hooks

**Files:**
- Modify: `frontend_flutter/lib/features/notifications/presentation/notifications_screen.dart`
- Modify: `frontend_flutter/lib/features/realtime/data/realtime_service.dart` (only if listener API gaps)
- Modify: `frontend_flutter/lib/shared/providers/providers.dart` or auth session to `connect()` on login
- Modify: i18n as needed

- [ ] **Step 1: Ensure realtime connects on authenticated session**

Find `AuthSessionController` (auth repository/session). After successful login/hydrate with tokens:

```dart
unawaited(ref.read(realtimeServiceProvider).connect());
```

On logout:

```dart
unawaited(ref.read(realtimeServiceProvider).disconnect());
```

If `realtimeServiceProvider` missing, add in `providers.dart`:

```dart
final realtimeServiceProvider = Provider<RealtimeService>((ref) {
  final svc = RealtimeService(
    config: ref.watch(appConfigProvider),
    tokenStore: ref.watch(tokenStoreProvider),
  );
  ref.onDispose(svc.disconnect);
  return svc;
});
```

- [ ] **Step 2: Rewrite notifications UI**

Must keep:

- `list` / `unreadCount` / `setReadStatus` / `markAllRead` / `deleteNotification` / `restoreNotification`
- Existing deep-link behavior for comment / group_comment / DM types (read current `_open` navigation logic before rewrite — preserve mapping)

Add:

- Keys: `notifications-filter-unread`, `notifications-mark-all-read`
- Type filter chips if already present — keep
- On WS event `type` in `notification_created`, `notification_read_status_updated`, `notifications_read_status_updated`, `notification_deleted`, `notification_restored`: refresh list or patch locally; update `notificationsUnreadProvider`
- Register listener in `initState`, remove in `dispose`

- [ ] **Step 3: Tests + analyze**

```powershell
flutter test test/features/notifications_screen_test.dart
flutter analyze
flutter test
```

Expected: green.

- [ ] **Step 4: Commit**

```powershell
git add frontend_flutter/lib/features/notifications/ frontend_flutter/lib/features/realtime/ frontend_flutter/lib/shared/providers/providers.dart frontend_flutter/lib/features/auth/ frontend_flutter/test/features/notifications_screen_test.dart frontend_flutter/lib/shared/i18n/
git commit -m "feat(flutter): rewrite notifications mailbox and realtime hooks"
```

---

### Task 9: W4 — Residual gaps pass (incremental)

**Files:** (touch only as QA finds issues)

- `feed_screen.dart`, `post_card.dart`, groups screens, `billing_screen.dart`, `pro_screen.dart`, security as needed

- [ ] **Step 1: Billing/Pro aligned-stub copy**

On Billing and Pro screens, ensure a visible note using l10n:

```dart
'billing.demo_notice': '演示数据，与网页一致，非真实扣费',
'pro.demo_notice': '功能介绍页，支付尚未开通',
```

Do not add fake checkout APIs.

- [ ] **Step 2: Groups residual**

If invites tab throws or mismatches web empty behavior, match web (empty list OK). No new endpoints.

- [ ] **Step 3: Feed/PostCard polish**

Fix only concrete overflow/menu bugs found during Windows smoke.

- [ ] **Step 4: Gate + commit**

```powershell
flutter analyze
flutter test
git add frontend_flutter
git commit -m "fix(flutter): residual parity polish for stubs and groups/feed"
```

---

### Task 10: W5 — Windows full acceptance checklist

**Files:** none or small hotfixes

- [ ] **Step 1: Run app on Windows**

```powershell
cd C:\Code\NekoTribe\frontend_flutter
flutter run -d windows
```

Login: `edge` + local password.

- [ ] **Step 2: Exercise checklist (check each)**

- [ ] Login / logout / session list
- [ ] Feed tabs, like, bookmark, retweet, open detail, comment
- [ ] Compose post with text (+ media if possible)
- [ ] Profile view + edit + avatar if quick
- [ ] Groups discover/my + open detail
- [ ] Channel chat send
- [ ] DM send
- [ ] Notifications list + mark read
- [ ] Settings / appearance / endpoint
- [ ] Moderation overview + content or reports action (privilege OK)
- [ ] Sentiment page predict smoke

- [ ] **Step 3: Fix any P0 blockers found, retest, commit hotfixes**

```powershell
flutter test
git add ...
git commit -m "fix(flutter): windows acceptance hotfixes"
```

---

### Task 11: W6 — Android installable core path

**Files:**
- Modify: `frontend_flutter/android/app/src/main/AndroidManifest.xml` (internet permission)
- Possibly: `android/app/src/debug/AndroidManifest.xml` cleartext
- Modify: `assets/config/app_config.json` optional preset `android-emulator`

- [ ] **Step 1: Ensure INTERNET permission**

`AndroidManifest.xml` application manifest must include:

```xml
<uses-permission android:name="android.permission.INTERNET" />
```

- [ ] **Step 2: Debug cleartext (localhost/HTTP)**

Create or edit `android/app/src/debug/AndroidManifest.xml`:

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
  <application android:usesCleartextTraffic="true" />
</manifest>
```

- [ ] **Step 3: Emulator API preset (optional but recommended)**

In `app_config.json` presets add:

```json
{
  "id": "android-emulator",
  "label": "Android Emulator → host 30001",
  "description": "Maps host machine localhost via 10.0.2.2",
  "apiBaseUrl": "http://10.0.2.2:30001",
  "wsBaseUrl": "ws://10.0.2.2:30001",
  "storageBaseUrl": "http://10.0.2.2:30001"
}
```

- [ ] **Step 4: Build APK**

```powershell
cd C:\Code\NekoTribe\frontend_flutter
flutter build apk --debug
```

Expected: success under `build/app/outputs/flutter-apk/`.

- [ ] **Step 5: Run on emulator/device if available**

```powershell
flutter devices
flutter run -d <android-id>
```

Core path: select android-emulator preset → login `edge` → feed → compose → notifications → chat.

If no emulator in environment, document build success + manual steps in README; do not claim device QA.

- [ ] **Step 6: Commit**

```powershell
git add frontend_flutter/android frontend_flutter/assets/config/app_config.json frontend_flutter/README.md
git commit -m "feat(flutter): android debug networking and emulator API preset"
```

---

### Task 12: W7 — Documentation closeout

**Files:**
- Modify: `frontend_flutter/README.md`
- Optional: short note in `doc/Flutter重构验收文档.md` or new date section — only if team expects it; prefer README update to avoid huge doc churn

- [ ] **Step 1: Update README “Implemented Parity Surface”**

Add bullets for:

- DM conversation rewrite + keys
- Notifications realtime hooks + shell badge
- Moderation resolved reopen
- Android emulator preset / cleartext debug
- Design/plan links to `docs/superpowers/specs/...` and `docs/superpowers/plans/...`

- [ ] **Step 2: Final gate**

```powershell
cd C:\Code\NekoTribe\frontend_flutter
flutter analyze
flutter test
```

Expected: clean + all green.

- [ ] **Step 3: Commit**

```powershell
git add frontend_flutter/README.md docs/superpowers/
git commit -m "docs(flutter): close web-parity implementation notes"
```

---

## Spec coverage self-check

| Spec item | Tasks |
|-----------|-------|
| Green analyze/test + known moderation failure | T1 |
| Windows login smoke | T2, T10 |
| Shell + M3 / status views | T3, T4 |
| DM rewrite | T5, T6 |
| Notifications + realtime rewrite | T7, T8 |
| Residual gaps + aligned stubs | T9 |
| Windows full acceptance incl. moderation | T10 |
| Android installable core path | T11 |
| Docs / README | T12 |
| No secrets in repo | All commits; password never written |
| No backend invention | Explicit in T9 groups/invites |

## Placeholder scan

Plan uses concrete files, commands, keys, and code sketches. Implementers must still read live constructors in `chat_models.dart` / notification models when filling fakes — field lists change; open those files at execution time rather than inventing fields.

## Execution notes

- Prefer **one task → tests → commit** discipline.
- After each wave, do not start the next with a red suite.
- Live password for `edge` stays in human memory / local secret store only.
