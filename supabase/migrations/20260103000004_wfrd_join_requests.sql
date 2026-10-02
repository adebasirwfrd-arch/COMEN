-- v3.4.2 · Pendaftaran karyawan Weatherford (WFRD): user pending memilih "Karyawan Weatherford" atau "Contractor".
-- Karyawan WFRD mengisi data kepegawaian (bukan data perusahaan); Admin memverifikasi lalu approve dengan role WFRD.

-- ═════════════ TABEL ═════════════
CREATE TABLE IF NOT EXISTS wfrd_join_requests (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id            UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  full_name          TEXT NOT NULL CHECK (length(full_name) BETWEEN 2 AND 120),
  employee_id        TEXT NOT NULL CHECK (employee_id ~ '^[A-Za-z0-9][A-Za-z0-9._/-]{1,39}$'),
  work_email         TEXT CHECK (work_email IS NULL OR work_email = lower(work_email)),
  job_title          TEXT NOT NULL CHECK (length(job_title) BETWEEN 2 AND 120),
  department         TEXT NOT NULL CHECK (length(department) BETWEEN 2 AND 120),
  geozone            TEXT NOT NULL REFERENCES geozones(code),
  work_location      TEXT CHECK (length(work_location) <= 120),
  line_manager_name  TEXT NOT NULL CHECK (length(line_manager_name) BETWEEN 2 AND 120),
  line_manager_email TEXT NOT NULL CHECK (line_manager_email = lower(line_manager_email)),
  phone_enc          BYTEA,
  enc_key_ver        SMALLINT NOT NULL DEFAULT 1,
  requested_role_key TEXT REFERENCES roles(key) ON UPDATE CASCADE ON DELETE SET NULL,
  note               TEXT CHECK (length(note) <= 1000),
  status             TEXT NOT NULL DEFAULT 'submitted' CHECK (status IN ('submitted','approved','rejected','withdrawn')),
  decided_by         UUID REFERENCES profiles(id),
  decided_at         TIMESTAMPTZ,
  decision_note      TEXT,
  submitted_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at         TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_wfrd_join_open ON wfrd_join_requests (user_id) WHERE status = 'submitted';
CREATE INDEX IF NOT EXISTS idx_wfrd_join_user ON wfrd_join_requests (user_id, created_at DESC);
-- Tanpa GRANT ke authenticated: dibaca/ditulis hanya lewat RPC
ALTER TABLE wfrd_join_requests ENABLE ROW LEVEL SECURITY;
COMMENT ON TABLE wfrd_join_requests IS 'Pengajuan akses karyawan Weatherford oleh user pending — RPC-only';
DROP TRIGGER IF EXISTS trg_updated_at ON wfrd_join_requests;
CREATE TRIGGER trg_updated_at BEFORE UPDATE ON wfrd_join_requests FOR EACH ROW EXECUTE FUNCTION _touch_updated_at();
DROP TRIGGER IF EXISTS trg_audit ON wfrd_join_requests;
CREATE TRIGGER trg_audit AFTER INSERT OR UPDATE OR DELETE ON wfrd_join_requests FOR EACH ROW EXECUTE FUNCTION log_change('id');

CREATE OR REPLACE FUNCTION _wfrd_request_json(r wfrd_join_requests) RETURNS JSONB
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT CASE WHEN r.id IS NULL THEN NULL ELSE jsonb_build_object(
    'id', r.id, 'status', r.status, 'full_name', r.full_name, 'employee_id', r.employee_id, 'work_email', r.work_email,
    'job_title', r.job_title, 'department', r.department, 'geozone', r.geozone,
    'geozone_name', (SELECT g.name FROM geozones g WHERE g.code = r.geozone), 'work_location', r.work_location,
    'line_manager_name', r.line_manager_name, 'line_manager_email', r.line_manager_email,
    'phone', _decrypt(r.phone_enc, 'data', r.enc_key_ver),
    'requested_role_key', r.requested_role_key,
    'requested_role_name', (SELECT x.name FROM roles x WHERE x.key = r.requested_role_key),
    'note', r.note, 'submitted_at', r.submitted_at) END
$$;

-- ═════════════ SELF-SERVICE (user pending) ═════════════
CREATE OR REPLACE FUNCTION get_my_wfrd_request() RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := _assert_self_service(FALSE); v_p profiles; v_r wfrd_join_requests;
BEGIN
  SELECT * INTO v_p FROM profiles WHERE id = v_uid;
  SELECT * INTO v_r FROM wfrd_join_requests WHERE user_id = v_uid AND status = 'submitted';
  RETURN jsonb_build_object(
    'request', _wfrd_request_json(v_r),
    'profile', jsonb_build_object('full_name', v_p.full_name, 'email', v_p.email),
    'contractor_draft', (SELECT jsonb_build_object('legal_name', c.legal_name, 'status', c.status)
                         FROM contractors c WHERE c.id = v_p.contractor_id),
    'geozones', (SELECT COALESCE(jsonb_agg(jsonb_build_object('code', code, 'name', name) ORDER BY code), '[]'::jsonb)
                 FROM geozones WHERE active),
    'roles', (SELECT COALESCE(jsonb_agg(jsonb_build_object('key', key, 'name', name, 'description', description) ORDER BY name), '[]'::jsonb)
              FROM roles WHERE is_wfrd AND key <> 'super_admin'));
END $$;

CREATE OR REPLACE FUNCTION submit_wfrd_join_request(p_data JSONB) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_uid UUID := _assert_self_service(TRUE); v_p profiles; v_c contractors; v_id UUID; v_ver SMALLINT := _active_key_ver('data');
  v_emp TEXT := _clean_text(p_data ->> 'employee_id', 40, TRUE);
  v_geo TEXT := upper(_clean_text(p_data ->> 'geozone', 20, TRUE));
  v_phone TEXT := _clean_text(p_data ->> 'phone', 20);
  v_role TEXT := _clean_text(p_data ->> 'requested_role_key', 40);
  v_name TEXT := _clean_text(p_data ->> 'full_name', 120, TRUE);
BEGIN
  PERFORM hit_rate_limit('wfrd_join:' || v_uid, 20, INTERVAL '1 hour');
  IF jsonb_typeof(p_data) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'Data tidak valid' USING ERRCODE = '22023'; END IF;
  SELECT * INTO v_p FROM profiles WHERE id = v_uid FOR UPDATE;
  IF v_p.status <> 'pending' THEN RAISE EXCEPTION 'Hanya untuk akun yang menunggu persetujuan' USING ERRCODE = '22023'; END IF;
  IF p_data -> 'privacy_accepted' IS DISTINCT FROM 'true'::jsonb THEN
    RAISE EXCEPTION 'Privacy Notice wajib disetujui' USING ERRCODE = '22023'; END IF;
  IF length(v_name) < 2 THEN RAISE EXCEPTION 'Nama lengkap wajib' USING ERRCODE = '22023'; END IF;
  IF v_emp !~ '^[A-Za-z0-9][A-Za-z0-9._/-]{1,39}$' THEN
    RAISE EXCEPTION 'Employee ID tidak valid (huruf/angka, 2–40 karakter)' USING ERRCODE = '22023'; END IF;
  IF NOT EXISTS (SELECT 1 FROM geozones WHERE code = v_geo AND active) THEN RAISE EXCEPTION 'Geozone tidak valid' USING ERRCODE = '22023'; END IF;
  IF v_phone IS NOT NULL AND v_phone !~ '^\+?[0-9 ()-]{6,20}$' THEN RAISE EXCEPTION 'Nomor telepon tidak valid' USING ERRCODE = '22023'; END IF;
  IF v_role IS NOT NULL AND NOT EXISTS (SELECT 1 FROM roles WHERE key = v_role AND is_wfrd AND key <> 'super_admin') THEN
    RAISE EXCEPTION 'Role yang diminta tidak valid' USING ERRCODE = '22023'; END IF;

  -- Registrasi perusahaan yang sudah dikirim harus diputuskan Admin dulu; draft milik sendiri dilepas
  IF v_p.contractor_id IS NOT NULL THEN
    SELECT * INTO v_c FROM contractors WHERE id = v_p.contractor_id FOR UPDATE;
    IF v_c.status <> 'draft' THEN
      RAISE EXCEPTION 'Anda sudah mengirim registrasi perusahaan %. Hubungi Admin WFRD untuk membatalkannya.', v_c.legal_name
        USING ERRCODE = '22023'; END IF;
    UPDATE profiles SET contractor_id = NULL WHERE id = v_uid;
    IF v_c.registered_by = v_uid AND NOT EXISTS (SELECT 1 FROM profiles WHERE contractor_id = v_c.id) THEN
      BEGIN
        DELETE FROM contractors WHERE id = v_c.id;
      EXCEPTION WHEN foreign_key_violation THEN NULL;
      END;
    END IF;
  END IF;

  UPDATE wfrd_join_requests SET status = 'withdrawn', decided_at = NOW(), decision_note = 'Diganti pengajuan baru'
  WHERE user_id = v_uid AND status = 'submitted';
  INSERT INTO wfrd_join_requests (user_id, full_name, employee_id, work_email, job_title, department, geozone, work_location,
                                  line_manager_name, line_manager_email, phone_enc, enc_key_ver, requested_role_key, note)
  VALUES (v_uid, v_name, v_emp, _clean_email(p_data ->> 'work_email', FALSE),
          _clean_text(p_data ->> 'job_title', 120, TRUE), _clean_text(p_data ->> 'department', 120, TRUE), v_geo,
          _clean_text(p_data ->> 'work_location', 120),
          _clean_text(p_data ->> 'line_manager_name', 120, TRUE), _clean_email(p_data ->> 'line_manager_email', TRUE),
          CASE WHEN v_phone IS NULL THEN NULL ELSE _encrypt(v_phone, 'data', v_ver) END, v_ver, v_role,
          _clean_text(p_data ->> 'note', 1000))
  RETURNING id INTO v_id;
  UPDATE profiles SET full_name = v_name, privacy_accepted_at = COALESCE(privacy_accepted_at, NOW()) WHERE id = v_uid;

  PERFORM _security_event(v_uid, 'wfrd_join_request', 'info', jsonb_build_object('request', v_id, 'employee_id', v_emp, 'geozone', v_geo));
  PERFORM _notify_permission_holders('admin.users.approve', NULL, 'user_pending', 'Karyawan Weatherford minta akses',
                                     v_name || ' · ' || v_p.email || ' · ' || v_emp, '/admin/approvals', 'info', NULL,
                                     '{}'::jsonb, 'wfrdreq:' || v_id);
  RETURN jsonb_build_object('id', v_id, 'status', 'submitted');
END $$;

CREATE OR REPLACE FUNCTION withdraw_wfrd_join_request() RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := _assert_self_service(TRUE);
BEGIN
  UPDATE wfrd_join_requests SET status = 'withdrawn', decided_at = NOW(), decision_note = 'Dibatalkan pemohon'
  WHERE user_id = v_uid AND status = 'submitted';
  IF NOT FOUND THEN RAISE EXCEPTION 'Tidak ada pengajuan karyawan WFRD yang aktif' USING ERRCODE = '22023'; END IF;
END $$;

-- Alur contractor tertutup selama pengajuan karyawan WFRD aktif (salinan v3.0 + guard di awal)
CREATE OR REPLACE FUNCTION save_registration_draft(p_data JSONB) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_uid UUID := _assert_self_service(TRUE); v_cid UUID; v_c contractors; v_ver SMALLINT := _active_key_ver('data');
  v_country TEXT := upper(_clean_text(p_data ->> 'country', 2)); v_phone TEXT := _clean_text(p_data ->> 'primary_contact_phone', 20);
  v_pc_email TEXT := _clean_email(p_data ->> 'primary_contact_email', FALSE);
BEGIN
  PERFORM hit_rate_limit('reg_draft:' || v_uid, 120, INTERVAL '1 hour');
  IF EXISTS (SELECT 1 FROM wfrd_join_requests WHERE user_id = v_uid AND status = 'submitted') THEN
    RAISE EXCEPTION 'Anda sedang mengajukan akses sebagai karyawan Weatherford. Batalkan pengajuan itu dulu untuk mendaftar sebagai contractor.'
      USING ERRCODE = '22023';
  END IF;
  IF jsonb_typeof(p_data) <> 'object' THEN RAISE EXCEPTION 'Data tidak valid' USING ERRCODE = '22023'; END IF;
  IF v_country IS NOT NULL AND v_country !~ '^[A-Z]{2}$' THEN RAISE EXCEPTION 'Kode negara ISO-2 tidak valid' USING ERRCODE = '22023'; END IF;
  IF v_phone IS NOT NULL AND v_phone !~ '^\+?[0-9 ()-]{6,20}$' THEN RAISE EXCEPTION 'Nomor telepon tidak valid' USING ERRCODE = '22023'; END IF;
  IF p_data ? 'website' AND NULLIF(p_data ->> 'website', '') IS NOT NULL AND p_data ->> 'website' !~* '^https?://' THEN
    RAISE EXCEPTION 'Website harus diawali http(s)://' USING ERRCODE = '22023'; END IF;

  SELECT contractor_id INTO v_cid FROM profiles WHERE id = v_uid;
  IF v_cid IS NULL THEN
    INSERT INTO contractors (legal_name, registered_by) VALUES (_clean_text(p_data ->> 'legal_name', 200, TRUE), v_uid)
    RETURNING id INTO v_cid;
    UPDATE profiles SET contractor_id = v_cid WHERE id = v_uid;
  END IF;
  SELECT * INTO v_c FROM contractors WHERE id = v_cid FOR UPDATE;
  IF v_c.status <> 'draft' THEN RAISE EXCEPTION 'Registrasi sudah dikirim; perubahan via profil perusahaan' USING ERRCODE = '22023'; END IF;

  BEGIN
    UPDATE contractors SET
      legal_name            = CASE WHEN p_data ? 'legal_name' THEN _clean_text(p_data ->> 'legal_name', 200, TRUE) ELSE legal_name END,
      trading_name          = CASE WHEN p_data ? 'trading_name' THEN _clean_text(p_data ->> 'trading_name', 200) ELSE trading_name END,
      registration_no       = CASE WHEN p_data ? 'registration_no' THEN _clean_text(p_data ->> 'registration_no', 60) ELSE registration_no END,
      tax_id                = CASE WHEN p_data ? 'tax_id' THEN _clean_text(p_data ->> 'tax_id', 40) ELSE tax_id END,
      country               = CASE WHEN p_data ? 'country' THEN v_country ELSE country END,
      address               = CASE WHEN p_data ? 'address' THEN _clean_text(p_data ->> 'address', 500) ELSE address END,
      website               = CASE WHEN p_data ? 'website' THEN _clean_text(p_data ->> 'website', 300) ELSE website END,
      primary_contact_name  = CASE WHEN p_data ? 'primary_contact_name' THEN _clean_text(p_data ->> 'primary_contact_name', 120) ELSE primary_contact_name END,
      primary_contact_email = CASE WHEN p_data ? 'primary_contact_email' THEN v_pc_email ELSE primary_contact_email END,
      email_domain          = CASE WHEN p_data ? 'primary_contact_email' THEN split_part(v_pc_email, '@', 2) ELSE email_domain END,
      primary_contact_phone_enc = CASE WHEN p_data ? 'primary_contact_phone' THEN _encrypt(v_phone, 'data', v_ver) ELSE primary_contact_phone_enc END,
      enc_key_ver           = CASE WHEN p_data ? 'primary_contact_phone' THEN v_ver ELSE enc_key_ver END,
      hse_manager_name      = CASE WHEN p_data ? 'hse_manager_name' THEN _clean_text(p_data ->> 'hse_manager_name', 120) ELSE hse_manager_name END,
      hse_manager_email     = CASE WHEN p_data ? 'hse_manager_email' THEN _clean_email(p_data ->> 'hse_manager_email', FALSE) ELSE hse_manager_email END,
      updated_at = NOW()
    WHERE id = v_cid;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'Tax ID sudah terdaftar untuk negara ini' USING ERRCODE = '23505', HINT = 'duplicate_tax_id';
  END;
  RETURN jsonb_build_object('contractor_id', v_cid, 'tracking_id', 'CMN-V' || lpad(v_c.vendor_seq::TEXT, 5, '0'));
END $$;

-- ═════════════ KEPUTUSAN ADMIN ═════════════
-- Approve/tolak/undangan menutup pengajuan; approve sebagai WFRD mengisi jabatan & geozone profil bila kosong
CREATE OR REPLACE FUNCTION _profiles_wfrd_request() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_r wfrd_join_requests;
BEGIN
  SELECT * INTO v_r FROM wfrd_join_requests WHERE user_id = NEW.id AND status = 'submitted' FOR UPDATE;
  IF NOT FOUND THEN RETURN NEW; END IF;
  UPDATE wfrd_join_requests
  SET status = CASE WHEN NEW.status = 'active' THEN 'approved' ELSE 'rejected' END,
      decided_by = COALESCE(auth.uid(), NEW.approved_by), decided_at = NOW(),
      decision_note = CASE WHEN NEW.status = 'active' THEN NULL ELSE NEW.status_reason END
  WHERE id = v_r.id;
  IF NEW.status = 'active' AND NEW.contractor_id IS NULL THEN
    NEW.job_title := COALESCE(NEW.job_title, v_r.job_title);
    NEW.geozone := COALESCE(NEW.geozone, v_r.geozone);
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_profiles_wfrd_request ON profiles;
CREATE TRIGGER trg_profiles_wfrd_request BEFORE UPDATE OF status ON profiles
  FOR EACH ROW WHEN (OLD.status = 'pending' AND NEW.status IN ('active','rejected'))
  EXECUTE FUNCTION _profiles_wfrd_request();

-- Antrean approval menampilkan pengajuan karyawan WFRD (salinan v3.3 + kolom wfrd_request)
CREATE OR REPLACE FUNCTION admin_list_users(p_status account_status DEFAULT NULL, p_search TEXT DEFAULT NULL,
  p_contractor UUID DEFAULT NULL, p_limit INT DEFAULT 50, p_offset INT DEFAULT 0) RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_q TEXT := _clean_text(p_search, 100);
BEGIN
  PERFORM assert_access('admin.users.view', NULL, FALSE);
  RETURN (SELECT COALESCE(jsonb_agg(row_to_json(x)), '[]'::jsonb) FROM (
    SELECT p.id, p.email, p.full_name, p.avatar_url, p.status, p.status_reason, p.is_root_admin, p.contractor_id,
           c.legal_name AS contractor_name, c.status AS vendor_status, p.last_login_at, p.created_at,
           _contractor_level_of(p.id) AS contractor_level,
           (SELECT i.provider FROM auth.identities i WHERE i.user_id = p.id ORDER BY i.created_at LIMIT 1) AS provider,
           EXISTS (SELECT 1 FROM auth.mfa_factors f WHERE f.user_id = p.id AND f.status = 'verified') AS mfa_enrolled,
           (SELECT count(*) FROM trusted_devices d WHERE d.user_id = p.id AND d.revoked_at IS NULL) AS devices,
           (SELECT count(*) FROM profiles q WHERE q.status = 'pending' AND split_part(q.email, '@', 2) = split_part(p.email, '@', 2)) AS same_domain_pending,
           EXISTS (SELECT 1 FROM contractors k WHERE k.email_domain = split_part(p.email, '@', 2) AND k.status <> 'draft') AS domain_matches_contractor,
           (SELECT jsonb_agg(jsonb_build_object('id', ur.id, 'role', r.key, 'scope_type', ur.scope_type, 'scope_id', ur.scope_id, 'expires_at', ur.expires_at))
              FROM user_roles ur JOIN roles r ON r.id = ur.role_id WHERE ur.user_id = p.id) AS roles,
           (SELECT _wfrd_request_json(w) FROM wfrd_join_requests w WHERE w.user_id = p.id AND w.status = 'submitted') AS wfrd_request
    FROM profiles p LEFT JOIN contractors c ON c.id = p.contractor_id
    WHERE (p_status IS NULL OR p.status = p_status)
      AND (p_contractor IS NULL OR p.contractor_id = p_contractor)
      AND (v_q IS NULL OR p.email ILIKE '%' || v_q || '%' OR p.full_name ILIKE '%' || v_q || '%')
    ORDER BY p.created_at DESC
    LIMIT LEAST(GREATEST(p_limit, 1), 200) OFFSET GREATEST(p_offset, 0)) x);
END $$;

-- ═════════════ PRIVILEGE ═════════════
REVOKE ALL ON TABLE wfrd_join_requests FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION _wfrd_request_json(wfrd_join_requests) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION _profiles_wfrd_request() FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION get_my_wfrd_request() FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION get_my_wfrd_request() TO authenticated;
REVOKE ALL ON FUNCTION submit_wfrd_join_request(JSONB) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION submit_wfrd_join_request(JSONB) TO authenticated;
REVOKE ALL ON FUNCTION withdraw_wfrd_join_request() FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION withdraw_wfrd_join_request() TO authenticated;
