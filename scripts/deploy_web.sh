#!/usr/bin/env bash
# Build production + deploy ke Vercel (project "comen"), lalu pasang alias comen.vercel.app.
# Prasyarat: `vercel login`, dan .vercel/project.json (vercel link --project comen) di root repo.
set -euo pipefail
cd "$(dirname "$0")/.."

ALIAS="${COMEN_ALIAS:-comen.vercel.app}"
[[ -f .vercel/project.json ]] || { echo "✗ .vercel/project.json tidak ada — jalankan: vercel link --yes --project comen"; exit 2; }

bash scripts/build_web.sh production
mkdir -p build/web/.vercel && cp .vercel/project.json build/web/.vercel/

# Output vercel berbeda di TTY (teks) dan non-TTY (JSON) → ambil URL deployment dengan regex
out="$(cd build/web && vercel deploy --prod --yes 2>&1)" || { echo "$out" | tail -20; exit 1; }
url="$(grep -Eo 'https://comen-[a-z0-9]+-[a-z0-9-]+\.vercel\.app' <<<"$out" | head -1)"
[[ -n "$url" ]] || { echo "✗ URL deployment tidak ditemukan:"; echo "$out" | tail -20; exit 1; }
echo "✓ Deploy: $url"
vercel alias set "$url" "$ALIAS" >/dev/null
echo "✓ Alias: https://$ALIAS"
