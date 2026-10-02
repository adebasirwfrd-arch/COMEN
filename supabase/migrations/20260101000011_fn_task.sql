-- ═════════════ TASK ID & PEMBUATAN ═════════════
CREATE OR REPLACE FUNCTION generate_task_id(p_scope task_scope, p_contractor UUID, p_contract UUID, p_sub UUID, p_code TEXT) RETURNS TEXT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_scope TEXT; v_seq INT;
BEGIN
  v_scope := CASE p_scope
    WHEN 'vendor'        THEN (SELECT 'V' || lpad(vendor_seq::TEXT, 5, '0') FROM contractors WHERE id = p_contractor)
    WHEN 'contract'      THEN (SELECT lpad(contract_seq::TEXT, 5, '0') FROM contracts WHERE id = p_contract)
    WHEN 'subcontractor' THEN (SELECT lpad(k.contract_seq::TEXT, 5, '0') || 'S' || lpad(s.sub_seq::TEXT, 2, '0')
                               FROM subcontractors s JOIN contracts k ON k.id = s.contract_id WHERE s.id = p_sub) END;
  IF v_scope IS NULL THEN RAISE EXCEPTION 'Scope task tidak valid' USING ERRCODE = '22023'; END IF;
  INSERT INTO task_sequences (scope_key, doc_type_code, current_seq) VALUES (v_scope, p_code, 1)
  ON CONFLICT (scope_key, doc_type_code) DO UPDATE SET current_seq = task_sequences.current_seq + 1
  RETURNING current_seq INTO v_seq;                     -- CHECK ≤ 999 menolak overflow
  RETURN 'CMN-' || v_scope || '-' || p_code || '-' || lpad(v_seq::TEXT, 3, '0');
END $$;

CREATE OR REPLACE FUNCTION _create_task(
  p_scope task_scope, p_contractor UUID, p_contract UUID, p_sub UUID, p_code TEXT, p_title TEXT, p_due DATE,
  p_is_blocker BOOLEAN DEFAULT FALSE, p_assigned_to UUID DEFAULT NULL, p_source_ref TEXT DEFAULT NULL,
  p_description TEXT DEFAULT NULL, p_is_mandatory BOOLEAN DEFAULT TRUE, p_phase lifecycle_phase DEFAULT NULL,
  p_renewal_of UUID DEFAULT NULL
) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_d doc_type_catalog; v_k contracts; v_id UUID; v_tid TEXT; v_phase lifecycle_phase; v_reviewer UUID;
BEGIN
  SELECT * INTO v_d FROM doc_type_catalog WHERE code = p_code AND active;
  IF NOT FOUND THEN RAISE EXCEPTION 'Jenis dokumen % tidak aktif', p_code USING ERRCODE = '22023'; END IF;
  IF NOT (p_scope = ANY(v_d.allowed_scopes)) THEN RAISE EXCEPTION 'Jenis % tidak berlaku untuk scope %', p_code, p_scope USING ERRCODE = '22023'; END IF;
  IF p_contract IS NOT NULL THEN SELECT * INTO v_k FROM contracts WHERE id = p_contract; END IF;

  v_phase := COALESCE(p_phase, CASE
    WHEN p_scope = 'vendor' THEN 'vendor_onboarding'::lifecycle_phase
    WHEN p_scope = 'subcontractor' THEN CASE WHEN v_k.status IN ('awarded','post_award','pre_mobilization') THEN 'pre_mobilization'
                                             ELSE 'execution' END::lifecycle_phase
    WHEN v_d.requirement IN ('adhoc','recurring') THEN CASE v_k.status
         WHEN 'awarded' THEN 'post_award' WHEN 'post_award' THEN 'post_award' WHEN 'pre_mobilization' THEN 'pre_mobilization'
         WHEN 'mobilization' THEN 'mobilization' WHEN 'demobilization' THEN 'demobilization'
         WHEN 'final_evaluation' THEN 'final_evaluation' ELSE 'execution' END::lifecycle_phase
    ELSE v_d.phase END);

  IF p_scope <> 'vendor' THEN
    v_reviewer := CASE v_d.reviewer_role WHEN 'hse_reviewer' THEN v_k.hse_reviewer_id WHEN 'process_owner' THEN v_k.process_owner_id END;
  END IF;

  v_tid := generate_task_id(p_scope, p_contractor, p_contract, p_sub, p_code);
  INSERT INTO tasks (task_id, scope, contractor_id, contract_id, subcontractor_id, doc_type_code, kind, phase, title, description,
                     is_mandatory, is_blocker, source_ref, assigned_to, reviewer_id, due_date, renewal_of, created_by)
  VALUES (v_tid, p_scope, p_contractor, p_contract, p_sub, p_code, v_d.kind, v_phase, left(COALESCE(p_title, v_d.label), 200),
          left(p_description, 4000), COALESCE(p_is_mandatory, TRUE), COALESCE(p_is_blocker, FALSE), p_source_ref, p_assigned_to,
          v_reviewer, p_due, p_renewal_of, auth.uid())
  RETURNING id INTO v_id;

  IF v_d.kind = 'checklist' AND v_d.checklist_template IS NOT NULL THEN
    INSERT INTO checklist_items (task_id, item_no, category, label, owner_party)
    SELECT v_id, (ord)::SMALLINT, e ->> 'category', e ->> 'label', COALESCE(e ->> 'owner_party', 'contractor')
    FROM jsonb_array_elements(v_d.checklist_template) WITH ORDINALITY AS x(e, ord);
  END IF;
  INSERT INTO task_events (task_id, event, actor_id, payload) VALUES (v_id, 'created', auth.uid(), jsonb_build_object('task_id', v_tid));
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION _risk_rank(p TEXT) RETURNS INT LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p WHEN 'low' THEN 1 WHEN 'medium' THEN 2 WHEN 'high' THEN 3 END
$$;

-- Due kontrak dari katalog; due ≤ hari ini → hari ini + 3 & compressed timeline
CREATE OR REPLACE FUNCTION _contract_due(p_contract UUID, p_code TEXT, OUT due DATE, OUT compressed BOOLEAN)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_k contracts; v_d doc_type_catalog; v_today DATE;
BEGIN
  SELECT * INTO v_k FROM contracts WHERE id = p_contract;
  SELECT * INTO v_d FROM doc_type_catalog WHERE code = p_code;
  v_today := _local_today(v_k.geozone);
  due := CASE v_d.due_anchor
    WHEN 'award_date'      THEN v_k.awarded_at + COALESCE(v_d.due_offset_days, 7)
    WHEN 'target_mob_date' THEN v_k.target_mob_date + COALESCE(v_d.due_offset_days, -14)
    ELSE v_today + COALESCE(v_d.due_offset_days, 7) END;
  compressed := due <= v_today;
  IF compressed THEN due := v_today + 3; END IF;
END $$;

-- ═════════════ GENERATOR ═════════════
CREATE OR REPLACE FUNCTION generate_vendor_tasks(p_contractor UUID) RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_c contractors; v_d doc_type_catalog; v_n INT := 0; v_due DATE := _local_today() + _setting_int('vendor_doc_due_days', 14);
BEGIN
  SELECT * INTO v_c FROM contractors WHERE id = p_contractor FOR UPDATE;
  FOR v_d IN SELECT * FROM doc_type_catalog WHERE active AND vendor_requirement IS NOT NULL ORDER BY code LOOP
    CONTINUE WHEN v_d.vendor_requirement = 'conditional' AND NOT CASE v_d.vendor_condition_key
                    WHEN 'country_is_id' THEN COALESCE(v_c.country = 'ID', FALSE) ELSE FALSE END;
    CONTINUE WHEN EXISTS (SELECT 1 FROM tasks WHERE contractor_id = p_contractor AND scope = 'vendor' AND doc_type_code = v_d.code
                          AND revision = 0 AND renewal_of IS NULL AND status <> 'cancelled');
    PERFORM _create_task('vendor', p_contractor, NULL, NULL, v_d.code, v_d.label, v_due, FALSE, NULL, NULL, NULL,
                         v_d.vendor_requirement <> 'optional');
    v_n := v_n + 1;
  END LOOP;
  IF v_n > 0 THEN
    PERFORM _notify_contractor(p_contractor, 'tasks_generated', v_n || ' dokumen vendor diminta', 'Upload ke link OneDrive & konfirmasi',
                               '/tasks', 'info', 2001, jsonb_build_object('count', v_n, 'due', v_due), 'vgen:' || p_contractor || ':' || CURRENT_DATE);
  END IF;
  RETURN v_n;
END $$;

