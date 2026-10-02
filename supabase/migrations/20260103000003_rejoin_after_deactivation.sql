-- v3.4.1 · Akun nonaktif (deactivated, mis. resign) tidak di-ban; login ulang = mulai lagi sebagai akun baru (pending).
-- Suspend tetap ban. Anonimisasi tetap permanen.

-- ═════════════ STATUS AKUN ═════════════
-- Hanya suspend yang mem-ban identitas Auth; deactivate & reactivate → unban (Edge admin-actions membaca 'ban')
CREATE OR REPLACE FUNCTION admin_set_user_status(p_user UUID, p_status account_status, p_reason TEXT) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_access('admin.users.suspend'); v_reason TEXT := _require_reason(p_reason); v_p profiles;
BEGIN
  IF p_status NOT IN ('active','suspended','deactivated') THEN RAISE EXCEPTION 'Status tidak valid' USING ERRCODE = '22023'; END IF;
  IF p_user = v_uid THEN PERFORM _deny('forbidden', 'Tidak bisa mengubah status sendiri'); END IF;
  PERFORM _assert_not_root_target(p_user);
  SELECT * INTO v_p FROM profiles WHERE id = p_user FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'User tidak ditemukan' USING ERRCODE = '22023'; END IF;
  IF v_p.status = 'pending' OR v_p.status = 'rejected' THEN RAISE EXCEPTION 'Gunakan User Approval untuk akun pending/rejected' USING ERRCODE = '22023'; END IF;
  IF v_p.anonymized_at IS NOT NULL THEN RAISE EXCEPTION 'Akun sudah dianonimkan' USING ERRCODE = '22023'; END IF;
  UPDATE profiles SET status = p_status, status_reason = v_reason,
                      sessions_valid_after = CASE WHEN p_status <> 'active' THEN NOW() ELSE sessions_valid_after END
  WHERE id = p_user;
  PERFORM _security_event(p_user, 'user_status', CASE WHEN p_status = 'active' THEN 'info' ELSE 'warning' END,
                          jsonb_build_object('status', p_status, 'reason', v_reason, 'by', v_uid));
  IF p_status = 'suspended' THEN
    PERFORM _email(7004, v_p.email, jsonb_build_object('name', v_p.full_name), 'suspended:' || p_user || ':' || extract(epoch FROM NOW())::BIGINT);
  END IF;
  PERFORM _rt_send('user:' || p_user, 'session_check', '{}'::jsonb);
  RETURN jsonb_build_object('user_id', p_user, 'status', p_status, 'ban', p_status = 'suspended');
END $$;

-- ═════════════ GABUNG ULANG ═════════════
-- Lepas semua afiliasi lama: role, perusahaan (trigger profil mengeluarkan dari chat perusahaan & menonaktifkan level), push.
CREATE OR REPLACE FUNCTION _rejoin_user(p_uid UUID) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_p profiles; v_roles JSONB;
BEGIN
  SELECT * INTO v_p FROM profiles WHERE id = p_uid FOR UPDATE;
  IF NOT FOUND OR v_p.status <> 'deactivated' OR v_p.anonymized_at IS NOT NULL OR v_p.is_root_admin THEN RETURN; END IF;
  SELECT COALESCE(jsonb_agg(r.key ORDER BY r.key), '[]'::jsonb) INTO v_roles
  FROM user_roles ur JOIN roles r ON r.id = ur.role_id WHERE ur.user_id = p_uid;
  DELETE FROM user_roles WHERE user_id = p_uid;
  DELETE FROM push_subscriptions WHERE user_id = p_uid;
  UPDATE profiles SET status = 'pending', status_reason = NULL, contractor_id = NULL, approved_by = NULL, approved_at = NULL
  WHERE id = p_uid;
  PERFORM _security_event(p_uid, 'user_rejoined', 'info', jsonb_build_object(
    'previous_contractor', v_p.contractor_id, 'previous_reason', v_p.status_reason, 'previous_roles', v_roles));
END $$;

