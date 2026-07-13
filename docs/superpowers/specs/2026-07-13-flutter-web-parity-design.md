# NekoTribe Flutter Web-Parity Design

> Date: 2026-07-13  
> Branch context: `Flutter`  
> Status: Approved for implementation planning  
> Scope: Complete Flutter client business parity with Nuxt production surface, Material 3 polish, Windows primary QA, Android installable core path

## 1. Problem and goal

NekoTribe already has a substantial Flutter client under `frontend_flutter/` that reuses Nuxt backend contracts (`/api/v2/**`, `/_ws`, `/storage/**`). The remaining work is not a greenfield rewrite. It is to:

1. Close residual **business parity** gaps versus the Nuxt production UI.
2. Raise **visual quality** under a unified Material 3 system (not pixel-cloning shadcn/Nuxt).
3. Validate on **Windows desktop** as the primary platform.
4. Make **Android** installable with a working core path (login → feed → compose → notifications → chat).
5. Keep quality gates green (`flutter analyze`, `flutter test`) and fix known failures.

### 1.1 Success criteria

| Criterion | Definition |
|-----------|------------|
| Parity checklist | Every Nuxt production capability mapped to Flutter as `done`, `partial→done`, or `aligned-stub` |
| Windows QA | Account `edge` (highest privilege) completes login, feed, compose/interactions, profile, groups, channel chat, DMs, notifications, settings, and moderation live flows |
| Android QA | Debug/release-capable install; configure API; complete core 5-step path |
| Visual | Consistent M3 spacing/cards/empty/error; desktop rail + mobile bottom bar; no layout overflow on primary lists |
| Quality | `flutter analyze` clean; `flutter test` all green; rewritten modules have widget/contract coverage |
| Backend | No new backend product contracts required for this effort |

### 1.2 Non-goals

- iOS App Store–grade delivery (do not block Windows; not a required acceptance target)
- Real payments / Billing backend
- Finishing Nuxt/backend incomplete items solely to invent Flutter-only features (see product inventory doc)
- FCM/APNs push, deep-link store setup
- Replacing Riverpod / go_router / Dio
- Full-repo freezed/json_serializable migration
- Committing secrets (passwords, tokens) into the repository

## 2. Current baseline (as of design)

### 2.1 Stack

| Area | Choice |
|------|--------|
| Flutter | 3.x stable (repo uses SDK `^3.11.5`) |
| State | `flutter_riverpod` |
| Routing | `go_router` |
| HTTP | `dio` via `ApiClient` |
| Storage | `flutter_secure_storage`, `shared_preferences` |
| Realtime | `web_socket_channel` |
| Desktop | `window_manager` + custom frame |
| Models | Hand-written `fromJson` (not freezed) |

### 2.2 What is already strong

Auth, feed, compose/edit, posts interactions, profiles, account settings/security/sessions/statements, groups create/manage/posts, channel chat (media/reply/edit/reaction/pin + realtime shapes), notifications API surface, moderation UI, SentimentFlow, endpoint switching, responsive shell, extensive route aliases matching Nuxt paths, API contract tests, prior Windows/Web builds.

Default API entry: `http://localhost:30001` (`assets/config/app_config.json` preset `entry`).

### 2.3 Known gaps driving this design

| Gap | Notes |
|-----|-------|
| Direct messages | Conversation UI thinner than channel chat / web DM room |
| Notifications UX + realtime consumption | List exists; mailbox-style UX and live updates need a focused rewrite |
| Shell / shared status views | Functional but not consistently polished |
| Billing / Pro | Static/demo (same class as web) |
| Quality | At least one failing moderation widget test (`resolved reports can be moved back to pending`) observed during baseline run |
| Android | Present as target folder; core-path install QA not treated as done |
| Shared web/backend incompletes | Follow Nuxt behavior; do not fake completion |

## 3. Strategy

**Primary:** gap-list driven sprints (incremental fixes on solid modules).  
**Secondary:** full module rewrites for high-value thin areas.

| Class | Action |
|-------|--------|
| Done + stable contracts | UI polish, small bugs, test hardening only |
| Partial / hard to extend | Rewrite presentation (and data only if required); keep API path contracts |
| Web stub/demo | Align Flutter stubs; label as demo where needed |
| Quality debt | Fix failing tests and shell consistency first |

### 3.1 Rewrite modules (Approach 2)

#### A. Direct messages (`features/chat` conversation side)

**Keep:** `ChatApi` contracts; `ChannelScreen` unless structural defects appear in QA.

**Rewrite:**

- `conversation_screen.dart`
- DM portion of `chat_home_screen` UX as needed for consistent IA

**Target capability (web-implemented subset):**

