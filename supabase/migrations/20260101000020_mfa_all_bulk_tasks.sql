-- 20 · MFA wajib untuk semua user aktif (WFRD & contractor) + penugasan task katalog ke banyak contractor

-- ═════════════ MFA SEMUA USER ═════════════
INSERT INTO app_settings (key, value, is_public, required_permission, description) VALUES
  ('mfa_required_all', 'true', FALSE, 'admin.security.manage',
   'Semua user aktif (WFRD & contractor) wajib TOTP; user pending tetap bisa menyelesaikan registrasi')
ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION user_requires_mfa(p_uid UUID DEFAULT auth.uid()) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT EXISTS (SELECT 1 FROM profiles WHERE id = p_uid AND is_root_admin)
      OR (COALESCE(setting('mfa_required_all'), 'false'::jsonb) = 'true'::jsonb
          AND EXISTS (SELECT 1 FROM profiles WHERE id = p_uid AND status = 'active'))
      OR EXISTS (
        SELECT 1 FROM user_roles ur JOIN roles r ON r.id = ur.role_id
        WHERE ur.user_id = p_uid AND (ur.expires_at IS NULL OR ur.expires_at > NOW())
          AND r.key IN (SELECT jsonb_array_elements_text(COALESCE(setting('mfa_required_roles'), '[]'::jsonb))))
$$;

-- ═════════════ TASK KATALOG → BANYAK CONTRACTOR ═════════════
-- p_scope 'vendor'  : satu task per perusahaan
-- p_scope 'contract': satu task per kontrak berjalan milik perusahaan terpilih
-- Contractor yang sudah punya task aktif (belum final) dengan jenis dokumen sama dilewati.
CREATE OR REPLACE FUNCTION admin_assign_doc_type(p_doc_type TEXT, p_scope TEXT, p_contractors UUID[], p_title TEXT,
  p_due DATE, p_is_blocker BOOLEAN, p_description TEXT, p_reason TEXT) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_access('admin.catalog.manage'); v_reason TEXT := _require_reason(p_reason);
        v_d doc_type_catalog; v_c contractors; v_k contracts; v_title TEXT; v_desc TEXT; v_id UUID; v_tid TEXT;
        v_n INT := 0; v_skip INT := 0; v_open task_status[] := ARRAY['open','awaiting_email','submitted','under_review','file_issue']::task_status[];
BEGIN
  IF NOT has_permission('task.generate') THEN PERFORM _deny('forbidden'); END IF;
  PERFORM hit_rate_limit('bulk_task:' || v_uid, 20, INTERVAL '1 hour');
  SELECT * INTO v_d FROM doc_type_catalog WHERE code = p_doc_type AND active;
  IF NOT FOUND THEN RAISE EXCEPTION 'Jenis dokumen tidak valid / nonaktif' USING ERRCODE = '22023'; END IF;
  IF p_scope NOT IN ('vendor','contract') OR NOT (p_scope::task_scope = ANY(v_d.allowed_scopes)) THEN
    RAISE EXCEPTION 'Jenis % tidak berlaku untuk scope %', p_doc_type, p_scope USING ERRCODE = '22023'; END IF;
  IF p_due IS NULL OR p_due < _local_today() THEN RAISE EXCEPTION 'Due date wajib & tidak boleh lampau' USING ERRCODE = '22023'; END IF;
  IF p_contractors IS NULL OR cardinality(p_contractors) = 0 OR cardinality(p_contractors) > 500 THEN
    RAISE EXCEPTION 'Pilih 1–500 contractor' USING ERRCODE = '22023'; END IF;
  v_title := COALESCE(_clean_text(p_title, 200), v_d.label);
  v_desc := _clean_text(p_description, 4000);

  FOR v_c IN SELECT * FROM contractors WHERE id = ANY(p_contractors) ORDER BY legal_name LOOP
    IF v_c.status NOT IN ('under_review','asl_approved','asl_conditional','asl_expired') THEN
      v_skip := v_skip + 1; CONTINUE; END IF;
    IF p_scope = 'vendor' THEN
      IF EXISTS (SELECT 1 FROM tasks WHERE contractor_id = v_c.id AND scope = 'vendor' AND doc_type_code = v_d.code AND status = ANY(v_open)) THEN
        v_skip := v_skip + 1; CONTINUE; END IF;
      v_id := _create_task('vendor', v_c.id, NULL, NULL, v_d.code, v_title, p_due, COALESCE(p_is_blocker, FALSE), NULL, 'bulk', v_desc);
      SELECT task_id INTO v_tid FROM tasks WHERE id = v_id;
      PERFORM _notify_contractor(v_c.id, 'task_generated', 'Task baru: ' || v_tid, v_title, '/tasks/' || v_id, 'info', 2001,
                                 jsonb_build_object('task_id', v_tid, 'title', v_title, 'due', p_due), 'bulk:' || v_id);
      v_n := v_n + 1;
    ELSE
      FOR v_k IN SELECT * FROM contracts WHERE contractor_id = v_c.id AND status NOT IN ('closed','terminated','suspended') ORDER BY contract_no LOOP
        IF EXISTS (SELECT 1 FROM tasks WHERE contract_id = v_k.id AND scope = 'contract' AND doc_type_code = v_d.code AND status = ANY(v_open)) THEN
          v_skip := v_skip + 1; CONTINUE; END IF;
        v_id := _create_task('contract', v_c.id, v_k.id, NULL, v_d.code, v_title, p_due, COALESCE(p_is_blocker, FALSE), NULL, 'bulk', v_desc);
        SELECT task_id INTO v_tid FROM tasks WHERE id = v_id;
        PERFORM _notify_contractor(v_c.id, 'task_generated', 'Task baru: ' || v_tid, v_title, '/tasks/' || v_id, 'info', 2001,
                                   jsonb_build_object('task_id', v_tid, 'title', v_title, 'due', p_due, 'contract_no', v_k.contract_no), 'bulk:' || v_id);
        PERFORM _bot_contract(v_k.id, 'task_card', '📌 ' || v_tid || ' — ' || v_title || ' (due ' || p_due || ')', 'normal', ARRAY[v_tid]);
        v_n := v_n + 1;
      END LOOP;
    END IF;
  END LOOP;

  PERFORM _security_event(v_uid, 'bulk_task_assign', 'info', jsonb_build_object('doc_type', v_d.code, 'scope', p_scope,
          'contractors', cardinality(p_contractors), 'created', v_n, 'skipped', v_skip, 'due', p_due, 'reason', v_reason));
  RETURN jsonb_build_object('created', v_n, 'skipped', v_skip);
END $$;

REVOKE ALL ON FUNCTION admin_assign_doc_type(TEXT, TEXT, UUID[], TEXT, DATE, BOOLEAN, TEXT, TEXT) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION admin_assign_doc_type(TEXT, TEXT, UUID[], TEXT, DATE, BOOLEAN, TEXT, TEXT) TO authenticated;
