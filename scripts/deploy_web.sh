#!/usr/bin/env bash
# Build production + deploy ke Vercel (project "comen"), lalu pasang alias comen.vercel.app.
# Prasyarat: `vercel login`, dan .vercel/project.json (vercel link --project comen) di root repo.
set -euo pipefail
cd "$(dirname "$0")/.."

ALIAS="${COMEN_ALIAS:-comen.vercel.app}"
[[ -f .vercel/project.json ]] || { echo "✗ .vercel/project.json tidak ada — jalankan: vercel link --yes --project comen"; exit 2; }

bash scripts/build_web.sh production
mkdir -p build/web/.vercel && cp .vercel/project.json build/web/.vercel/

url="$(cd build/web && vercel deploy --prod --yes 2>/dev/null | python3 -c 'import sys,json,re; s=sys.stdin.read(); print(json.loads(s[re.search(r"^\{", s, re.M).start():])["deployment"]["url"])')"
echo "✓ Deploy: $url"
vercel alias set "$url" "$ALIAS" >/dev/null
echo "✓ Alias: https://$ALIAS"
