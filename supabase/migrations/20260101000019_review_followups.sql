-- ═════════════ REVIEW FOLLOW-UPS ═════════════
-- CREATE OR REPLACE mempertahankan ACL; fungsi baru di-GRANT eksplisit di bawah.

-- DSAR: hanya data milik subjek — tanpa field internal sistem / identitas admin lain
CREATE OR REPLACE FUNCTION admin_export_user_data(p_user UUID, p_reason TEXT) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_access('admin.privacy.manage'); v_reason TEXT := _require_reason(p_reason); v_p profiles;
BEGIN
  PERFORM assert_step_up();
  PERFORM hit_rate_limit('dsar:' || v_uid, 3, INTERVAL '1 hour');
  SELECT * INTO v_p FROM profiles WHERE id = p_user;
  IF NOT FOUND THEN RAISE EXCEPTION 'User tidak ditemukan' USING ERRCODE = '22023'; END IF;
  PERFORM _security_event(p_user, 'export', 'warning', jsonb_build_object('kind', 'dsar', 'reason', v_reason, 'by', v_uid));
  RETURN jsonb_build_object(
    'generated_at', NOW(),
    'profile', jsonb_build_object('id', v_p.id, 'email', v_p.email, 'full_name', v_p.full_name, 'job_title', v_p.job_title,
                 'phone', _decrypt(v_p.phone_enc, 'data', v_p.enc_key_ver), 'locale', v_p.locale, 'avatar_url', v_p.avatar_url,
                 'status', v_p.status, 'status_reason', v_p.status_reason, 'geozone', v_p.geozone,
                 'company', (SELECT legal_name FROM contractors WHERE id = v_p.contractor_id),
                 'privacy_accepted_at', v_p.privacy_accepted_at, 'approved_at', v_p.approved_at,
                 'last_login_at', v_p.last_login_at, 'created_at', v_p.created_at, 'updated_at', v_p.updated_at),
    'roles', (SELECT COALESCE(jsonb_agg(jsonb_build_object('role', r.key, 'scope_type', ur.scope_type, 'scope_id', ur.scope_id,
                     'granted_at', ur.granted_at, 'expires_at', ur.expires_at)), '[]'::jsonb)
              FROM user_roles ur JOIN roles r ON r.id = ur.role_id WHERE ur.user_id = p_user),
    'devices', (SELECT COALESCE(jsonb_agg(jsonb_build_object('label', label, 'first_seen', first_seen, 'last_seen', last_seen,
                       'revoked_at', revoked_at)), '[]'::jsonb) FROM trusted_devices WHERE user_id = p_user),
    'security_events', (SELECT COALESCE(jsonb_agg(jsonb_build_object('event', event, 'at', created_at)), '[]'::jsonb)
                        FROM security_events WHERE user_id = p_user),
    'tasks_confirmed', (SELECT COALESCE(jsonb_agg(jsonb_build_object('task_id', task_id, 'at', upload_confirmed_at)), '[]'::jsonb)
                        FROM tasks WHERE upload_confirmed_by = p_user),
    'messages', (SELECT COALESCE(jsonb_agg(jsonb_build_object('channel', channel_id, 'at', created_at,
                        'body', _decrypt(body_enc, 'chat', key_ver)) ORDER BY seq), '[]'::jsonb)
                 FROM chat_messages WHERE sender_id = p_user AND deleted_at IS NULL));
END $$;

