#!/usr/bin/env bash
# Setiap RPC yang dipanggil dari lib/ wajib ada di allowlist authenticated (migration 14.16).
set -euo pipefail
cd "$(dirname "$0")/.."

MIG=$(ls supabase/migrations/*_rls_grants.sql)
allow=$(python3 - "$MIG" <<'PY'
import glob, re, sys
s = open(sys.argv[1]).read()
m = re.search(r"v_client\s+TEXT\[\]\s*:=\s*ARRAY\[(.*?)\];", s, re.S)
body = re.sub(r"--[^\n]*", "", m.group(1))
names = set(re.findall(r"'([a-z0-9_]+)'", body))
# Migration setelah 16 menambah RPC lewat GRANT eksplisit
for f in sorted(glob.glob("supabase/migrations/*.sql")):
    if f > sys.argv[1]:
        names |= set(re.findall(r"GRANT EXECUTE ON FUNCTION (?:public\.)?([a-z0-9_]+)\([^)]*\) TO authenticated", open(f).read()))
print("\n".join(sorted(names)))
PY
)

used=$(grep -rhoE "(\.rpc|rpcMap|rpcList)(<[^>]*>)?\(\s*'[a-z0-9_]+'" lib | sed -E "s/.*'([a-z0-9_]+)'/\1/" | sort -u)

missing=$(comm -23 <(echo "$used") <(echo "$allow"))
if [[ -n "$missing" ]]; then
  echo "✗ RPC dipanggil dari lib/ tetapi TIDAK ada di allowlist 14.16:"
  echo "$missing" | sed 's/^/    /'
  for fn in $missing; do grep -rnE "'$fn'" lib | sed 's/^/      /'; done
  exit 1
fi
echo "✓ $(echo "$used" | grep -c .) RPC yang dipakai semuanya ada di allowlist ($(echo "$allow" | grep -c .) entri)"