CREATE OR REPLACE FUNCTION _onboard_user(p_uid UUID, p_signup_provider TEXT DEFAULT NULL) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_p profiles; v_confirmed BOOLEAN; v_inv user_invites; v_role roles; v_rejoined BOOLEAN := FALSE;
BEGIN
  SELECT * INTO v_p FROM profiles WHERE id = p_uid FOR UPDATE;
  IF NOT FOUND OR v_p.anonymized_at IS NOT NULL THEN RETURN; END IF;
  SELECT email_confirmed_at IS NOT NULL INTO v_confirmed FROM auth.users WHERE id = p_uid;

  -- (A) Root admin: email allowlist + identitas Google terverifikasi
  IF EXISTS (SELECT 1 FROM admin_allowlist WHERE email = v_p.email)
     AND (_is_allowlisted_google(p_uid) OR (p_signup_provider = 'google' AND v_confirmed)) THEN
    DELETE FROM user_roles ur USING roles r WHERE ur.role_id = r.id AND ur.user_id = p_uid AND NOT r.is_wfrd;
    IF NOT v_p.is_root_admin OR v_p.status <> 'active' OR v_p.contractor_id IS NOT NULL THEN
      UPDATE profiles SET is_root_admin = TRUE, status = 'active', contractor_id = NULL, status_reason = NULL,
                          approved_at = COALESCE(approved_at, NOW())
      WHERE id = p_uid;
      PERFORM _security_event(p_uid, 'root_admin_activated', 'warning', jsonb_build_object('email', v_p.email));
    END IF;
    PERFORM _grant_role_internal(p_uid, (SELECT id FROM roles WHERE key = 'super_admin'), 'global', NULL, NULL,
                                 'Root admin (admin_allowlist)', NULL);
    RETURN;
  END IF;

  -- (A2) Mantan user (deactivated) login ulang sendiri dengan login segar setelah dinonaktifkan → akun baru (pending).
  --      Sesi lama (auth_time ≤ sessions_valid_after) & pemanggilan atas nama admin tidak memicu ini.
  IF v_p.status = 'deactivated' AND v_confirmed AND auth.uid() = p_uid
     AND COALESCE(jwt_auth_time(), '-infinity'::TIMESTAMPTZ) > v_p.sessions_valid_after THEN
    PERFORM _rejoin_user(p_uid);
    SELECT * INTO v_p FROM profiles WHERE id = p_uid;
    v_rejoined := TRUE;
  END IF;

  IF v_p.status <> 'pending' OR NOT v_confirmed THEN RETURN; END IF;

  -- (B) Undangan aktif untuk email terverifikasi
  SELECT * INTO v_inv FROM user_invites
  WHERE email = v_p.email AND accepted_at IS NULL AND revoked_at IS NULL AND expires_at > NOW()
  FOR UPDATE;
  IF FOUND THEN
    SELECT * INTO v_role FROM roles WHERE id = v_inv.role_id;
    UPDATE profiles SET status = 'active', status_reason = NULL,
                        contractor_id = CASE WHEN v_role.is_wfrd THEN NULL ELSE v_inv.contractor_id END,
                        approved_by = v_inv.invited_by, approved_at = NOW()
    WHERE id = p_uid;
    PERFORM _grant_role_internal(p_uid, v_inv.role_id, v_inv.scope_type, v_inv.scope_id, v_inv.role_expires_at,
                                 'Undangan ' || v_inv.id, v_inv.invited_by);
    UPDATE user_invites SET accepted_at = NOW(), accepted_by = p_uid WHERE id = v_inv.id;
    PERFORM _security_event(p_uid, 'user_status', 'info', jsonb_build_object('status', 'active', 'via', 'invite', 'invite', v_inv.id));
    PERFORM _notify(p_uid, 'account_approved', 'Akun Anda aktif', 'Selamat datang di COMEN.', '/', 'info', 7003,
                    jsonb_build_object('name', v_p.full_name), 'approved:' || p_uid || CASE WHEN v_rejoined THEN ':' || v_inv.id ELSE '' END);
    PERFORM _after_activation(p_uid);
    RETURN;
  END IF;

  -- (C) Pending → antrian approval (user baru sekali; mantan user setiap kali bergabung ulang)
  IF v_rejoined THEN
    PERFORM _notify_permission_holders('admin.users.approve', NULL, 'user_pending', 'Mantan user mendaftar ulang',
                                       v_p.email, '/admin/approvals', 'info', 7001,
                                       jsonb_build_object('email', v_p.email, 'name', v_p.full_name),
                                       'rejoin:' || p_uid || ':' || extract(epoch FROM NOW())::BIGINT);
  ELSIF NOT EXISTS (SELECT 1 FROM security_events WHERE user_id = p_uid AND event = 'new_pending_user') THEN
    PERFORM _security_event(p_uid, 'new_pending_user', 'info',
                            jsonb_build_object('email', v_p.email, 'provider', p_signup_provider));
    PERFORM _notify_permission_holders('admin.users.approve', NULL, 'user_pending', 'User baru menunggu persetujuan',
                                       v_p.email, '/admin/approvals', 'info', 7001,
                                       jsonb_build_object('email', v_p.email, 'name', v_p.full_name), 'pending:' || p_uid);
  END IF;