-- Badge unread hanya pesan utama (balasan thread tidak tampil di timeline); mention di thread tetap dihitung
CREATE OR REPLACE FUNCTION list_my_channels() RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_access('chat.use', NULL, FALSE);
BEGIN
  RETURN (SELECT COALESCE(jsonb_agg(row_to_json(x) ORDER BY x.last_message_at DESC NULLS LAST), '[]'::jsonb) FROM (
    SELECT c.id, c.type, c.is_archived, c.is_locked, c.contract_id, c.task_id, c.last_message_at, m.member_role, m.notify_level, m.muted_until,
           CASE WHEN c.type = 'direct' THEN (SELECT p.full_name FROM chat_members o JOIN profiles p ON p.id = o.user_id
                                             WHERE o.channel_id = c.id AND o.user_id <> v_uid LIMIT 1) ELSE c.name END AS name,
           CASE WHEN c.type = 'direct' THEN (SELECT o.user_id FROM chat_members o WHERE o.channel_id = c.id AND o.user_id <> v_uid LIMIT 1) END AS peer_id,
           (SELECT count(*) FROM (SELECT 1 FROM chat_messages cm WHERE cm.channel_id = c.id AND cm.seq > m.last_read_seq
                                    AND cm.thread_root IS NULL
                                    AND cm.sender_id IS DISTINCT FROM v_uid AND cm.deleted_at IS NULL LIMIT 99) u) AS unread,
           (SELECT count(*) FROM chat_messages cm WHERE cm.channel_id = c.id AND cm.seq > m.last_read_seq AND v_uid = ANY(cm.mentions)) AS unread_mentions,
           (SELECT count(*) FROM chat_messages cm WHERE cm.channel_id = c.id AND cm.requires_ack AND cm.deleted_at IS NULL
              AND NOT EXISTS (SELECT 1 FROM chat_acks a WHERE a.message_id = cm.id AND a.user_id = v_uid)
              AND cm.sender_id IS DISTINCT FROM v_uid) AS pending_acks
    FROM chat_members m JOIN chat_channels c ON c.id = m.channel_id
    WHERE m.user_id = v_uid) x);
END $$;

CREATE OR REPLACE FUNCTION update_my_company(p_data JSONB) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_cid UUID := auth_contractor_id(); v_ver SMALLINT := _active_key_ver('data');
BEGIN
  PERFORM assert_access('company.edit', NULL, TRUE, v_cid);
  IF p_data ? 'primary_contact_phone' AND COALESCE(p_data ->> 'primary_contact_phone', '') !~ '^\+?[0-9 ()-]{6,20}$' THEN
    RAISE EXCEPTION 'Nomor telepon tidak valid' USING ERRCODE = '22023';
  END IF;
  UPDATE contractors SET
    trading_name          = CASE WHEN p_data ? 'trading_name' THEN _clean_text(p_data ->> 'trading_name', 200) ELSE trading_name END,
    address               = CASE WHEN p_data ? 'address' THEN _clean_text(p_data ->> 'address', 500, TRUE) ELSE address END,
    website               = CASE WHEN p_data ? 'website' THEN _clean_text(p_data ->> 'website', 300) ELSE website END,
    primary_contact_name  = CASE WHEN p_data ? 'primary_contact_name' THEN _clean_text(p_data ->> 'primary_contact_name', 120, TRUE) ELSE primary_contact_name END,
    primary_contact_email = CASE WHEN p_data ? 'primary_contact_email' THEN _clean_email(p_data ->> 'primary_contact_email', TRUE) ELSE primary_contact_email END,
    primary_contact_phone_enc = CASE WHEN p_data ? 'primary_contact_phone' THEN _encrypt(_clean_text(p_data ->> 'primary_contact_phone', 20, TRUE), 'data', v_ver) ELSE primary_contact_phone_enc END,
    enc_key_ver           = CASE WHEN p_data ? 'primary_contact_phone' THEN v_ver ELSE enc_key_ver END,
    hse_manager_name      = CASE WHEN p_data ? 'hse_manager_name' THEN _clean_text(p_data ->> 'hse_manager_name', 120, TRUE) ELSE hse_manager_name END,
    hse_manager_email     = CASE WHEN p_data ? 'hse_manager_email' THEN _clean_email(p_data ->> 'hse_manager_email', TRUE) ELSE hse_manager_email END,
    updated_at = NOW()
  WHERE id = v_cid;
END $$;

