#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
command -v flutter >/dev/null 2>&1 || fail 'Flutter SDK missing. Install Flutter and add its bin directory to PATH.'
[[ -f .dart_tool/package_config.json ]] || fail 'Dependencies missing. Run flutter pub get in this project first (network access may be needed).'
command -v python3 >/dev/null 2>&1 || fail 'Python 3 is required for endpoint and port checks. Install python3 first.'

# Read the same defaults as the app, then apply optional environment overrides.
mapfile -t endpoints < <(python3 - <<'PY'
import json
import os
with open('assets/config/app_config.json', encoding='utf-8') as config_file:
    defaults = json.load(config_file)['defaults']
for name, key in [('API_BASE_URL', 'apiBaseUrl'), ('WS_BASE_URL', 'wsBaseUrl'), ('STORAGE_BASE_URL', 'storageBaseUrl')]:
    print(os.environ.get(name) or defaults[key])
PY
)
[[ ${#endpoints[@]} -eq 3 ]] || fail 'Cannot read endpoint configuration.'
python3 - "${endpoints[@]}" <<'PY'
import socket
import sys
from urllib.parse import urlsplit
for name, value in zip(('API_BASE_URL', 'WS_BASE_URL', 'STORAGE_BASE_URL'), sys.argv[1:]):
    try:
        uri = urlsplit(value)
        schemes = ('ws', 'wss') if name == 'WS_BASE_URL' else ('http', 'https')
        valid = (uri.scheme in schemes and uri.hostname and uri.path in ('', '/')
                 and not uri.query and not uri.fragment and not uri.username
                 and not uri.password and not any(c.isspace() for c in value))
        uri.port  # Validate a supplied port as well.
    except ValueError:
        valid = False
    if not valid:
        sys.exit(f'ERROR: {name} must be an origin without /api/v2, /_ws, /storage, credentials, query, or fragment.')
try:
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 30004))
except OSError:
    sys.exit('ERROR: Port 30004 is unavailable. Stop the process using it before restarting this script.')
PY

printf '%s\n' 'Flutter Web: http://127.0.0.1:30004 (open manually once Flutter is ready).' \
    'Saved endpoint settings override these build defaults. Nuxt must be started separately.'
exec flutter run -d web-server --web-hostname 127.0.0.1 --web-port 30004 --no-pub \
    "--dart-define=API_BASE_URL=${endpoints[0]}" \
    "--dart-define=WS_BASE_URL=${endpoints[1]}" \
    "--dart-define=STORAGE_BASE_URL=${endpoints[2]}"
