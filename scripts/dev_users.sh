# scripts/dev_users.sh — lokal saja (SERVICE_ROLE_KEY dari `supabase status`)
set -euo pipefail
API="${SUPABASE_URL:-http://127.0.0.1:54321}"
for EMAIL in ade.basirwfrd@gmail.com hse.admin@dev.local reviewer@dev.local po@dev.local procurement@dev.local \
             director@dev.local rep@maju.dev.local viewer@maju.dev.local; do
  curl -sf -X POST "$API/auth/v1/admin/users" \
    -H "apikey: $SERVICE_ROLE_KEY" -H "Authorization: Bearer $SERVICE_ROLE_KEY" -H "Content-Type: application/json" \
    -d "{\"email\":\"$EMAIL\",\"password\":\"DevOnly!2026\",\"email_confirm\":true}" >/dev/null || echo "skip $EMAIL (sudah ada)"
done
psql "${DB_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}" -v ON_ERROR_STOP=1 -c "
  SELECT dev_link_google_identity('ade.basirwfrd@gmail.com');
  SELECT dev_assign_role('hse.admin@dev.local','hse_admin');
  SELECT dev_assign_role('reviewer@dev.local','hse_reviewer');
  SELECT dev_assign_role('po@dev.local','process_owner',NULL,'geozone','APAC');
  SELECT dev_assign_role('procurement@dev.local','procurement');
  SELECT dev_assign_role('director@dev.local','hse_director');
  SELECT dev_assign_role('rep@maju.dev.local','contractor_rep','00000000-0000-4000-8000-000000000001');
  SELECT dev_assign_role('viewer@maju.dev.local','contractor_viewer','00000000-0000-4000-8000-000000000001');"