CREATE OR REPLACE FUNCTION build_contract_requirements(p_contract UUID) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_k contracts;
BEGIN
  SELECT * INTO v_k FROM contracts WHERE id = p_contract;
  INSERT INTO contract_requirements (contract_id, doc_type_code, applicable, is_mandatory, is_mob_gate, reason, computed_at)
  SELECT p_contract, d.code, a.applicable, a.applicable AND d.requirement <> 'optional',
         a.applicable AND d.requirement <> 'optional' AND d.is_mob_gate, a.reason, NOW()
  FROM doc_type_catalog d
  CROSS JOIN LATERAL (SELECT
     CASE d.requirement
       WHEN 'mandatory'   THEN d.min_risk_class IS NULL OR _risk_rank(v_k.risk_class) >= _risk_rank(d.min_risk_class)
       WHEN 'conditional' THEN COALESCE((v_k.premob_questionnaire ->> d.condition_key)::BOOLEAN, FALSE)
                               OR (d.min_risk_class IS NOT NULL AND _risk_rank(v_k.risk_class) >= _risk_rank(d.min_risk_class))
       WHEN 'optional'    THEN TRUE END AS applicable,
     CASE d.requirement
       WHEN 'mandatory'   THEN 'mandatory'
       WHEN 'conditional' THEN concat_ws(' / ',
                                 CASE WHEN COALESCE((v_k.premob_questionnaire ->> d.condition_key)::BOOLEAN, FALSE) THEN d.condition_key END,
                                 CASE WHEN d.min_risk_class IS NOT NULL AND _risk_rank(v_k.risk_class) >= _risk_rank(d.min_risk_class)
                                      THEN 'risk ≥ ' || d.min_risk_class END)
       ELSE 'optional' END AS reason) a
  WHERE d.active AND 'contract' = ANY(d.allowed_scopes) AND d.requirement IN ('mandatory','conditional','optional')
  ON CONFLICT (contract_id, doc_type_code) DO UPDATE SET applicable = EXCLUDED.applicable, is_mandatory = EXCLUDED.is_mandatory,
    is_mob_gate = EXCLUDED.is_mob_gate, reason = EXCLUDED.reason, computed_at = NOW();
END $$;

CREATE OR REPLACE FUNCTION generate_contract_tasks(p_contract UUID, p_phase lifecycle_phase) RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_k contracts; r RECORD; v_due DATE; v_cmp BOOLEAN; v_any_cmp BOOLEAN := FALSE; v_n INT := 0;
BEGIN
  SELECT * INTO v_k FROM contracts WHERE id = p_contract FOR UPDATE;
  FOR r IN SELECT d.code, d.label, cr.is_mandatory FROM contract_requirements cr JOIN doc_type_catalog d ON d.code = cr.doc_type_code
           WHERE cr.contract_id = p_contract AND cr.applicable AND d.phase = p_phase AND d.active ORDER BY d.code LOOP
    CONTINUE WHEN EXISTS (SELECT 1 FROM tasks WHERE contract_id = p_contract AND scope = 'contract' AND doc_type_code = r.code
                          AND revision = 0 AND renewal_of IS NULL AND status <> 'cancelled');
    SELECT due, compressed INTO v_due, v_cmp FROM _contract_due(p_contract, r.code);
    v_any_cmp := v_any_cmp OR (v_cmp AND p_phase = 'pre_mobilization');
    PERFORM _create_task('contract', v_k.contractor_id, p_contract, NULL, r.code, r.label, v_due, FALSE, NULL, NULL, NULL,
                         r.is_mandatory, p_phase);
    v_n := v_n + 1;
  END LOOP;
  IF v_any_cmp THEN UPDATE contracts SET compressed_timeline = TRUE WHERE id = p_contract; END IF;
  IF v_n > 0 THEN
    PERFORM _notify_contractor(v_k.contractor_id, 'tasks_generated', v_n || ' task baru · ' || v_k.contract_no, p_phase::TEXT,
                               '/contracts/' || p_contract, 'info', 2001,
                               jsonb_build_object('count', v_n, 'contract_no', v_k.contract_no, 'phase', p_phase),
                               'cgen:' || p_contract || ':' || p_phase);
    PERFORM _bot_contract(p_contract, 'task_card', '📋 ' || v_n || ' task baru untuk fase ' || p_phase ||
                          CASE WHEN v_any_cmp THEN ' — ⚠ COMPRESSED TIMELINE' ELSE '' END, 'important');
  END IF;
  RETURN v_n;
END $$;

CREATE OR REPLACE FUNCTION generate_subcontractor_tasks(p_sub UUID) RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_s subcontractors; v_k contracts; v_d doc_type_catalog; v_n INT := 0;
BEGIN
  SELECT * INTO v_s FROM subcontractors WHERE id = p_sub;
  SELECT * INTO v_k FROM contracts WHERE id = v_s.contract_id;
  FOR v_d IN SELECT * FROM doc_type_catalog WHERE active AND subcon_required ORDER BY code LOOP
    CONTINUE WHEN EXISTS (SELECT 1 FROM tasks WHERE subcontractor_id = p_sub AND doc_type_code = v_d.code AND revision = 0 AND status <> 'cancelled');
    PERFORM _create_task('subcontractor', v_k.contractor_id, v_k.id, p_sub, v_d.code, v_d.label || ' — ' || v_s.legal_name,
                         _local_today(v_k.geozone) + 10);
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END $$;

CREATE OR REPLACE FUNCTION create_adhoc_task(p_contractor UUID, p_contract UUID, p_subcontractor UUID, p_doc_type TEXT, p_title TEXT,
  p_due DATE, p_is_blocker BOOLEAN, p_assigned_to UUID, p_source_ref TEXT, p_description TEXT) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID; v_cid UUID := p_contractor; v_scope task_scope; v_a profiles; v_d doc_type_catalog; v_id UUID; v_tid TEXT;
BEGIN
  IF p_contract IS NOT NULL THEN
    v_uid := assert_access('task.generate', p_contract);
    SELECT contractor_id INTO v_cid FROM contracts WHERE id = p_contract;
    v_scope := CASE WHEN p_subcontractor IS NULL THEN 'contract' ELSE 'subcontractor' END;
    IF p_subcontractor IS NOT NULL AND NOT EXISTS (SELECT 1 FROM subcontractors WHERE id = p_subcontractor AND contract_id = p_contract) THEN
      RAISE EXCEPTION 'Subcontractor bukan bagian kontrak ini' USING ERRCODE = '22023'; END IF;
    IF EXISTS (SELECT 1 FROM contracts WHERE id = p_contract AND status IN ('closed','terminated')) THEN
      RAISE EXCEPTION 'Kontrak sudah ditutup' USING ERRCODE = '22023'; END IF;
  ELSE
    v_uid := assert_access('task.generate', NULL, TRUE, p_contractor);
    v_scope := 'vendor';
  END IF;
  SELECT * INTO v_d FROM doc_type_catalog WHERE code = p_doc_type AND active;
  IF NOT FOUND THEN RAISE EXCEPTION 'Jenis dokumen tidak valid' USING ERRCODE = '22023'; END IF;
  IF p_due IS NULL OR p_due < _local_today() THEN RAISE EXCEPTION 'Due date wajib & tidak boleh lampau' USING ERRCODE = '22023'; END IF;
  IF p_assigned_to IS NOT NULL THEN
    SELECT * INTO v_a FROM profiles WHERE id = p_assigned_to AND status = 'active';
    IF NOT FOUND THEN RAISE EXCEPTION 'Assignee tidak aktif' USING ERRCODE = '22023'; END IF;
    IF v_a.contractor_id IS NULL AND v_d.kind <> 'action' THEN
      RAISE EXCEPTION 'Assignee WFRD hanya untuk task action' USING ERRCODE = '22023'; END IF;
    IF v_a.contractor_id IS NOT NULL AND v_a.contractor_id <> v_cid THEN
      RAISE EXCEPTION 'Assignee harus dari contractor yang sama' USING ERRCODE = '22023'; END IF;
  END IF;
  v_id := _create_task(v_scope, v_cid, p_contract, p_subcontractor, p_doc_type, _clean_text(p_title, 200, TRUE), p_due,
                       COALESCE(p_is_blocker, FALSE), p_assigned_to, _clean_text(p_source_ref, 200), _clean_text(p_description, 4000));
  SELECT task_id INTO v_tid FROM tasks WHERE id = v_id;
  IF v_a.id IS NOT NULL AND v_a.contractor_id IS NULL THEN
    PERFORM _notify(v_a.id, 'task_assigned', 'Action untuk Anda: ' || v_tid, p_title, '/tasks/' || v_id, 'info', NULL, '{}'::jsonb, 'assign:' || v_id);
  ELSE
    PERFORM _notify_contractor(v_cid, 'task_generated', 'Task baru: ' || v_tid, p_title, '/tasks/' || v_id, 'info', 2001,
                               jsonb_build_object('task_id', v_tid, 'title', p_title, 'due', p_due), 'adhoc:' || v_id);
  END IF;
  IF p_contract IS NOT NULL THEN
    PERFORM _bot_contract(p_contract, 'task_card', '📌 ' || v_tid || ' — ' || p_title || ' (due ' || p_due || ')', 'normal', ARRAY[v_tid]);
  END IF;
  RETURN jsonb_build_object('id', v_id, 'task_id', v_tid);
END $$;