CREATE OR REPLACE FUNCTION admin_list_channels(p_search TEXT DEFAULT NULL, p_limit INT DEFAULT 100) RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
BEGIN
  PERFORM assert_access('admin.chat.manage', NULL, FALSE);
  RETURN (SELECT COALESCE(jsonb_agg(row_to_json(x)), '[]'::jsonb) FROM (
    SELECT c.id, c.type, c.name, c.topic, c.contract_id, c.is_locked, c.is_archived, c.legal_hold, c.retention_days, c.last_message_at,
           (SELECT count(*) FROM chat_members m WHERE m.channel_id = c.id) AS members
    FROM chat_channels c
    WHERE c.type <> 'direct' AND (p_search IS NULL OR c.name ILIKE '%' || _clean_text(p_search, 100) || '%')
    ORDER BY c.last_message_at DESC NULLS LAST LIMIT LEAST(GREATEST(p_limit, 1), 500)) x);
END $$;

-- Akun pending boleh mengelola perangkatnya sendiri (route /settings/devices terbuka untuk pending)
CREATE OR REPLACE FUNCTION rename_my_device(p_device UUID, p_label TEXT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_session(FALSE);
BEGIN
  UPDATE trusted_devices SET label = _clean_text(p_label, 80, TRUE) WHERE id = p_device AND user_id = v_uid;
  IF NOT FOUND THEN RAISE EXCEPTION 'Perangkat tidak ditemukan' USING ERRCODE = '22023'; END IF;
END $$;

-- Alasan admin wajib tercatat sebagai security event (audit trigger hanya mencatat baris)
CREATE OR REPLACE FUNCTION admin_revoke_invite(p_invite UUID, p_reason TEXT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_access('admin.invites.manage'); v_reason TEXT := _require_reason(p_reason);
BEGIN
  UPDATE user_invites SET revoked_at = NOW() WHERE id = p_invite AND accepted_at IS NULL AND revoked_at IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'Undangan tidak aktif' USING ERRCODE = '22023'; END IF;
  PERFORM _security_event(v_uid, 'invite_revoked', 'info', jsonb_build_object('invite', p_invite, 'reason', v_reason));
END $$;

CREATE OR REPLACE FUNCTION admin_upsert_holiday(p_id UUID, p_date DATE, p_geozone TEXT, p_name TEXT, p_reason TEXT) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_access('admin.settings.manage'); v_reason TEXT := _require_reason(p_reason); v_id UUID;
BEGIN
  IF p_id IS NULL THEN
    INSERT INTO holidays (holiday_date, geozone, name) VALUES (p_date, p_geozone, _clean_text(p_name, 120, TRUE)) RETURNING id INTO v_id;
  ELSE
    UPDATE holidays SET holiday_date = p_date, geozone = p_geozone, name = _clean_text(p_name, 120, TRUE) WHERE id = p_id RETURNING id INTO v_id;
    IF v_id IS NULL THEN RAISE EXCEPTION 'Hari libur tidak ditemukan' USING ERRCODE = '22023'; END IF;
  END IF;
  PERFORM _security_event(v_uid, 'settings_changed', 'info',
                          jsonb_build_object('key', 'holiday', 'id', v_id, 'date', p_date, 'geozone', p_geozone, 'reason', v_reason));
  RETURN v_id;
EXCEPTION WHEN unique_violation THEN
  RAISE EXCEPTION 'Hari libur sudah ada untuk tanggal & geozone ini' USING ERRCODE = '23505';
END $$;

CREATE OR REPLACE FUNCTION admin_delete_holiday(p_id UUID, p_reason TEXT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_access('admin.settings.manage'); v_reason TEXT := _require_reason(p_reason); v_h holidays;
BEGIN
  DELETE FROM holidays WHERE id = p_id RETURNING * INTO v_h;
  IF v_h.id IS NULL THEN RAISE EXCEPTION 'Hari libur tidak ditemukan' USING ERRCODE = '22023'; END IF;
  PERFORM _security_event(v_uid, 'settings_changed', 'info',
                          jsonb_build_object('key', 'holiday_deleted', 'date', v_h.holiday_date, 'geozone', v_h.geozone, 'reason', v_reason));
END $$;

CREATE OR REPLACE FUNCTION admin_upsert_geozone(p_code TEXT, p_name TEXT, p_review_mailbox TEXT, p_timezone TEXT, p_active BOOLEAN, p_reason TEXT)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_access('admin.settings.manage'); v_reason TEXT := _require_reason(p_reason); v_old geozones;
BEGIN
  PERFORM NOW() AT TIME ZONE p_timezone;
  SELECT * INTO v_old FROM geozones WHERE code = upper(p_code);
  INSERT INTO geozones (code, name, review_mailbox, timezone, active)
  VALUES (upper(p_code), _clean_text(p_name, 80, TRUE), _clean_email(p_review_mailbox, TRUE), p_timezone, COALESCE(p_active, TRUE))
  ON CONFLICT (code) DO UPDATE SET name = EXCLUDED.name, review_mailbox = EXCLUDED.review_mailbox,
                                   timezone = EXCLUDED.timezone, active = EXCLUDED.active;
  PERFORM _security_event(v_uid, 'settings_changed', 'warning',
                          jsonb_build_object('key', 'geozone', 'code', upper(p_code), 'old', to_jsonb(v_old), 'reason', v_reason));
END $$;

CREATE OR REPLACE FUNCTION admin_retry_outbox(p_ids BIGINT[], p_reason TEXT) RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_access('admin.templates.manage'); v_reason TEXT := _require_reason(p_reason); v_n INT;
BEGIN
  UPDATE notification_outbox SET status = 'queued', attempts = 0, send_after = NOW(), locked_until = NULL, last_error = NULL
  WHERE id = ANY(p_ids[1:1000]) AND status = 'failed';
  GET DIAGNOSTICS v_n = ROW_COUNT;
  PERFORM _security_event(v_uid, 'outbox_retry', 'info', jsonb_build_object('count', v_n, 'reason', v_reason));
  RETURN v_n;
END $$;

-- Daftar user perusahaan: rekan sesama contractor, atau WFRD yang boleh melihat vendor tsb (assignee task, kartu My Company)
CREATE OR REPLACE FUNCTION list_contractor_users(p_contractor UUID DEFAULT NULL) RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_session(FALSE); v_own UUID := auth_contractor_id(); v_cid UUID := COALESCE(p_contractor, auth_contractor_id());
BEGIN
  IF v_cid IS NULL THEN RAISE EXCEPTION 'Contractor wajib diisi' USING ERRCODE = '22023'; END IF;
  IF NOT (v_cid = v_own OR (auth_is_wfrd() AND can_view_contractor(v_cid))) THEN PERFORM _deny('forbidden'); END IF;
  RETURN COALESCE((
    SELECT jsonb_agg(jsonb_build_object('id', p.id, 'full_name', p.full_name, 'email', p.email, 'avatar_url', p.avatar_url,
             'job_title', p.job_title, 'status', p.status, 'last_login_at', p.last_login_at,
             'roles', (SELECT COALESCE(jsonb_agg(jsonb_build_object('role', r.key) ORDER BY r.key), '[]'::jsonb)
                       FROM user_roles ur JOIN roles r ON r.id = ur.role_id
                       WHERE ur.user_id = p.id AND (ur.expires_at IS NULL OR ur.expires_at > NOW())))
           ORDER BY p.status = 'active' DESC, p.full_name)
    FROM profiles p
    WHERE p.contractor_id = v_cid AND p.anonymized_at IS NULL AND p.status IN ('active','pending','suspended')), '[]'::jsonb);
END $$;
REVOKE ALL ON FUNCTION list_contractor_users(UUID) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION list_contractor_users(UUID) TO authenticated;

-- Re-enkripsi bertahap setelah rotasi kunci (no-op bila semua baris sudah versi aktif)
SELECT cron.schedule('comen-rekey', '15 20 * * *', $$SELECT public.svc_rekey('chat', 5000); SELECT public.svc_rekey('data', 5000)$$);