- Paginated history
- Send text
- Failure retry / clear error
- Peer profile entry
- Read state if API already exposes it
- Unified empty/loading/error with channel design language

**Do not require** full channel feature parity (reactions/pins/sticker toolbar) unless web DM + API already support them.

**Done when:** Windows can open a conversation, send/receive text, paginate; tests cover send + empty state; visual language matches channel chat.

#### B. Notifications (`features/notifications` + realtime consumption)

**Keep:** `NotificationsApi` paths (list, read-status, delete, restore) and model fields.

**Rewrite:**

- `notifications_screen` information architecture (filters, unread, actions, resource navigation)
- Subscription to `RealtimeService` after login: connect, reconnect, apply `notification_*` events to list/badge
- AppShell badge when unread count is available

**Done when:** Core mailbox actions match web; WS updates UI when backend WS is up; failures show retryable error; widget tests cover filter/read/navigation keys.

#### C. Shell + shared visuals (`shared/`)

**Strengthen/rewrite (not business APIs):**

- `status_views`: unified Loading / Empty / Error+Retry
- `app_shell`: desktop rail hierarchy, compose entry, profile placement, mobile bottom bar
- List/card spacing and AppBar consistency; keep M3 seed theming

**Done when:** Primary navigations are stable at compact and desktop widths; errors are short and retryable.

### 3.2 Incremental modules (Approach 1)

| Area | Action |
|------|--------|
| Feed / PostCard / detail / search / tags | Polish overflow, menus, lightbox edges; keep contracts |
| Compose / edit | Guard 280-char, tags, visibility, media regressions |
| Groups | Residual QA vs web; invite inbox behaves like web (including empty/incomplete backend behavior) |
| Account / settings / security / sessions / statements | Edge-case polish; no fake 2FA completion beyond API |
| Moderation | Fix failing test; live smoke with `edge` |
| SentimentFlow | Regression only |
| i18n | New strings for rewritten modules in zh/en maps |

### 3.3 Aligned stubs

| Screen | Behavior |
|--------|----------|
| Billing | Plan/demo invoices consistent with web; do not imply real charge |
| Pro | Marketing feature list; non-paying CTA consistent with web |

## 4. Architecture

```text
Screens (features/*/presentation)
  → Riverpod providers (shared/providers)
    → *Api / AuthRepository / UsersRepository
      → ApiClient (Dio) + TokenStore
        → API host → /api/v2/** , /_ws , /storage/**
AppShell: mobile NavigationBar | desktop NavigationRail + DesktopWindowFrame
```

### 4.1 Data flow rules

| Rule | Detail |
|------|--------|
| No mega-store | Page-local state; small notifiers only when shared |
| Mutations | Prefer server confirmation; optimistic only for established like/bookmark patterns; rollback + toast on failure |
| Pagination | `page`, `page_size`, `has_next`; footer load-more with retry |
| Media URLs | Always `AssetUrlResolver` |
| Public unauthenticated actions | Route to login via existing auth navigation helpers |
| Envelope | v2 `{code,message,data,meta}`; Nuxt nested error envelope; SentimentFlow raw JSON compatibility retained |

### 4.2 DM flow (after rewrite)

```text
ChatHome → select DM
  → GET direct messages (paged)
  → POST send
  → If WS DM events exist: merge; else append on success + refresh on re-entry
```

### 4.3 Notification flow (after rewrite)

```text
Login success → RealtimeService.connect
NotificationsScreen → REST list
WS notification_* → insert/update/badge
Tap → go_router by resource type (post/user/group/… aligned with web mapping)
```

### 4.4 Error handling

| Case | UX |
|------|----|
| Network/timeout | Unified error view + retry; short copy |
| Business 4xx | Mapped user strings; field errors on forms |
| 401 after failed refresh | Clear session → `/auth/login` |
| 403 moderation/admin | Friendly no-permission empty state |
| 404 resource | Not found / deleted + back |
| Upload failure | Keep draft; mark failed media removable |
| WS down | Background reconnect; optional “realtime offline” hint; REST remains usable |

## 5. Platforms

### 5.1 Windows (primary)

- Full parity checklist
- Custom window frame retained
- Live API against `http://localhost:30001` (or selected preset)

### 5.2 Android (this effort)

| In scope | Out of scope |
|----------|--------------|
| Fix/confirm `android/` project builds | FCM / background push |
| Install debug build | Store signing pipeline |
| Default or documented API reachability (`10.0.2.2:30001` for emulator; LAN IP for device) | Full moderation/Sentiment matrix on device |
| Core path: login → feed → compose → notifications → chat entry | iOS acceptance |
| Network + gallery/camera permissions as needed for compose | |