END $$;

-- ═════════════ UNDANGAN ═════════════
-- Email mantan user (deactivated, belum dianonimkan) boleh diundang ulang: undangan diterapkan saat ia login & bergabung ulang
CREATE OR REPLACE FUNCTION admin_create_invite(p_email TEXT, p_role_key TEXT, p_scope_type TEXT, p_scope_id TEXT,
  p_contractor UUID, p_role_expires_at TIMESTAMPTZ, p_note TEXT, p_reason TEXT,
  p_contractor_level contractor_user_level DEFAULT NULL) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_access('admin.invites.manage'); v_reason TEXT := _require_reason(p_reason);
        v_email TEXT := _clean_email(p_email, TRUE); v_role roles; v_st TEXT; v_sid TEXT; v_cid UUID; v_id UUID; v_existing UUID;
BEGIN
  PERFORM hit_rate_limit('invite:' || v_uid, 50, INTERVAL '1 hour');
  SELECT * INTO v_role FROM roles WHERE key = p_role_key;
  IF NOT FOUND THEN RAISE EXCEPTION 'Role tidak dikenal' USING ERRCODE = '22023'; END IF;
  PERFORM _assert_can_grant(v_role.id);
  IF EXISTS (SELECT 1 FROM profiles WHERE email = v_email AND status <> 'pending'
               AND NOT (status = 'deactivated' AND anonymized_at IS NULL)) THEN
    RAISE EXCEPTION 'Email sudah memiliki akun (gunakan Users & Access)' USING ERRCODE = '22023';
  END IF;
  IF v_role.is_wfrd THEN
    IF p_contractor IS NOT NULL THEN RAISE EXCEPTION 'Role WFRD tidak boleh terhubung ke contractor' USING ERRCODE = '22023'; END IF;
    IF p_contractor_level IS NOT NULL THEN RAISE EXCEPTION 'Level contractor hanya untuk role contractor' USING ERRCODE = '22023'; END IF;
    v_st := COALESCE(p_scope_type, 'global'); v_sid := CASE WHEN v_st = 'global' THEN NULL ELSE p_scope_id END;
    PERFORM _validate_scope(v_st, v_sid);
  ELSE
    IF p_contractor IS NULL OR NOT EXISTS (SELECT 1 FROM contractors WHERE id = p_contractor) THEN
      RAISE EXCEPTION 'Role contractor wajib memilih contractor' USING ERRCODE = '22023';
    END IF;
    IF p_contractor_level IS NULL THEN
      RAISE EXCEPTION 'Level user contractor (PIC / Supervisor / Employee) wajib dipilih' USING ERRCODE = '22023'; END IF;
    IF p_contractor_level = 'pic' AND NOT has_permission('level.pic.set') THEN
      PERFORM _deny('forbidden', 'Menetapkan level PIC membutuhkan permission level.pic.set'); END IF;
    v_st := 'global'; v_sid := NULL; v_cid := p_contractor;
  END IF;
  UPDATE user_invites SET revoked_at = NOW() WHERE email = v_email AND accepted_at IS NULL AND revoked_at IS NULL;
  INSERT INTO user_invites (email, role_id, scope_type, scope_id, contractor_id, role_expires_at, note, invited_by, contractor_level)
  VALUES (v_email, v_role.id, v_st, v_sid, v_cid, p_role_expires_at, _clean_text(p_note, 500), v_uid, p_contractor_level)
  RETURNING id INTO v_id;
  PERFORM _email(1007, v_email, jsonb_build_object('role', v_role.name, 'link', '/invite?email=' || replace(replace(v_email, '%', '%25'), '+', '%2B'),
                 'company', (SELECT legal_name FROM contractors WHERE id = v_cid)), 'invite:' || v_id);
  SELECT id INTO v_existing FROM profiles WHERE email = v_email AND status = 'pending';
  IF v_existing IS NOT NULL THEN PERFORM _onboard_user(v_existing, NULL); END IF;     -- user pending terverifikasi langsung aktif
  RETURN v_id;
END $$;

REVOKE ALL ON FUNCTION _rejoin_user(UUID) FROM PUBLIC, anon, authenticated, service_role;
