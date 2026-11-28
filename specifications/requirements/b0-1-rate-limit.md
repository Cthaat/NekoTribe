# B0.1 · Shared v2 admission and login alerts (revision 1)

Nuxt, Go and Rust implement the same policy against one deployment Redis namespace. Apply it before dispatch to public /api/v2/** operations, including aliases. Path classification uses the matched route template and HTTP method. Query strings, tokens, account names, backend names and client platforms never select a fresh bucket. The retired integrations/sentiment-flow prefix retains its fixed config/410/404 responses before admission. Probes, metrics, WebSocket, internal protocols and CORS preflight are outside this slice.

## Admission

Take the first matching row. The numbers below are production defaults, expressed as admissions per fixed window in seconds. Operators must roll out identical policy values to all instances.

| Tier | Selector | Limit | Seconds |
|---|---|---:|---:|
| Auth/OTP | All /api/v2/auth/** except GET or DELETE sessions and DELETE tokens/current. Also PATCH users/me/email and users/me/two-factor setup, confirm and deletion. | 10 | 60 |
| AI | POST ai/conversations/{id}/{generate,knowledge-generate,group-generate,moderation-generate}, ai/media/describe and users/me/ai-provider/test. | 10 | 60 |
| Export/Upload | GET users/me/export, POST media or media/private, PUT users/me/avatar and any other operation accepting multipart/form-data. | 10 | 60 |
| Write | Remaining methods other than GET and HEAD. | 40 | 10 |
| Read | Remaining GET and HEAD requests. | 100 | 10 |

Relative route names above are under /api/v2/. The sessions exception covers the sessions collection and its descendants. All five tiers are independent. Resolve IP from the socket by default. Honor the existing trusted proxy policy only at a configured, sanitized ingress. Canonicalize IPv4, fold IPv4-mapped IPv6 into IPv4, use lowercase RFC 5952 for IPv6 and use the literal unknown for an unavailable address. Do not use untrusted forwarding headers or a device fingerprint to partition quotas.

Use the shared Redis key neko:v2:admission:1:<tier>:<ip> with tier tokens auth, ai, transfer, write, read respectively. A single Lua evaluation creates the counter with its millisecond expiry on the first admission, admits at most limit requests until expiry and returns admissions left and milliseconds to expiry from Redis. Admission and expiry are indivisible across processes. A denial never refreshes the TTL. At expiry the next request starts a new window. Redis failure preserves the existing general limiter fail-open policy. Independent OTP/AI reservation and authorization policies still run and retain their own failure semantics.

## Wire contract

A tier rejection returns HTTP 429 before any business side effect. With Accept: application/json all three backends return the V2HttpErrorTransport outer fields, statusCode 429 and a required data envelope with code 42901, a nonempty localized message and null data and meta. HEAD sends no body. RateLimit-Limit is the selected limit, RateLimit-Remaining is 0, RateLimit-Reset and Retry-After both equal max(1, ceil(remaining_ms / 1000)). All are decimal integer headers. Browser CORS responses expose all four. Clients use status, code and delay for decisions; message text may be localized.

After admission, OTP send/verification, password reset, email change and the five AI quota operations keep their existing error shapes, codes, examples and Retry-After semantics. A fresh OTP window or a backend switch never resets those business budgets. A 429 does not refresh credentials or replay a write automatically. An admitted operation retains its documented parameters, authentication, authorization, business validations, success schema, cookies and pagination meta. Readiness checks are read-only and missing required auth structures yield a sanitized 503. No schema additions or DDL are required.

## Asynchronous login email

Apply the same rule to a completed password login (including a trusted device), either 2FA completion route, passkey authentication verification and GitHub login completion when they actually issue a session. Capture the evidence from sessions for this account preceding this login. The new-device predicate follows auth-login.md, including revoked and expired session history and its existing unknown fingerprint fallback. For location change, compare the last prior committed session (created_at DESC, session_id ASC) with this login. Resolve both trusted client IPs using the same deployment-local region mapping/version on all three backends. Compare canonical region identifiers only when both are known. An IP change alone, profile location, browser locale and untrusted headers are insufficient. With no mapping, device alerts continue. No new table, external geolocation call or raw location header is required.

After successful session commit, if either predicate matches, schedule at most one email per issued session even when both match. Reuse the existing login_alerts gate, email preference, account destination and configured SMTP path. Preserve independent in-app notification and push settings. A password-only challenge, refresh, failed/replayed login or rollback schedules no message. Mail delivery is best-effort and asynchronous. Slow or failed SMTP cannot change the HTTP response, cookies or persisted session. Escape dynamic HTML; exclude credentials and raw exception details from logs. A single alert can identify both reasons. The shared vectors specify acceptance targets for both clients and all native backends.
