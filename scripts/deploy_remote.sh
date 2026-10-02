#!/usr/bin/env bash
# Sekali jalan setelah `supabase login`: konfigurasi Auth, secret Edge, dan deploy 7 Edge Function ke production.
# Migration & Vault sudah di-push lewat koneksi database (supabase db push --db-url).
set -euo pipefail
cd "$(dirname "$0")/.."

REF="xyttrxynkwjfqdurscdy"
[[ -f .env.production.local ]] || { echo "✗ .env.production.local tidak ada"; exit 1; }
[[ -f BLUEPRINT/secret.md ]] || { echo "✗ BLUEPRINT/secret.md tidak ada"; exit 1; }

# bash 3.2 (macOS) salah mem-parse heredoc di dalam $(...) → tulis ke file sementara lalu source
TMP_ENV="$(mktemp)"; chmod 600 "$TMP_ENV"; trap 'rm -f "$TMP_ENV"' EXIT
python3 - > "$TMP_ENV" <<'PY'
import json, re, shlex
s = open('BLUEPRINT/secret.md').read()
g = json.loads(s[s.index('{'):s.rindex('}') + 1])['web']
pw = re.search(r'^Password=\s*(.+?)\s*$', s, re.M).group(1)
print(f"export GOOGLE_CLIENT_ID={shlex.quote(g['client_id'])}")
print(f"export GOOGLE_CLIENT_SECRET={shlex.quote(g['client_secret'])}")
print(f"export SUPABASE_DB_PASSWORD={shlex.quote(pw)}")
for line in open('.env.production.local'):
    line = line.strip()
    if line.startswith('TURNSTILE_SECRET_KEY='):
        print(f"export TURNSTILE_SECRET_KEY={shlex.quote(line.split('=', 1)[1])}")
PY
# shellcheck disable=SC1090
source "$TMP_ENV"

echo "→ link project $REF"
supabase link --project-ref "$REF" -p "$SUPABASE_DB_PASSWORD" >/dev/null

echo "→ push konfigurasi Auth (site URL, redirect, Google, Turnstile captcha, MFA TOTP, JWT 900 s)"
supabase config push --project-ref "$REF" --yes

echo "→ set secret Edge Function"
supabase secrets set --project-ref "$REF" --env-file .env.production.local >/dev/null

echo "→ deploy Edge Functions"
for fn in notify-dispatch audit-anchor submit-registration admin-actions inbound-email brevo-webhook mfa-recovery; do
  supabase functions deploy "$fn" --project-ref "$REF" --no-verify-jwt
done

echo "✓ Selesai. Langkah manual tersisa: Google Cloud Console → Authorized redirect URI"
echo "  https://$REF.supabase.co/auth/v1/callback ; Realtime 'Allow public access' OFF ; JWT signing key ES256."