-- ═════════════ LINK ONEDRIVE ═════════════
CREATE OR REPLACE FUNCTION resolve_upload_link(p_task UUID) RETURNS UUID
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT l.id FROM tasks t
  JOIN LATERAL (
    SELECT l.id,
           CASE
             WHEN l.scope_type = 'task' AND l.task_id = t.id THEN 1
             WHEN l.scope_type = 'subcontractor' AND l.subcontractor_id = t.subcontractor_id AND l.doc_type_code = t.doc_type_code THEN 2
             WHEN l.scope_type = 'subcontractor' AND l.subcontractor_id = t.subcontractor_id AND l.doc_type_code IS NULL THEN 3
             WHEN l.scope_type = 'contract' AND l.contract_id = t.contract_id AND l.doc_type_code = t.doc_type_code THEN 4
             WHEN l.scope_type = 'contract' AND l.contract_id = t.contract_id AND l.doc_type_code IS NULL THEN 5
             WHEN t.scope = 'vendor' AND l.scope_type = 'vendor' AND l.contractor_id = t.contractor_id AND l.doc_type_code = t.doc_type_code THEN 6
             WHEN t.scope = 'vendor' AND l.scope_type = 'vendor' AND l.contractor_id = t.contractor_id AND l.doc_type_code IS NULL THEN 7
             WHEN t.scope = 'vendor' AND l.scope_type = 'global' AND l.doc_type_code = t.doc_type_code THEN 8
             WHEN t.scope = 'vendor' AND l.scope_type = 'global' AND l.doc_type_code IS NULL THEN 9
           END AS prio
    FROM upload_links l
    WHERE l.active AND (l.expires_at IS NULL OR l.expires_at >= CURRENT_DATE)
  ) l ON l.prio IS NOT NULL
  WHERE t.id = p_task
  ORDER BY l.prio
  LIMIT 1
$$;

CREATE OR REPLACE FUNCTION admin_upsert_upload_link(p_id UUID, p_scope_type TEXT, p_contractor UUID, p_contract UUID, p_subcontractor UUID,
  p_task UUID, p_doc_type TEXT, p_url TEXT, p_link_type TEXT, p_label TEXT, p_expires_at DATE, p_reason TEXT) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID; v_reason TEXT := _require_reason(p_reason); v_id UUID; v_contract UUID := p_contract; v_contractor UUID := p_contractor;
        v_warn TEXT[] := '{}'; v_url TEXT := btrim(p_url); v_old upload_links;
BEGIN
  IF p_id IS NOT NULL THEN
    SELECT * INTO v_old FROM upload_links WHERE id = p_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Link tidak ditemukan' USING ERRCODE = '22023'; END IF;
    p_scope_type := v_old.scope_type; v_contractor := v_old.contractor_id; v_contract := v_old.contract_id;
    p_subcontractor := v_old.subcontractor_id; p_task := v_old.task_id; p_doc_type := v_old.doc_type_code;
  END IF;
  IF p_scope_type = 'task' THEN
    SELECT contract_id, contractor_id INTO v_contract, v_contractor FROM tasks WHERE id = p_task;
  ELSIF p_scope_type = 'subcontractor' THEN
    SELECT contract_id INTO v_contract FROM subcontractors WHERE id = p_subcontractor;
  END IF;
  v_uid := CASE
    WHEN v_contract IS NOT NULL THEN assert_access('upload_link.manage', v_contract)
    WHEN p_scope_type IN ('vendor','task') THEN assert_access('upload_link.manage', NULL, TRUE, v_contractor)
    ELSE assert_access('upload_link.manage') END;
  IF v_url !~* '^https://(1drv\.ms|onedrive\.live\.com|[a-z0-9-]+(-my)?\.sharepoint\.com)/' OR v_url ~ '[\s<>"]' THEN
    RAISE EXCEPTION 'URL harus link OneDrive/SharePoint (https)' USING ERRCODE = '22023';
  END IF;
  IF v_url ~* '^https://(1drv\.ms|onedrive\.live\.com)/' THEN v_warn := v_warn || 'personal_onedrive'; END IF;
  IF p_link_type = 'folder_edit' AND (p_doc_type IS NULL OR EXISTS (SELECT 1 FROM doc_type_catalog WHERE code = p_doc_type AND sensitive)) THEN
    v_warn := v_warn || 'folder_edit_sensitive';
  END IF;

  IF p_id IS NULL THEN
    UPDATE upload_links SET active = FALSE, updated_at = NOW()
    WHERE active AND scope_type = p_scope_type AND contractor_id IS NOT DISTINCT FROM (CASE WHEN p_scope_type = 'vendor' THEN v_contractor END)
      AND contract_id IS NOT DISTINCT FROM (CASE WHEN p_scope_type IN ('contract','subcontractor') THEN v_contract END)
      AND subcontractor_id IS NOT DISTINCT FROM p_subcontractor AND task_id IS NOT DISTINCT FROM p_task
      AND doc_type_code IS NOT DISTINCT FROM p_doc_type;
    INSERT INTO upload_links (scope_type, contractor_id, contract_id, subcontractor_id, task_id, doc_type_code, url, link_type, label, expires_at, created_by)
    VALUES (p_scope_type, CASE WHEN p_scope_type = 'vendor' THEN v_contractor END,
            CASE WHEN p_scope_type IN ('contract','subcontractor') THEN v_contract END,
            CASE WHEN p_scope_type = 'subcontractor' THEN p_subcontractor END, CASE WHEN p_scope_type = 'task' THEN p_task END,
            CASE WHEN p_scope_type = 'task' THEN NULL ELSE p_doc_type END, v_url, COALESCE(p_link_type, 'file_request'),
            _clean_text(p_label, 200, TRUE), p_expires_at, v_uid)
    RETURNING id INTO v_id;
  ELSE
    UPDATE upload_links SET url = v_url, link_type = COALESCE(p_link_type, link_type), label = _clean_text(p_label, 200, TRUE),
                            expires_at = p_expires_at, active = TRUE, updated_at = NOW()
    WHERE id = p_id RETURNING id INTO v_id;
  END IF;
  RETURN jsonb_build_object('id', v_id, 'warnings', to_jsonb(v_warn));
END $$;