### 5.3 Flutter Web

Not a blocker. Keep existing web build/CORS/token compatibility; regression as convenient.

## 6. Environments and accounts

| Item | Convention |
|------|------------|
| Default API/WS/storage | `http://localhost:30001` / `ws://localhost:30001` |
| Android emulator | Document/use `http://10.0.2.2:30001` |
| Physical device | Endpoint screen or custom preset with reachable host |
| QA account | `edge` — highest privilege (moderation included) |
| Secrets | Password and tokens stay local only; never commit |

## 7. Testing and verification

| Gate | When |
|------|------|
| `flutter analyze` | Every wave exit |
| `flutter test` | Every wave exit; all green |
| API contract tests | Preserve/extend for posts/groups/chat/notifications |
| Widget tests | Required for rewritten DM, notifications, shell pieces |
| Fix | Moderation “resolved → pending” failure aligned with UI keys/labels |
| Manual Windows | Checklist with `edge` |
| Manual Android | Core 5-step path |

Do not claim success without running the relevant command or flow. Record gaps honestly (e.g. WS down in environment).

## 8. Delivery waves

| Wave | Content |
|------|---------|
| **W0** | Baseline: fix failing tests, analyze clean, Windows login smoke to `30001` with `edge` |
| **W1** | Shell + M3 shared status/visual polish |
| **W2** | DM conversation rewrite + tests |
| **W3** | Notifications + realtime consumption rewrite + tests |
| **W4** | Residual gaps (groups/posts/settings/moderation edges) |
| **W5** | Windows full business acceptance (incl. moderation) |
| **W6** | Android project hardening + core path |
| **W7** | Docs: `frontend_flutter/README.md`, acceptance notes; close checklist |

Implementation detail tasks belong in the follow-on plan from `writing-plans`, not in this design.

## 9. Parity matrix (planning)

| Domain | Baseline | Strategy | Windows | Android |
|--------|----------|----------|---------|---------|
| Auth | done | incremental | full | login |
| Feed / discover / tags / search | done | polish | full | feed |
| Compose / edit / media / interactions | done | polish + contracts | full | compose |
| Profiles / follow / account lists | done | polish | full | — |
| Account settings / security / sessions / statements | done | polish | full | — |
| Analytics | done | polish | full | — |
| Billing / Pro | stub | aligned-stub | show | — |
| Groups | done | residual QA | full | — |
| Group invites | web-aligned | match web | full | — |
| Channel chat | done | regression | full | enter chat |
| Direct messages | partial | **rewrite** | full | list/send |
| Notifications | partial/done boundary | **rewrite** | full | list |
| Realtime shell | partial | part of W3 | full | best-effort |
| Moderation | done | fix tests + live | full with `edge` | — |
| SentimentFlow | done | regression | full | — |
| Endpoint config | done | keep | full | required |
| iOS / push / payments | n/a | out of scope | — | — |

## 10. Risks

| Risk | Mitigation |
|------|------------|
| Treating web/backend incompletes as Flutter-only bugs | Label `aligned-with-web-gap`; match web |
| DM lacks rich WS events | REST + local append + refresh; attach events if present |
| Rewrite regressions | Contract tests first; wave isolation |
| Android cleartext/localhost | Emulator host mapping + network security for debug |
| UI polish scope creep | Shared components + rewrite screens + primary paths only |
| Brittle text finders in tests | Prefer `Key` / stable l10n keys |

## 11. Documentation outputs

| Artifact | Path |
|----------|------|
| This design | `docs/superpowers/specs/2026-07-13-flutter-web-parity-design.md` |
| Living client status | `frontend_flutter/README.md` (update in W7) |
| Prior acceptance reference | `doc/Flutter重构验收文档.md` |
| Migration reference | `doc/NekoTribe-Flutter前端迁移执行文档.md` |
| Shared product gaps | `doc/NekoTribe未实现功能盘点.md` |

## 12. Implementation handoff

After user review of this committed spec:

1. Invoke **writing-plans** to produce a step-by-step implementation plan (W0–W7 tasks, files, verification commands).
2. Execute plan wave-by-wave with analyze/test gates.
3. Do not expand into backend feature invention unless a separate approved design says so.

## 13. Approval record

| Item | Decision |
|------|----------|
| Goal style | A — business full parity with Nuxt production |
| Platforms | Windows primary + Android installable core path |
| Web incompletes | Align with web; no extra backend invention |
| Visual standard | Material 3 refined consistency |
| Approach | Gap sprints primary; DM, notifications+realtime, shell/shared status as rewrites |
| QA account | `edge` (highest privilege) |
| Design sections | Approved 2026-07-13 |
