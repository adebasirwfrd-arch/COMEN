-- supabase/seed.sql (lokal). Akun dibuat lewat GoTrue lokal: scripts/dev_users.sh (Admin API, email_confirm = true)
--   ade.basirwfrd@gmail.com · hse.admin@dev.local · reviewer@dev.local · po@dev.local · procurement@dev.local
--   director@dev.local · rep@maju.dev.local · viewer@maju.dev.local   (password: DevOnly!2026 — lokal saja)

-- Pengaman: staging/production WAJIB punya secret edge_base_url https:// (Part 20) → seed ditolak di sana
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM vault.decrypted_secrets WHERE name = 'edge_base_url' AND decrypted_secret LIKE 'https://%') THEN
    RAISE EXCEPTION 'seed.sql hanya untuk database lokal';
  END IF;
END $$;

-- Mock Login memakai password (GoTrue lokal) → izinkan HANYA di lokal
UPDATE app_settings SET value = 'true' WHERE key = 'password_login_enabled';

INSERT INTO contractors (id, legal_name, registration_no, tax_id, country, address, primary_contact_name, primary_contact_email,
                         hse_manager_name, hse_manager_email, status, submitted_at, asl_expires_on)
VALUES ('00000000-0000-4000-8000-000000000001', 'PT Maju Jaya Abadi', 'NIB-DEV-001', '01.234.567.8-901.000', 'ID',
        'Jl. Dev No. 1, Jakarta', 'Budi Rep', 'rep@maju.dev.local', 'Sari HSE', 'hse@maju.dev.local',
        'asl_approved', NOW(), CURRENT_DATE + 365)
ON CONFLICT (id) DO NOTHING;

-- Helper lokal: aktifkan user + beri role (konteks sistem → guard tetap berlaku untuk super_admin)
CREATE OR REPLACE FUNCTION dev_assign_role(p_email TEXT, p_role_key TEXT, p_contractor UUID DEFAULT NULL, p_scope_type TEXT DEFAULT 'global',
  p_scope_id TEXT DEFAULT NULL) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID;
BEGIN
  SELECT id INTO v_uid FROM profiles WHERE email = lower(p_email);
  IF v_uid IS NULL THEN RAISE EXCEPTION 'User % belum dibuat (jalankan scripts/dev_users.sh)', p_email; END IF;
  UPDATE profiles SET status = 'active', contractor_id = p_contractor, approved_at = NOW() WHERE id = v_uid;
  PERFORM _grant_role_internal(v_uid, (SELECT id FROM roles WHERE key = p_role_key), p_scope_type, p_scope_id, NULL, 'dev seed', NULL);
END $$;
REVOKE ALL ON FUNCTION dev_assign_role FROM PUBLIC, anon, authenticated, service_role;

-- Root admin lokal: tautkan identitas Google palsu (HANYA lokal) lalu jalankan onboarding normal
CREATE OR REPLACE FUNCTION dev_link_google_identity(p_email TEXT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID;
BEGIN
  SELECT id INTO v_uid FROM auth.users WHERE email = lower(p_email);
  IF v_uid IS NULL THEN RAISE EXCEPTION 'User % belum dibuat', p_email; END IF;
  INSERT INTO auth.identities (id, provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
  VALUES (gen_random_uuid(), v_uid::TEXT, v_uid,
          jsonb_build_object('sub', v_uid, 'email', lower(p_email), 'email_verified', TRUE), 'google', NOW(), NOW(), NOW())
  ON CONFLICT DO NOTHING;
  PERFORM _onboard_user(v_uid, 'google');
END $$;
REVOKE ALL ON FUNCTION dev_link_google_identity FROM PUBLIC, anon, authenticated, service_role;

-- Dijalankan setelah scripts/dev_users.sh:
--   SELECT dev_link_google_identity('ade.basirwfrd@gmail.com');
--   SELECT dev_assign_role('hse.admin@dev.local',  'hse_admin');
--   SELECT dev_assign_role('reviewer@dev.local',   'hse_reviewer');
--   SELECT dev_assign_role('po@dev.local',         'process_owner', NULL, 'geozone', 'APAC');
--   SELECT dev_assign_role('procurement@dev.local','procurement');
--   SELECT dev_assign_role('director@dev.local',   'hse_director');
--   SELECT dev_assign_role('rep@maju.dev.local',   'contractor_rep',    '00000000-0000-4000-8000-000000000001');
--   SELECT dev_assign_role('viewer@maju.dev.local','contractor_viewer', '00000000-0000-4000-8000-000000000001');