CREATE OR REPLACE FUNCTION admin_deactivate_upload_link(p_id UUID, p_reason TEXT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_l upload_links; v_reason TEXT := _require_reason(p_reason); v_contract UUID; v_contractor UUID;
BEGIN
  SELECT * INTO v_l FROM upload_links WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Link tidak ditemukan' USING ERRCODE = '22023'; END IF;
  v_contract := v_l.contract_id; v_contractor := v_l.contractor_id;
  IF v_l.scope_type = 'task' THEN SELECT contract_id, contractor_id INTO v_contract, v_contractor FROM tasks WHERE id = v_l.task_id; END IF;
  IF v_contract IS NOT NULL THEN PERFORM assert_access('upload_link.manage', v_contract);
  ELSIF v_contractor IS NOT NULL THEN PERFORM assert_access('upload_link.manage', NULL, TRUE, v_contractor);
  ELSE PERFORM assert_access('upload_link.manage'); END IF;
  UPDATE upload_links SET active = FALSE, updated_at = NOW() WHERE id = p_id;
END $$;

CREATE OR REPLACE FUNCTION link_coverage(p_contract UUID DEFAULT NULL)
RETURNS TABLE (task_uuid UUID, task_id TEXT, title TEXT, contract_no TEXT, contractor_name TEXT, due_date DATE)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
BEGIN
  IF p_contract IS NULL THEN PERFORM assert_access('upload_link.view', NULL, FALSE);
  ELSE PERFORM assert_access('upload_link.view', p_contract, FALSE); END IF;
  RETURN QUERY
  SELECT t.id, t.task_id, t.title, k.contract_no, c.legal_name, t.due_date
  FROM tasks t JOIN contractors c ON c.id = t.contractor_id LEFT JOIN contracts k ON k.id = t.contract_id
  WHERE t.status IN ('open','file_issue') AND t.kind IN ('document','evidence')
    AND (p_contract IS NULL OR t.contract_id = p_contract)
    AND resolve_upload_link(t.id) IS NULL
  ORDER BY t.due_date NULLS LAST;
END $$;

-- ═════════════ AKSES & DETAIL TASK ═════════════
CREATE OR REPLACE FUNCTION _task_for_update(p_task UUID) RETURNS tasks
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_t tasks;
BEGIN
  SELECT * INTO v_t FROM tasks WHERE id = p_task FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Task tidak ditemukan' USING ERRCODE = '22023'; END IF;
  RETURN v_t;
END $$;

-- Akses contractor ke task: permission + kepemilikan (assert_access dgn contract/contractor)
CREATE OR REPLACE FUNCTION _assert_task_perm(p_perm TEXT, v_t tasks, p_write BOOLEAN DEFAULT TRUE) RETURNS UUID
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
BEGIN
  IF v_t.contract_id IS NOT NULL THEN RETURN assert_access(p_perm, v_t.contract_id, p_write); END IF;
  RETURN assert_access(p_perm, NULL, p_write, v_t.contractor_id);
END $$;

CREATE OR REPLACE FUNCTION _can_review_task(p_uid UUID, v_t tasks) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT v_t.reviewer_id = p_uid OR EXISTS (
    SELECT 1 FROM user_roles ur JOIN roles r ON r.id = ur.role_id JOIN profiles p ON p.id = ur.user_id AND p.status = 'active'
    LEFT JOIN contracts c ON c.id = v_t.contract_id
    WHERE ur.user_id = p_uid AND p.contractor_id IS NULL AND (ur.expires_at IS NULL OR ur.expires_at > NOW())
      AND (r.key = (SELECT reviewer_role FROM doc_type_catalog WHERE code = v_t.doc_type_code)
           OR r.key IN ('hse_admin','hse_director','super_admin'))
      AND (ur.scope_type = 'global'
           OR (ur.scope_type = 'geozone'    AND ur.scope_id = c.geozone)
           OR (ur.scope_type = 'contract'   AND ur.scope_id = v_t.contract_id::TEXT)
           OR (ur.scope_type = 'contractor' AND ur.scope_id = v_t.contractor_id::TEXT)))
$$;

CREATE OR REPLACE FUNCTION get_task_detail(p_task UUID) RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_session(FALSE); v_t tasks; v_l upload_links; v_d doc_type_catalog;
BEGIN
  IF NOT can_view_task(p_task) THEN PERFORM _deny('forbidden'); END IF;
  SELECT * INTO v_t FROM tasks WHERE id = p_task;
  SELECT * INTO v_d FROM doc_type_catalog WHERE code = v_t.doc_type_code;
  SELECT * INTO v_l FROM upload_links WHERE id = resolve_upload_link(p_task);
  RETURN jsonb_build_object(
    'task', to_jsonb(v_t) - 'confirm_code' || jsonb_build_object('confirm_code',
             CASE WHEN v_t.status = 'awaiting_email' OR auth_is_wfrd() THEN v_t.confirm_code END),
    'doc', jsonb_build_object('label', v_d.label, 'kind', v_d.kind, 'requires_email', v_d.requires_email,
                              'requires_expiry', v_d.requires_expiry, 'requires_fingerprint', v_d.requires_fingerprint,
                              'sensitive', v_d.sensitive, 'review_sla_days', v_d.review_sla_days),
    'link', CASE WHEN v_l.id IS NULL THEN NULL ELSE jsonb_build_object('id', v_l.id, 'url', v_l.url, 'label', v_l.label,
              'link_type', v_l.link_type, 'scope_type', v_l.scope_type,
              'personal', v_l.url ~* '^https://(1drv\.ms|onedrive\.live\.com)/') END,
    'contract', (SELECT jsonb_build_object('id', id, 'contract_no', contract_no, 'title', title, 'status', status) FROM contracts WHERE id = v_t.contract_id),
    'contractor', (SELECT jsonb_build_object('id', id, 'legal_name', legal_name, 'vendor_ref', 'CMN-V' || lpad(vendor_seq::TEXT, 5, '0'))
                   FROM contractors WHERE id = v_t.contractor_id),
    'checklist', (SELECT COALESCE(jsonb_agg(to_jsonb(ci) ORDER BY ci.item_no), '[]'::jsonb) FROM checklist_items ci WHERE ci.task_id = p_task),
    'events', (SELECT COALESCE(jsonb_agg(jsonb_build_object('event', e.event, 'at', e.created_at, 'actor', e.actor_id, 'payload', e.payload)
                       ORDER BY e.created_at), '[]'::jsonb) FROM task_events e WHERE e.task_id = p_task),
    'revisions', (SELECT COALESCE(jsonb_agg(jsonb_build_object('id', id, 'task_id', task_id, 'status', status) ORDER BY revision), '[]'::jsonb)
                  FROM tasks WHERE base_task_id = v_t.base_task_id),
    'can_review', auth_is_wfrd() AND has_any_permission('task.review') AND _can_review_task(v_uid, v_t),
    'can_confirm', v_t.contractor_id = auth_contractor_id() AND has_permission('task.confirm_upload'));
END $$;

-- Antrian review: berlaku untuk reviewer ber-scope global maupun geozone/kontrak/contractor
CREATE OR REPLACE FUNCTION get_review_queue(p_limit INT DEFAULT 200)
RETURNS TABLE (id UUID, task_id TEXT, title TEXT, status task_status, contract_no TEXT, contractor_name TEXT,
               review_due_at TIMESTAMPTZ, upload_confirmed_at TIMESTAMPTZ, email_verified BOOLEAN, kind task_kind)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_session(FALSE);
BEGIN
  IF NOT (auth_is_wfrd() AND has_any_permission('task.review')) THEN PERFORM _deny('forbidden'); END IF;
  RETURN QUERY
  SELECT t.id, t.task_id, t.title, t.status, k.contract_no, c.legal_name, t.review_due_at, t.upload_confirmed_at, t.email_verified, t.kind
  FROM tasks t JOIN contractors c ON c.id = t.contractor_id LEFT JOIN contracts k ON k.id = t.contract_id
  WHERE t.status IN ('submitted','under_review') AND _can_review_task(v_uid, t)
    AND (t.contract_id IS NULL OR has_contract_permission('task.review', t.contract_id) OR t.reviewer_id = v_uid)
  ORDER BY t.review_due_at NULLS LAST
  LIMIT LEAST(GREATEST(p_limit, 1), 500);
END $$;

CREATE OR REPLACE FUNCTION log_link_opened(p_task UUID) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_session(FALSE);
BEGIN
  IF NOT can_view_task(p_task) THEN PERFORM _deny('forbidden'); END IF;
  PERFORM hit_rate_limit('linkopen:' || v_uid, 120, INTERVAL '1 hour');
  INSERT INTO task_events (task_id, event, actor_id, payload)
  VALUES (p_task, 'link_opened', v_uid, jsonb_build_object('link', resolve_upload_link(p_task)));
END $$;

CREATE OR REPLACE FUNCTION get_task_email_context(p_task UUID) RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_t tasks; v_k contracts; v_c contractors; v_d doc_type_catalog; v_l upload_links; v_to TEXT; v_cc TEXT; v_subject TEXT; v_body TEXT;
BEGIN
  PERFORM assert_session(FALSE);
  IF NOT can_view_task(p_task) THEN PERFORM _deny('forbidden'); END IF;
  SELECT * INTO v_t FROM tasks WHERE id = p_task;
  IF v_t.status <> 'awaiting_email' AND NOT auth_is_wfrd() THEN
    RAISE EXCEPTION 'Email konfirmasi hanya tersedia setelah Konfirmasi Upload' USING ERRCODE = '22023'; END IF;
  SELECT * INTO v_k FROM contracts WHERE id = v_t.contract_id;
  SELECT * INTO v_c FROM contractors WHERE id = v_t.contractor_id;
  SELECT * INTO v_d FROM doc_type_catalog WHERE code = v_t.doc_type_code;
  SELECT * INTO v_l FROM upload_links WHERE id = COALESCE(v_t.upload_link_id, resolve_upload_link(p_task));
  v_to := COALESCE(v_k.review_mailbox, _setting_text('vendor_review_mailbox', NULL));
  v_cc := CASE WHEN _setting_bool('inbound_auto_match', FALSE) THEN _setting_text('inbound_address', NULL) END;
  v_subject := '[' || v_t.task_id || '] Konfirmasi Upload · KODE ' || COALESCE(v_t.confirm_code, '----') || ' · ' || v_c.legal_name
               || COALESCE(' · ' || v_k.contract_no, ' · CMN-V' || lpad(v_c.vendor_seq::TEXT, 5, '0'));
  v_body := 'Task ID      : ' || v_t.task_id || E'\n' ||
            'Kode         : ' || COALESCE(v_t.confirm_code, '-') || E'\n' ||
            'Dokumen      : ' || v_d.label || E'\n' ||
            'Nama file    : ' || COALESCE(v_t.uploaded_file_name, '-') || E'\n' ||
            'SHA-256      : ' || COALESCE(v_t.file_sha256, '(tidak diisi)') || E'\n' ||
            'Folder       : ' || COALESCE(v_l.label, '-') || E'\n\n' ||
            'Kami menyatakan dokumen telah diupload ke folder OneDrive yang disediakan WFRD.';
  RETURN jsonb_build_object('to', v_to, 'cc', v_cc, 'subject', v_subject, 'body', v_body, 'code', v_t.confirm_code);
END $$;

-- ═════════════ KONFIRMASI UPLOAD (contractor) ═════════════
CREATE OR REPLACE FUNCTION confirm_upload(p_task UUID, p_file_name TEXT, p_sha256 TEXT, p_doc_number TEXT, p_issuer TEXT,
  p_issue_date DATE, p_expiry_date DATE, p_evidence_ref TEXT, p_form_data JSONB, p_note TEXT, p_integrity_attested BOOLEAN)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_t tasks := _task_for_update(p_task); v_uid UUID; v_d doc_type_catalog; v_link UUID; v_k contracts;
        v_file TEXT := _clean_text(p_file_name, 255); v_sha TEXT := lower(NULLIF(btrim(p_sha256), '')); v_code TEXT; v_now TIMESTAMPTZ := clock_timestamp();
        v_status task_status;
BEGIN
  v_uid := _assert_task_perm('task.confirm_upload', v_t);
  PERFORM hit_rate_limit('confirm:' || v_uid, 30, INTERVAL '1 hour');
  IF v_t.status NOT IN ('open','file_issue','awaiting_email') THEN
    RAISE EXCEPTION 'Task tidak menunggu konfirmasi (status %)', v_t.status USING ERRCODE = '22023'; END IF;
  IF v_t.kind = 'action' AND v_t.assigned_to IS NOT NULL AND EXISTS (SELECT 1 FROM profiles WHERE id = v_t.assigned_to AND contractor_id IS NULL) THEN
    PERFORM _deny('forbidden', 'Action ini milik PIC WFRD'); END IF;
  SELECT * INTO v_d FROM doc_type_catalog WHERE code = v_t.doc_type_code;
  SELECT * INTO v_k FROM contracts WHERE id = v_t.contract_id;
  IF v_k.status IN ('closed','terminated','suspended') THEN RAISE EXCEPTION 'Kontrak sedang %', v_k.status USING ERRCODE = '22023'; END IF;
  IF v_sha IS NOT NULL AND v_sha !~ '^[a-f0-9]{64}$' THEN RAISE EXCEPTION 'SHA-256 tidak valid' USING ERRCODE = '22023'; END IF;

  IF v_t.kind IN ('document','evidence') THEN
    v_link := resolve_upload_link(p_task);
    IF v_link IS NULL THEN RAISE EXCEPTION 'Link OneDrive belum tersedia — hubungi WFRD' USING ERRCODE = '22023'; END IF;
    IF v_file IS NULL OR v_file !~ ('^' || v_t.task_id || '([ .]|$)') OR v_file ~ '[/\\]' THEN
      RAISE EXCEPTION 'Nama file wajib diawali Task ID % diikuti spasi/titik', v_t.task_id USING ERRCODE = '22023'; END IF;
    IF p_integrity_attested IS NOT TRUE THEN RAISE EXCEPTION 'Pernyataan integritas wajib dicentang' USING ERRCODE = '22023'; END IF;
    IF v_d.requires_fingerprint AND v_sha IS NULL THEN RAISE EXCEPTION 'Sidik jari SHA-256 wajib untuk dokumen ini' USING ERRCODE = '22023'; END IF;
    IF v_d.requires_expiry AND (p_expiry_date IS NULL OR p_expiry_date <= CURRENT_DATE) THEN
      RAISE EXCEPTION 'Tanggal kedaluwarsa wajib dan harus di masa depan' USING ERRCODE = '22023'; END IF;
  ELSIF v_t.kind = 'form' THEN
    IF p_form_data IS NULL OR jsonb_typeof(p_form_data) <> 'object' OR length(p_form_data::TEXT) > 200000 THEN
      RAISE EXCEPTION 'Form wajib diisi' USING ERRCODE = '22023'; END IF;
    IF v_t.doc_type_code = 'MONRPT' AND (p_form_data ->> 'period' !~ '^\d{4}-(0[1-9]|1[0-2])$'
         OR jsonb_typeof(p_form_data -> 'man_hours') <> 'number' OR (p_form_data ->> 'man_hours')::NUMERIC < 0
         OR jsonb_typeof(p_form_data -> 'km_driven') <> 'number' OR (p_form_data ->> 'km_driven')::NUMERIC < 0) THEN
      RAISE EXCEPTION 'Monthly report: period YYYY-MM, man_hours & km_driven angka ≥ 0' USING ERRCODE = '22023'; END IF;
    IF v_t.doc_type_code = 'JRAREG' AND NOT EXISTS (SELECT 1 FROM risk_items WHERE contract_id = v_t.contract_id) THEN
      RAISE EXCEPTION 'JRA wajib memiliki minimal 1 risk item' USING ERRCODE = '22023'; END IF;
  ELSIF v_t.kind = 'checklist' THEN
    IF EXISTS (SELECT 1 FROM checklist_items WHERE task_id = p_task AND owner_party = 'contractor' AND NOT checked) THEN
      RAISE EXCEPTION 'Semua item contractor wajib dicentang' USING ERRCODE = '22023'; END IF;
  ELSIF v_t.kind = 'action' THEN
    IF _clean_text(p_evidence_ref, 500) IS NULL AND _clean_text(p_note, 1000) IS NULL THEN
      RAISE EXCEPTION 'Action wajib bukti atau catatan' USING ERRCODE = '22023'; END IF;
  END IF;

  IF v_d.requires_email THEN
    v_status := 'awaiting_email';
    v_code := upper(left(encode(hmac(v_t.task_id || '|' || (EXTRACT(EPOCH FROM v_now) * 1000000)::BIGINT,
                                     _secret('confirm_code_secret'), 'sha256'), 'hex'), 8));
    v_code := left(v_code, 4) || '-' || right(v_code, 4);
  ELSE
    v_status := 'submitted';
  END IF;

  UPDATE tasks SET
    status = v_status, status_reason = _clean_text(p_note, 1000), upload_link_id = v_link,
    uploaded_file_name = v_file, file_sha256 = v_sha, evidence_ref = _clean_text(p_evidence_ref, 500),
    integrity_attested = COALESCE(p_integrity_attested, FALSE), upload_confirmed_at = v_now, upload_confirmed_by = v_uid,
    confirm_code = v_code, email_claimed_at = NULL, email_verified = FALSE, email_verified_via = NULL, email_from = NULL,
    doc_number = _clean_text(p_doc_number, 120), issuer = _clean_text(p_issuer, 200), issue_date = p_issue_date, expiry_date = p_expiry_date,
    form_data = CASE WHEN v_t.kind = 'form' THEN p_form_data ELSE form_data END,
    review_due_at = CASE WHEN v_status = 'submitted' THEN _business_deadline(v_d.review_sla_days, v_k.geozone) END,
    updated_at = NOW()
  WHERE id = p_task;
  INSERT INTO task_events (task_id, event, actor_id, payload)
  VALUES (p_task, 'upload_confirmed', v_uid, jsonb_build_object('file', v_file, 'sha256', v_sha, 'status', v_status));
  IF v_status = 'submitted' THEN PERFORM _on_task_submitted(p_task); END IF;
  RETURN jsonb_build_object('status', v_status, 'confirm_code', v_code);
END $$;

CREATE OR REPLACE FUNCTION _on_task_submitted(p_task UUID) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_t tasks; v_u UUID;
BEGIN
  SELECT * INTO v_t FROM tasks WHERE id = p_task;
  IF v_t.doc_type_code = 'FNDCLS' THEN
    UPDATE audit_findings SET status = 'closure_submitted' WHERE fndcls_task_id = p_task AND status = 'open';
  END IF;
  IF v_t.reviewer_id IS NOT NULL THEN
    PERFORM _notify(v_t.reviewer_id, 'task_submitted', 'Siap direview: ' || v_t.task_id, v_t.title, '/tasks/' || p_task, 'info', 2004,
                    jsonb_build_object('task_id', v_t.task_id, 'title', v_t.title), 'submitted:' || p_task || ':' || v_t.upload_confirmed_at);
  ELSE
    FOR v_u IN SELECT p.id FROM profiles p WHERE p.status = 'active' AND p.contractor_id IS NULL AND _can_review_task(p.id, v_t)
                                             AND NOT p.is_root_admin LIMIT 20 LOOP
      PERFORM _notify(v_u, 'task_submitted', 'Siap direview: ' || v_t.task_id, v_t.title, '/tasks/' || p_task, 'info', 2004,
                      jsonb_build_object('task_id', v_t.task_id, 'title', v_t.title), 'submitted:' || p_task || ':' || v_t.upload_confirmed_at || ':' || v_u);
    END LOOP;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION claim_confirmation_email(p_task UUID) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_t tasks := _task_for_update(p_task); v_uid UUID; v_d doc_type_catalog;
BEGIN
  v_uid := _assert_task_perm('task.confirm_upload', v_t);
  IF v_t.status <> 'awaiting_email' THEN RAISE EXCEPTION 'Task tidak menunggu email konfirmasi' USING ERRCODE = '22023'; END IF;
  SELECT * INTO v_d FROM doc_type_catalog WHERE code = v_t.doc_type_code;
  UPDATE tasks SET status = 'submitted', email_claimed_at = NOW(),
                   review_due_at = _business_deadline(v_d.review_sla_days, (SELECT geozone FROM contracts WHERE id = v_t.contract_id)),
                   updated_at = NOW()
  WHERE id = p_task;
  INSERT INTO task_events (task_id, event, actor_id) VALUES (p_task, 'email_claimed', v_uid);
  PERFORM _on_task_submitted(p_task);
END $$;

-- Dipanggil Edge inbound-email (service_role) — TIDAK di-GRANT ke authenticated
-- p_sender_auth = hasil Edge: header Authentication-Results berisi dmarc=pass, atau spf=pass DAN dkim=pass
CREATE OR REPLACE FUNCTION verify_confirmation_email_inbound(p_task_id TEXT, p_from TEXT, p_code TEXT, p_subject TEXT,
  p_attachments INT, p_provider_msg_id TEXT, p_sender_auth BOOLEAN) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_t tasks; v_c contractors; v_from TEXT := lower(btrim(p_from)); v_sender BOOLEAN; v_match BOOLEAN; v_d doc_type_catalog;
BEGIN
  IF p_provider_msg_id IS NULL OR v_from IS NULL OR v_from !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN
    RETURN jsonb_build_object('ok', FALSE, 'reason', 'malformed');
  END IF;
  SELECT * INTO v_t FROM tasks WHERE task_id = upper(p_task_id) FOR UPDATE;
  IF EXISTS (SELECT 1 FROM task_emails WHERE direction = 'inbound' AND provider_msg_id = p_provider_msg_id) THEN
    RETURN jsonb_build_object('ok', FALSE, 'reason', 'duplicate');                -- retry webhook = idempotent
  END IF;
  IF NOT FOUND OR v_t.id IS NULL THEN
    INSERT INTO task_emails (direction, provider_msg_id, from_email, subject, code_matched, status)
    VALUES ('inbound', p_provider_msg_id, v_from, left(p_subject, 500), FALSE, 'unknown_task');
    RETURN jsonb_build_object('ok', FALSE, 'reason', 'unknown_task');
  END IF;
  SELECT * INTO v_c FROM contractors WHERE id = v_t.contractor_id;
  v_match := v_t.confirm_code IS NOT NULL AND upper(p_code) = v_t.confirm_code;
  v_sender := COALESCE(p_sender_auth, FALSE) AND (
              v_from IN (SELECT email FROM profiles WHERE contractor_id = v_c.id AND status = 'active')
           OR v_from IN (lower(v_c.primary_contact_email), lower(v_c.hse_manager_email))
           OR (v_c.email_domain IS NOT NULL AND split_part(v_from, '@', 2) = v_c.email_domain
               AND v_c.email_domain NOT IN ('gmail.com','googlemail.com','yahoo.com','yahoo.co.id','outlook.com','hotmail.com',
                                            'live.com','icloud.com','proton.me','protonmail.com','aol.com','ymail.com')));
  INSERT INTO task_emails (task_id, direction, provider_msg_id, from_email, subject, code_matched, sender_verified, attachments_count, status)
  VALUES (v_t.id, 'inbound', p_provider_msg_id, v_from, left(p_subject, 500), v_match, v_sender, p_attachments,
          CASE WHEN v_match AND v_sender THEN 'verified' ELSE 'rejected' END);
  IF NOT (v_match AND v_sender) OR v_t.status NOT IN ('awaiting_email','submitted','under_review') THEN
    RETURN jsonb_build_object('ok', FALSE, 'reason', CASE WHEN NOT v_match THEN 'code_mismatch' WHEN NOT v_sender THEN 'sender_unverified' ELSE 'bad_status' END);
  END IF;
  SELECT * INTO v_d FROM doc_type_catalog WHERE code = v_t.doc_type_code;
  UPDATE tasks SET email_verified = TRUE, email_verified_via = 'inbound_parsed', email_from = v_from,
                   status = CASE WHEN status = 'awaiting_email' THEN 'submitted' ELSE status END,
                   review_due_at = CASE WHEN status = 'awaiting_email'
                                        THEN _business_deadline(v_d.review_sla_days, (SELECT geozone FROM contracts WHERE id = v_t.contract_id))
                                        ELSE review_due_at END,
                   updated_at = NOW()
  WHERE id = v_t.id;
  INSERT INTO task_events (task_id, event, payload) VALUES (v_t.id, 'email_verified', jsonb_build_object('from', v_from, 'via', 'inbound'));
  IF v_t.status = 'awaiting_email' THEN PERFORM _on_task_submitted(v_t.id); END IF;
  RETURN jsonb_build_object('ok', TRUE, 'task', v_t.task_id);
END $$;

-- ═════════════ REVIEW ═════════════
CREATE OR REPLACE FUNCTION start_review(p_task UUID) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_t tasks := _task_for_update(p_task); v_uid UUID;
BEGIN
  v_uid := _assert_task_perm('task.review', v_t);
  IF NOT _can_review_task(v_uid, v_t) THEN PERFORM _deny('forbidden', 'Anda bukan reviewer untuk jenis dokumen ini'); END IF;
  IF v_t.status <> 'submitted' THEN RAISE EXCEPTION 'Task tidak dalam status submitted' USING ERRCODE = '22023'; END IF;
  UPDATE tasks SET status = 'under_review', review_started_at = NOW(), reviewer_id = COALESCE(reviewer_id, v_uid), updated_at = NOW()
  WHERE id = p_task;
  INSERT INTO task_events (task_id, event, actor_id) VALUES (p_task, 'review_started', v_uid);
END $$;

-- Buat revisi -R{n+1} dari task (dipakai revise & reopen)
CREATE OR REPLACE FUNCTION _create_revision(v_t tasks, p_due DATE, p_reason TEXT) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_id UUID; v_tid TEXT;
BEGIN
  IF v_t.revision >= 99 THEN RAISE EXCEPTION 'Batas revisi tercapai' USING ERRCODE = '22023'; END IF;
  v_tid := v_t.base_task_id || '-R' || (v_t.revision + 1);
  INSERT INTO tasks (task_id, revision, scope, contractor_id, contract_id, subcontractor_id, doc_type_code, kind, phase, title, description,
                     is_mandatory, is_blocker, source_ref, parent_task_id, renewal_of, assigned_to, reviewer_id, due_date, form_data, created_by)
  VALUES (v_tid, v_t.revision + 1, v_t.scope, v_t.contractor_id, v_t.contract_id, v_t.subcontractor_id, v_t.doc_type_code, v_t.kind,
          v_t.phase, v_t.title, v_t.description, v_t.is_mandatory, v_t.is_blocker, v_t.source_ref, v_t.id, v_t.renewal_of,
          v_t.assigned_to, v_t.reviewer_id, p_due, v_t.form_data, auth.uid())
  RETURNING id INTO v_id;
  INSERT INTO checklist_items (task_id, item_no, category, label, owner_party, checked, checked_by, checked_at, evidence_ref, notes)
  SELECT v_id, item_no, category, label, owner_party, checked, checked_by, checked_at, evidence_ref, notes
  FROM checklist_items WHERE task_id = v_t.id;
  UPDATE audit_findings SET fndcls_task_id = v_id, status = 'open' WHERE fndcls_task_id = v_t.id;
  INSERT INTO task_events (task_id, event, actor_id, payload) VALUES (v_id, 'created', auth.uid(), jsonb_build_object('revision_of', v_t.task_id, 'reason', p_reason));
  RETURN v_id;
END $$;

-- p_decision: approve | revise | reject | file_issue
CREATE OR REPLACE FUNCTION review_task(p_task UUID, p_decision TEXT, p_notes TEXT, p_email_confirmed BOOLEAN DEFAULT FALSE,
  p_fingerprint_verified BOOLEAN DEFAULT NULL, p_revision_due_days INT DEFAULT NULL) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_t tasks := _task_for_update(p_task); v_uid UUID; v_d doc_type_catalog; v_notes TEXT := _clean_text(p_notes, 4000);
        v_new UUID; v_status task_status; v_gz TEXT; v_tpl INT; v_dir UUID;
BEGIN
  v_uid := _assert_task_perm('task.review', v_t);
  IF NOT _can_review_task(v_uid, v_t) THEN PERFORM _deny('forbidden', 'Anda bukan reviewer untuk jenis dokumen ini'); END IF;
  IF v_t.status NOT IN ('submitted','under_review') THEN RAISE EXCEPTION 'Task belum siap direview (status %)', v_t.status USING ERRCODE = '22023'; END IF;
  IF p_decision NOT IN ('approve','revise','reject','file_issue') THEN RAISE EXCEPTION 'Keputusan tidak valid' USING ERRCODE = '22023'; END IF;
  IF p_decision <> 'approve' AND (v_notes IS NULL OR length(v_notes) < 5) THEN
    RAISE EXCEPTION 'Catatan wajib untuk revise/reject/file issue' USING ERRCODE = '22023'; END IF;
  SELECT * INTO v_d FROM doc_type_catalog WHERE code = v_t.doc_type_code;
  SELECT geozone INTO v_gz FROM contracts WHERE id = v_t.contract_id;

  IF p_decision = 'approve' THEN
    IF v_d.requires_email AND NOT v_t.email_verified AND p_email_confirmed IS NOT TRUE THEN
      RAISE EXCEPTION 'Konfirmasi dulu bahwa email dengan KODE % sudah diterima', v_t.confirm_code USING ERRCODE = '22023'; END IF;
    IF v_t.kind = 'checklist' AND EXISTS (SELECT 1 FROM checklist_items WHERE task_id = p_task AND NOT verified) THEN
      RAISE EXCEPTION 'Semua item checklist wajib diverifikasi' USING ERRCODE = '22023'; END IF;
    IF v_d.requires_fingerprint AND p_fingerprint_verified IS FALSE THEN
      RAISE EXCEPTION 'Sidik jari tidak cocok — gunakan File Issue' USING ERRCODE = '22023'; END IF;
    IF v_t.doc_type_code = 'JRAREG' AND NOT (
         EXISTS (SELECT 1 FROM signatures WHERE entity = 'jra' AND entity_id = p_task AND party = 'wfrd')
     AND EXISTS (SELECT 1 FROM signatures WHERE entity = 'jra' AND entity_id = p_task AND party = 'contractor')) THEN
      RAISE EXCEPTION 'JRA wajib ditandatangani kedua pihak sebelum approve' USING ERRCODE = '22023'; END IF;
    v_status := 'approved'; v_tpl := 2005;
  ELSIF p_decision = 'revise' THEN v_status := 'revise'; v_tpl := 2006;
  ELSIF p_decision = 'reject' THEN v_status := 'rejected'; v_tpl := 2007;
  ELSE v_status := 'file_issue'; v_tpl := 2008;
  END IF;

  UPDATE tasks SET status = v_status, status_reason = v_notes, reviewed_by = v_uid, reviewed_at = NOW(), review_notes = v_notes,
                   review_started_at = COALESCE(review_started_at, NOW()), reviewer_id = COALESCE(reviewer_id, v_uid),
                   fingerprint_verified = COALESCE(p_fingerprint_verified, fingerprint_verified),
                   email_verified = CASE WHEN p_decision = 'approve' AND v_d.requires_email AND NOT email_verified THEN TRUE ELSE email_verified END,
                   email_verified_via = CASE WHEN p_decision = 'approve' AND v_d.requires_email AND NOT email_verified THEN 'reviewer_confirmed' ELSE email_verified_via END,
                   approved_snapshot = CASE WHEN p_decision = 'approve' THEN left(concat_ws(' | ', uploaded_file_name, file_sha256, doc_number,
                                                 'exp ' || expiry_date, evidence_ref), 1000) END,
                   confirm_code = CASE WHEN p_decision = 'file_issue' THEN NULL ELSE confirm_code END,
                   updated_at = NOW()
  WHERE id = p_task;
  INSERT INTO task_events (task_id, event, actor_id, payload)
  VALUES (p_task, CASE p_decision WHEN 'approve' THEN 'approved' ELSE p_decision END, v_uid, jsonb_build_object('notes', v_notes));

  IF p_decision = 'revise' THEN
    v_new := _create_revision(v_t, add_business_days(_local_today(v_gz), COALESCE(p_revision_due_days, _setting_int('revision_due_days', 5)), v_gz), v_notes);
  ELSIF p_decision = 'reject' THEN
    FOR v_dir IN SELECT p.id FROM profiles p WHERE p.status = 'active' AND _user_has_role(p.id, 'hse_director')
                   AND (v_t.contract_id IS NULL OR _uid_has_contract_permission(p.id, 'task.waive', v_t.contract_id)) LOOP
      PERFORM _notify(v_dir, 'task_rejected_escalation', 'Task ditolak: ' || v_t.task_id, v_notes, '/tasks/' || p_task, 'warning',
                      NULL, '{}'::jsonb, 'rejesc:' || p_task || ':' || v_dir);
    END LOOP;
  END IF;

  PERFORM _notify_contractor(v_t.contractor_id, 'task_' || v_status, v_t.task_id || ': ' || v_status, v_notes,
                             '/tasks/' || COALESCE(v_new, p_task), CASE WHEN v_status = 'approved' THEN 'info' ELSE 'warning' END, v_tpl,
                             jsonb_build_object('task_id', v_t.task_id, 'title', v_t.title, 'notes', v_notes,
                                                'new_task_id', (SELECT task_id FROM tasks WHERE id = v_new)),
                             'review:' || p_task || ':' || v_status);
  IF v_t.contract_id IS NOT NULL THEN
    PERFORM _bot_contract(v_t.contract_id, 'task_card',
              CASE v_status WHEN 'approved' THEN '✅ ' WHEN 'revise' THEN '🔁 ' WHEN 'rejected' THEN '⛔ ' ELSE '⚠ ' END ||
              v_t.task_id || ' — ' || v_status, 'normal', ARRAY[v_t.task_id]);
  END IF;
  RETURN jsonb_build_object('status', v_status, 'new_task', v_new);
END $$;

-- ═════════════ AKSI LIFECYCLE ═════════════
CREATE OR REPLACE FUNCTION reopen_rejected_task(p_task UUID, p_due_days INT, p_reason TEXT) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_t tasks := _task_for_update(p_task); v_uid UUID; v_reason TEXT := _require_reason(p_reason); v_new UUID; v_gz TEXT;
BEGIN
  v_uid := _assert_task_perm('task.waive', v_t);
  IF v_t.status <> 'rejected' THEN RAISE EXCEPTION 'Hanya task rejected yang bisa dibuka ulang' USING ERRCODE = '22023'; END IF;
  SELECT geozone INTO v_gz FROM contracts WHERE id = v_t.contract_id;
  UPDATE tasks SET status = 'revise', status_reason = 'Dibuka ulang: ' || v_reason, updated_at = NOW() WHERE id = p_task;
  v_new := _create_revision(v_t, add_business_days(_local_today(v_gz), GREATEST(COALESCE(p_due_days, 5), 1), v_gz), v_reason);
  INSERT INTO task_events (task_id, event, actor_id, payload) VALUES (p_task, 'reopened', v_uid, jsonb_build_object('reason', v_reason, 'new', v_new));
  PERFORM _notify_contractor(v_t.contractor_id, 'task_reopened', v_t.task_id || ' dibuka ulang', v_reason, '/tasks/' || v_new, 'info', 2006,
                             jsonb_build_object('task_id', v_t.task_id, 'notes', v_reason), 'reopen:' || p_task);
  RETURN v_new;
END $$;

CREATE OR REPLACE FUNCTION waive_task(p_task UUID, p_reason TEXT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_t tasks := _task_for_update(p_task); v_uid UUID; v_reason TEXT := _require_reason(p_reason);
BEGIN
  v_uid := _assert_task_perm('task.waive', v_t);
  IF v_t.status NOT IN ('open','awaiting_email','file_issue','submitted','under_review','rejected') THEN
    RAISE EXCEPTION 'Task tidak bisa di-waive pada status %', v_t.status USING ERRCODE = '22023'; END IF;
  UPDATE tasks SET status = 'waived', status_reason = v_reason, reviewed_by = v_uid, reviewed_at = NOW(), updated_at = NOW() WHERE id = p_task;
  INSERT INTO task_events (task_id, event, actor_id, payload) VALUES (p_task, 'waived', v_uid, jsonb_build_object('reason', v_reason));
  PERFORM _notify_contractor(v_t.contractor_id, 'task_waived', v_t.task_id || ' di-waive (N/A)', v_reason, '/tasks/' || p_task, 'info');
END $$;

CREATE OR REPLACE FUNCTION cancel_task(p_task UUID, p_reason TEXT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_t tasks := _task_for_update(p_task); v_uid UUID; v_reason TEXT := _require_reason(p_reason);
BEGIN
  v_uid := _assert_task_perm('task.generate', v_t);
  IF v_t.status NOT IN ('open','awaiting_email','file_issue') THEN
    RAISE EXCEPTION 'Hanya task open/awaiting_email/file_issue yang bisa dibatalkan' USING ERRCODE = '22023'; END IF;
  UPDATE tasks SET status = 'cancelled', status_reason = v_reason, updated_at = NOW() WHERE id = p_task;
  INSERT INTO task_events (task_id, event, actor_id, payload) VALUES (p_task, 'cancelled', v_uid, jsonb_build_object('reason', v_reason));
  PERFORM _notify_contractor(v_t.contractor_id, 'task_cancelled', v_t.task_id || ' dibatalkan', v_reason, '/tasks/' || p_task, 'info');
END $$;

CREATE OR REPLACE FUNCTION supersede_task(p_task UUID, p_due DATE, p_reason TEXT) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_t tasks := _task_for_update(p_task); v_uid UUID; v_reason TEXT := _require_reason(p_reason); v_new UUID;
BEGIN
  v_uid := _assert_task_perm('task.generate', v_t);
  IF v_t.status <> 'approved' THEN RAISE EXCEPTION 'Hanya task approved yang bisa di-supersede (MOC)' USING ERRCODE = '22023'; END IF;
  IF p_due IS NULL OR p_due < CURRENT_DATE THEN RAISE EXCEPTION 'Due date baru wajib' USING ERRCODE = '22023'; END IF;
  v_new := _create_task(v_t.scope, v_t.contractor_id, v_t.contract_id, v_t.subcontractor_id, v_t.doc_type_code,
                        v_t.title || ' (MOC)', p_due, v_t.is_blocker, v_t.assigned_to, v_t.source_ref, 'MOC: ' || v_reason, v_t.is_mandatory, v_t.phase);
  UPDATE tasks SET status = 'superseded', superseded_by = v_new, status_reason = 'MOC: ' || v_reason, updated_at = NOW() WHERE id = p_task;
  INSERT INTO task_events (task_id, event, actor_id, payload) VALUES (p_task, 'superseded', v_uid, jsonb_build_object('reason', v_reason, 'new', v_new));
  PERFORM _notify_contractor(v_t.contractor_id, 'task_superseded', v_t.task_id || ' diganti (MOC)', v_reason, '/tasks/' || v_new, 'warning', 2001,
                             jsonb_build_object('task_id', (SELECT task_id FROM tasks WHERE id = v_new)), 'moc:' || p_task);
  RETURN v_new;
END $$;

CREATE OR REPLACE FUNCTION edit_task_due(p_task UUID, p_due DATE, p_reason TEXT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_t tasks := _task_for_update(p_task); v_uid UUID; v_reason TEXT := _require_reason(p_reason);
BEGIN
  v_uid := _assert_task_perm('task.edit_due', v_t);
  IF v_t.status NOT IN ('open','awaiting_email','file_issue') THEN RAISE EXCEPTION 'Due hanya bisa diubah untuk task terbuka' USING ERRCODE = '22023'; END IF;
  IF p_due IS NULL OR p_due < CURRENT_DATE THEN RAISE EXCEPTION 'Due date tidak boleh lampau' USING ERRCODE = '22023'; END IF;
  UPDATE tasks SET due_date = p_due, updated_at = NOW() WHERE id = p_task;
  INSERT INTO task_events (task_id, event, actor_id, payload)
  VALUES (p_task, 'due_changed', v_uid, jsonb_build_object('from', v_t.due_date, 'to', p_due, 'reason', v_reason));
  PERFORM _notify_contractor(v_t.contractor_id, 'task_due_changed', 'Due ' || v_t.task_id || ' → ' || p_due, v_reason, '/tasks/' || p_task, 'info');
END $$;

CREATE OR REPLACE FUNCTION nudge_task(p_task UUID, p_note TEXT, p_email BOOLEAN DEFAULT FALSE) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_t tasks := _task_for_update(p_task); v_uid UUID; v_note TEXT := _clean_text(p_note, 500); v_u UUID;
BEGIN
  v_uid := _assert_task_perm('task.nudge', v_t);
  IF v_t.status NOT IN ('open','awaiting_email','file_issue') THEN RAISE EXCEPTION 'Task tidak menunggu contractor' USING ERRCODE = '22023'; END IF;
  PERFORM hit_rate_limit('nudge:' || p_task, 1, INTERVAL '1 hour');
  FOR v_u IN SELECT * FROM _contractor_users(v_t.contractor_id) LOOP
    PERFORM _notify(v_u, 'task_nudge', '⏰ Pengingat: ' || v_t.task_id, COALESCE(v_note, v_t.title), '/tasks/' || p_task, 'warning',
                    CASE WHEN p_email THEN 2014 END, jsonb_build_object('task_id', v_t.task_id, 'title', v_t.title, 'note', v_note, 'due', v_t.due_date),
                    'nudge:' || p_task || ':' || v_u || ':' || date_trunc('hour', NOW()));
  END LOOP;
  IF v_t.contract_id IS NOT NULL THEN
    PERFORM _bot_task_thread(p_task, 'reminder', '⏰ Pengingat ' || v_t.task_id || COALESCE(' — ' || v_note, ''), 'important');
  END IF;
  INSERT INTO task_events (task_id, event, actor_id, payload) VALUES (p_task, 'nudged', v_uid, jsonb_build_object('note', v_note, 'email', p_email));
END $$;

-- ═════════════ CHECKLIST & ACTION ═════════════
CREATE OR REPLACE FUNCTION checklist_set_item(p_item UUID, p_checked BOOLEAN, p_evidence_ref TEXT, p_notes TEXT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_i checklist_items; v_t tasks; v_uid UUID;
BEGIN
  SELECT * INTO v_i FROM checklist_items WHERE id = p_item FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Item tidak ditemukan' USING ERRCODE = '22023'; END IF;
  v_t := _task_for_update(v_i.task_id);
  v_uid := _assert_task_perm('task.confirm_upload', v_t);
  IF v_i.owner_party <> 'contractor' THEN PERFORM _deny('forbidden', 'Item ini milik WFRD'); END IF;
  IF v_t.status NOT IN ('open','file_issue') THEN RAISE EXCEPTION 'Checklist sudah dikirim' USING ERRCODE = '22023'; END IF;
  UPDATE checklist_items SET checked = COALESCE(p_checked, FALSE), checked_by = v_uid, checked_at = NOW(),
                             evidence_ref = _clean_text(p_evidence_ref, 500), notes = _clean_text(p_notes, 1000), verified = FALSE,
                             verified_by = NULL, verified_at = NULL
  WHERE id = p_item;
END $$;

CREATE OR REPLACE FUNCTION checklist_verify_item(p_item UUID, p_verified BOOLEAN, p_notes TEXT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_i checklist_items; v_t tasks; v_uid UUID;
BEGIN
  SELECT * INTO v_i FROM checklist_items WHERE id = p_item FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Item tidak ditemukan' USING ERRCODE = '22023'; END IF;
  v_t := _task_for_update(v_i.task_id);
  v_uid := _assert_task_perm('task.review', v_t);
  IF NOT _can_review_task(v_uid, v_t) THEN PERFORM _deny('forbidden'); END IF;
  IF v_t.status NOT IN ('submitted','under_review') THEN RAISE EXCEPTION 'Checklist belum dikirim contractor' USING ERRCODE = '22023'; END IF;
  IF v_i.owner_party = 'contractor' AND NOT v_i.checked THEN RAISE EXCEPTION 'Item belum dicentang contractor' USING ERRCODE = '22023'; END IF;
  UPDATE checklist_items SET verified = COALESCE(p_verified, FALSE), verified_by = v_uid, verified_at = NOW(),
                             checked = CASE WHEN owner_party = 'wfrd' THEN COALESCE(p_verified, FALSE) ELSE checked END,
                             checked_by = CASE WHEN owner_party = 'wfrd' THEN v_uid ELSE checked_by END,
                             checked_at = CASE WHEN owner_party = 'wfrd' THEN NOW() ELSE checked_at END,
                             notes = COALESCE(_clean_text(p_notes, 1000), notes)
  WHERE id = p_item;
  IF v_t.status = 'submitted' THEN
    UPDATE tasks SET status = 'under_review', review_started_at = NOW(), reviewer_id = COALESCE(reviewer_id, v_uid) WHERE id = v_t.id;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION complete_wfrd_action(p_task UUID, p_evidence_ref TEXT, p_note TEXT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_t tasks := _task_for_update(p_task); v_uid UUID := assert_session(TRUE);
BEGIN
  IF v_t.kind <> 'action' OR v_t.status <> 'open' THEN RAISE EXCEPTION 'Bukan action terbuka' USING ERRCODE = '22023'; END IF;
  IF NOT auth_is_wfrd() OR (v_t.assigned_to IS DISTINCT FROM v_uid AND NOT
       (CASE WHEN v_t.contract_id IS NOT NULL THEN has_contract_permission('task.generate', v_t.contract_id) ELSE has_permission('task.generate') END)) THEN
    PERFORM _deny('forbidden');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = v_t.assigned_to AND contractor_id IS NULL) THEN
    RAISE EXCEPTION 'Action ini milik contractor' USING ERRCODE = '22023'; END IF;
  IF _clean_text(p_evidence_ref, 500) IS NULL AND _clean_text(p_note, 1000) IS NULL THEN
    RAISE EXCEPTION 'Bukti atau catatan wajib' USING ERRCODE = '22023'; END IF;
  UPDATE tasks SET status = 'approved', evidence_ref = _clean_text(p_evidence_ref, 500), review_notes = _clean_text(p_note, 1000),
                   upload_confirmed_at = NOW(), upload_confirmed_by = v_uid, reviewed_by = v_uid, reviewed_at = NOW(), updated_at = NOW()
  WHERE id = p_task;
  INSERT INTO task_events (task_id, event, actor_id, payload) VALUES (p_task, 'approved', v_uid, jsonb_build_object('wfrd_action', TRUE));
END $$;

-- ═════════════ VIEW (security_invoker → RLS pemanggil berlaku) ═════════════
CREATE VIEW v_task_tracking WITH (security_invoker = true) AS
SELECT t.id, t.task_id, t.base_task_id, t.revision, t.scope, t.kind, t.status, t.phase, t.title, t.doc_type_code, d.label AS doc_label,
       t.contractor_id, c.legal_name AS contractor_name, t.contract_id, k.contract_no, t.subcontractor_id,
       t.due_date, t.review_due_at, t.is_mandatory, t.is_blocker, t.assigned_to, t.reviewer_id, t.expiry_date,
       t.upload_confirmed_at, t.email_verified, t.created_at, t.updated_at,
       (t.status IN ('open','awaiting_email','file_issue') AND t.due_date < business_today()) AS is_overdue,
       (t.status IN ('submitted','under_review') AND t.review_due_at < NOW()) AS review_overdue
FROM tasks t
JOIN doc_type_catalog d ON d.code = t.doc_type_code
LEFT JOIN contractors c ON c.id = t.contractor_id
LEFT JOIN contracts k ON k.id = t.contract_id;

CREATE VIEW v_task_latest WITH (security_invoker = true) AS
SELECT DISTINCT ON (base_task_id) * FROM v_task_tracking ORDER BY base_task_id, revision DESC;
