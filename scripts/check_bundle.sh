#!/usr/bin/env bash
# Gate G6 (22.4): build/web tidak boleh memuat rahasia, mock auth, atau kredensial dev.
set -euo pipefail

DIR="${1:-build/web}"
[[ -d "$DIR" ]] || { echo "✗ $DIR tidak ada — jalankan flutter build web dulu"; exit 2; }

fail=0
check() {
  local label="$1" pattern="$2"
  if grep -rIlF -- "$pattern" "$DIR" >/dev/null 2>&1; then
    echo "✗ $label ditemukan:"; grep -rIlF -- "$pattern" "$DIR" | sed 's/^/    /'; fail=1
  fi
}
# Pola regex: hanya nilai nyata, bukan prefix yang dicek oleh library (mis. supabase_flutter mengecek "sb_secret_").
check_re() {
  local label="$1" pattern="$2"
  if grep -rIlE -- "$pattern" "$DIR" >/dev/null 2>&1; then
    echo "✗ $label ditemukan:"; grep -rIlE -- "$pattern" "$DIR" | sed 's/^/    /'; fail=1
  fi
}

check_re "Brevo API key"         'xkeysib-[A-Za-z0-9]{16,}'
check_re "Supabase secret key"   'sb_secret_[A-Za-z0-9_-]{16,}'
check "Mock auth marker"         "COMEN_MOCK_AUTH_ENABLED"
check "Password dev"             "DevOnly!2026"
check_re "Akun dev"              '[A-Za-z0-9._%+-]+@dev\.local'
check "Turnstile secret"         "TURNSTILE_SECRET"
check "VAPID private"            "VAPID_PRIVATE"
check_re "Private key PEM"       '-----BEGIN [A-Z ]*PRIVATE KEY-----'

if [[ -n "${SUPABASE_SERVICE_ROLE_KEY:-}" ]]; then check "SUPABASE_SERVICE_ROLE_KEY" "$SUPABASE_SERVICE_ROLE_KEY"; fi

# JWT service_role (payload base64 berisi "role":"service_role")
if grep -rIoE 'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}' "$DIR" 2>/dev/null | while IFS= read -r line; do
     tok="${line#*:}"; payload="$(cut -d. -f2 <<<"$tok" | tr '_-' '/+')"
     pad=$(( (4 - ${#payload} % 4) % 4 )); payload+="$(printf '=%.0s' $(seq 1 $pad) 2>/dev/null)"
     base64 -d <<<"$payload" 2>/dev/null | grep -q '"service_role"' && echo "$line"
   done | grep -q .; then
  echo "✗ JWT service_role ditemukan di bundle"; fail=1
fi

if [[ "${COMEN_ENV:-}" == "production" ]] && grep -rIlE '127\.0\.0\.1|localhost:54321' "$DIR"/main.dart.js >/dev/null 2>&1; then
  echo "✗ COMEN_ENV=production tetapi SUPABASE_URL lokal"; fail=1
fi

if [[ $fail -eq 0 ]]; then echo "✓ Bundle check lulus ($DIR)"; fi
exit $fail
