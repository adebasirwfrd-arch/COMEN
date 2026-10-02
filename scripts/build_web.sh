#!/usr/bin/env bash
# Build Flutter Web. Pemakaian: scripts/build_web.sh [production|local]
#   production → Supabase project + APP_ORIGIN Vercel, mock auth mati, lalu bundle check.
#   local      → Supabase lokal (supabase start) + mock login aktif.
set -euo pipefail
cd "$(dirname "$0")/.."
MODE="${1:-production}"

envval() { grep -E "^$2=" "$1" | head -1 | cut -d= -f2- | sed -E 's/^"(.*)"$/\1/'; }

if [[ "$MODE" == "production" ]]; then
  SUPABASE_URL="https://xyttrxynkwjfqdurscdy.supabase.co"
  SUPABASE_ANON_KEY="${SUPABASE_ANON_KEY:-$(python3 -c "import re;print(re.search(r'^anonpublic=\s*(\S+)', open('BLUEPRINT/secret.md').read(), re.M).group(1))")}"
  VAPID_PUBLIC_KEY="$(envval .env.production.local VAPID_PUBLIC_KEY)"
  APP_ORIGIN="${APP_ORIGIN:-https://comen.vercel.app}"
  MOCK=false
else
  SUPABASE_URL="http://127.0.0.1:54321"
  SUPABASE_ANON_KEY="$(supabase status -o env | grep -E '^ANON_KEY=' | cut -d= -f2- | tr -d '"')"
  VAPID_PUBLIC_KEY="$(envval supabase/functions/.env VAPID_PUBLIC_KEY)"
  APP_ORIGIN="http://localhost:3000"
  MOCK=true
fi

flutter build web --release --csp --no-web-resources-cdn --no-source-maps --no-wasm-dry-run \
  --dart-define=SUPABASE_URL="$SUPABASE_URL" \
  --dart-define=SUPABASE_ANON_KEY="$SUPABASE_ANON_KEY" \
  --dart-define=APP_ORIGIN="$APP_ORIGIN" \
  --dart-define=VAPID_PUBLIC_KEY="$VAPID_PUBLIC_KEY" \
  --dart-define=TURNSTILE_SITE_KEY="${TURNSTILE_SITE_KEY:-1x00000000000000000000AA}" \
  --dart-define=COMEN_ENV="$MODE" \
  --dart-define=COMEN_MOCK_AUTH="$MOCK"

cp vercel.json build/web/vercel.json
if [[ "$MODE" == "production" ]]; then COMEN_ENV=production scripts/check_bundle.sh build/web; fi
echo "✓ build/web siap ($MODE)"
