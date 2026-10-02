CREATE OR REPLACE FUNCTION _user_has_role(p_uid UUID, p_role_key TEXT) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT EXISTS (SELECT 1 FROM user_roles ur JOIN roles r ON r.id = ur.role_id JOIN profiles p ON p.id = ur.user_id
                 WHERE ur.user_id = p_uid AND r.key = p_role_key AND p.status = 'active'
                   AND (ur.expires_at IS NULL OR ur.expires_at > NOW()))
$$;

CREATE OR REPLACE FUNCTION _vendor_ref(p_contractor UUID) RETURNS TEXT
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT 'CMN-V' || lpad(vendor_seq::TEXT, 5, '0') FROM contractors WHERE id = p_contractor
$$;

-- Status task yang masih "hidup" (belum final)
CREATE OR REPLACE FUNCTION _open_statuses() RETURNS task_status[]
LANGUAGE sql IMMUTABLE AS $$
  SELECT ARRAY['open','awaiting_email','submitted','under_review','file_issue','rejected']::task_status[]
$$;

-- Dokumen terpenuhi: ada approved yang belum kedaluwarsa / waived, dan tidak ada task non-renewal yang masih terbuka
CREATE OR REPLACE FUNCTION _doc_satisfied(p_contractor UUID, p_contract UUID, p_sub UUID, p_code TEXT) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT EXISTS (
           SELECT 1 FROM tasks t
           WHERE t.contractor_id = p_contractor AND t.contract_id IS NOT DISTINCT FROM p_contract
             AND t.subcontractor_id IS NOT DISTINCT FROM p_sub AND t.doc_type_code = p_code
             AND (t.status = 'waived' OR (t.status = 'approved' AND (t.expiry_date IS NULL OR t.expiry_date >= CURRENT_DATE))))
     AND NOT EXISTS (
           SELECT 1 FROM tasks t
           WHERE t.contractor_id = p_contractor AND t.contract_id IS NOT DISTINCT FROM p_contract
             AND t.subcontractor_id IS NOT DISTINCT FROM p_sub AND t.doc_type_code = p_code
             AND t.renewal_of IS NULL AND t.is_mandatory AND t.status = ANY(_open_statuses()))
$$;

-- ═════════════ VENDOR ═════════════
CREATE OR REPLACE FUNCTION admin_upsert_contractor(p_id UUID, p_data JSONB, p_reason TEXT) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_access('admin.contractors.manage'); v_reason TEXT := _require_reason(p_reason);
        v_id UUID := p_id; v_ver SMALLINT := _active_key_ver('data'); v_pc TEXT := _clean_email(p_data ->> 'primary_contact_email', FALSE);
BEGIN
  IF v_id IS NULL THEN
    INSERT INTO contractors (legal_name, registered_by) VALUES (_clean_text(p_data ->> 'legal_name', 200, TRUE), v_uid) RETURNING id INTO v_id;
  ELSIF NOT EXISTS (SELECT 1 FROM contractors WHERE id = v_id) THEN
    RAISE EXCEPTION 'Contractor tidak ditemukan' USING ERRCODE = '22023';
  END IF;
  BEGIN
    UPDATE contractors SET
      legal_name            = COALESCE(_clean_text(p_data ->> 'legal_name', 200), legal_name),
      trading_name          = CASE WHEN p_data ? 'trading_name' THEN _clean_text(p_data ->> 'trading_name', 200) ELSE trading_name END,
      registration_no       = CASE WHEN p_data ? 'registration_no' THEN _clean_text(p_data ->> 'registration_no', 60) ELSE registration_no END,
      tax_id                = CASE WHEN p_data ? 'tax_id' THEN _clean_text(p_data ->> 'tax_id', 40) ELSE tax_id END,
      country               = CASE WHEN p_data ? 'country' THEN upper(_clean_text(p_data ->> 'country', 2)) ELSE country END,
      address               = CASE WHEN p_data ? 'address' THEN _clean_text(p_data ->> 'address', 500) ELSE address END,
      website               = CASE WHEN p_data ? 'website' THEN _clean_text(p_data ->> 'website', 300) ELSE website END,
      primary_contact_name  = CASE WHEN p_data ? 'primary_contact_name' THEN _clean_text(p_data ->> 'primary_contact_name', 120) ELSE primary_contact_name END,
      primary_contact_email = CASE WHEN p_data ? 'primary_contact_email' THEN v_pc ELSE primary_contact_email END,
      email_domain          = CASE WHEN p_data ? 'email_domain' THEN lower(_clean_text(p_data ->> 'email_domain', 120))
                                   WHEN p_data ? 'primary_contact_email' THEN split_part(v_pc, '@', 2) ELSE email_domain END,
      primary_contact_phone_enc = CASE WHEN p_data ? 'primary_contact_phone' THEN _encrypt(_clean_text(p_data ->> 'primary_contact_phone', 20), 'data', v_ver) ELSE primary_contact_phone_enc END,
      enc_key_ver           = CASE WHEN p_data ? 'primary_contact_phone' THEN v_ver ELSE enc_key_ver END,
      hse_manager_name      = CASE WHEN p_data ? 'hse_manager_name' THEN _clean_text(p_data ->> 'hse_manager_name', 120) ELSE hse_manager_name END,
      hse_manager_email     = CASE WHEN p_data ? 'hse_manager_email' THEN _clean_email(p_data ->> 'hse_manager_email', FALSE) ELSE hse_manager_email END,
      internal_notes        = CASE WHEN p_data ? 'internal_notes' THEN _clean_text(p_data ->> 'internal_notes', 2000) ELSE internal_notes END,
      updated_at = NOW()
    WHERE id = v_id;
    IF COALESCE((p_data ->> 'submit')::BOOLEAN, FALSE) THEN
      UPDATE contractors SET status = 'under_review', submitted_at = COALESCE(submitted_at, NOW()) WHERE id = v_id AND status = 'draft';
      PERFORM generate_vendor_tasks(v_id);                    -- task dibuat; due berjalan sejak sekarang
    END IF;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'Tax ID sudah terdaftar untuk negara ini' USING ERRCODE = '23505', HINT = 'duplicate_tax_id';
  END;
  RETURN v_id;
END $$;

-- Contractor mengubah data kontak setelah submit (identitas legal hanya oleh WFRD)
CREATE OR REPLACE FUNCTION update_my_company(p_data JSONB) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_cid UUID := auth_contractor_id(); v_ver SMALLINT := _active_key_ver('data');
BEGIN
  PERFORM assert_access('company.edit', NULL, TRUE, v_cid);
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

CREATE OR REPLACE FUNCTION vendor_request_info(p_contractor UUID, p_message TEXT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_access('vendor.edit', NULL, TRUE, p_contractor); v_msg TEXT := _require_reason(p_message);
BEGIN
  UPDATE contractors SET status = 'draft', status_reason = v_msg, updated_at = NOW()
  WHERE id = p_contractor AND status = 'under_review';
  IF NOT FOUND THEN RAISE EXCEPTION 'Vendor tidak dalam status under_review' USING ERRCODE = '22023'; END IF;
  PERFORM _notify_contractor(p_contractor, 'vendor_needs_info', 'WFRD membutuhkan informasi tambahan', v_msg, '/register',
                             'warning', 1002, jsonb_build_object('message', v_msg), 'needinfo:' || p_contractor || ':' || extract(epoch FROM NOW())::BIGINT);
END $$;

CREATE OR REPLACE FUNCTION save_self_assessment(p_year INT, p_answers JSONB) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_cid UUID := auth_contractor_id(); v_uid UUID; v_id UUID;
BEGIN
  v_uid := assert_access('company.edit', NULL, TRUE, v_cid);
  IF jsonb_typeof(p_answers) <> 'object' OR length(p_answers::TEXT) > 100000 THEN RAISE EXCEPTION 'Jawaban tidak valid' USING ERRCODE = '22023'; END IF;
  INSERT INTO self_assessments (contractor_id, period_year, answers) VALUES (v_cid, p_year, p_answers)
  ON CONFLICT (contractor_id, period_year) DO UPDATE SET answers = EXCLUDED.answers, updated_at = NOW()
    WHERE self_assessments.status = 'draft'
  RETURNING id INTO v_id;
  IF v_id IS NULL THEN RAISE EXCEPTION 'Self-assessment sudah dikirim' USING ERRCODE = '22023'; END IF;
  RETURN v_id;
END $$;

-- answers.performance = {"y1":{recordable,lti,pvi,man_hours,km,fatality}, "y2":{…}, "y3":{…}}
CREATE OR REPLACE FUNCTION submit_self_assessment(p_year INT) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_cid UUID := auth_contractor_id(); v_uid UUID; v_sa self_assessments; v_n NUMERIC := _setting_int('kpi_normalizer', 200000);
        v_comp JSONB := '{}'::jsonb; y TEXT; v JSONB; v_fat INT := 0; v_mh NUMERIC; v_km NUMERIC;
BEGIN
  v_uid := assert_access('company.edit', NULL, TRUE, v_cid);
  SELECT * INTO v_sa FROM self_assessments WHERE contractor_id = v_cid AND period_year = p_year FOR UPDATE;
  IF NOT FOUND OR v_sa.status <> 'draft' THEN RAISE EXCEPTION 'Self-assessment tidak dalam draft' USING ERRCODE = '22023'; END IF;
  FOREACH y IN ARRAY ARRAY['y1','y2','y3'] LOOP
    v := v_sa.answers -> 'performance' -> y;
    IF v IS NULL THEN RAISE EXCEPTION 'Data performa % belum lengkap', y USING ERRCODE = '22023'; END IF;
    v_mh := NULLIF((v ->> 'man_hours')::NUMERIC, 0); v_km := NULLIF((v ->> 'km')::NUMERIC, 0);
    v_fat := v_fat + COALESCE((v ->> 'fatality')::INT, 0);
    v_comp := v_comp || jsonb_build_object(y, jsonb_build_object(
      'trir', round(((COALESCE((v ->> 'recordable')::NUMERIC, 0) + COALESCE((v ->> 'fatality')::NUMERIC, 0)) * v_n / v_mh), 3),
      'ltir', round(((COALESCE((v ->> 'lti')::NUMERIC, 0) + COALESCE((v ->> 'fatality')::NUMERIC, 0)) * v_n / v_mh), 3),
      'pvir', round((COALESCE((v ->> 'pvi')::NUMERIC, 0) * 1000000 / v_km), 3)));
  END LOOP;
  v_comp := v_comp || jsonb_build_object('fatality_3y', v_fat,
    'trir_avg', (SELECT round(avg((v_comp -> k ->> 'trir')::NUMERIC), 3) FROM unnest(ARRAY['y1','y2','y3']) k));
  UPDATE self_assessments SET computed = v_comp, status = 'submitted', submitted_by = v_uid, submitted_at = NOW(), updated_at = NOW()
  WHERE id = v_sa.id;
  PERFORM _notify_permission_holders('vendor.screen', NULL, 'self_assessment_submitted', 'Self-assessment siap di-screening',
                                     (SELECT legal_name FROM contractors WHERE id = v_cid), '/vendors/' || v_cid, 'info', NULL, '{}'::jsonb,
                                     'sa:' || v_sa.id);
  RETURN v_comp;
END $$;

-- p_scores = {hse_program:0-100, training:0-100, equipment:0-100, legal_gate:bool}; performance dihitung dari TRIR rata-rata 3 tahun
CREATE OR REPLACE FUNCTION screen_vendor(p_contractor UUID, p_scores JSONB, p_conditions TEXT) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_access('vendor.screen', NULL, TRUE, p_contractor); v_sa self_assessments;
        v_trir NUMERIC; v_perf NUMERIC; v_total NUMERIC; v_rec TEXT; v_s JSONB;
BEGIN
  SELECT * INTO v_sa FROM self_assessments WHERE contractor_id = p_contractor AND status = 'submitted' ORDER BY period_year DESC LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'Belum ada self-assessment yang dikirim' USING ERRCODE = '22023'; END IF;
  IF EXISTS (SELECT 1 FROM unnest(ARRAY['hse_program','training','equipment']) k
             WHERE (p_scores ->> k) IS NULL OR (p_scores ->> k)::NUMERIC NOT BETWEEN 0 AND 100) THEN
    RAISE EXCEPTION 'Skor komponen 0–100 wajib' USING ERRCODE = '22023';
  END IF;
  v_trir := (v_sa.computed ->> 'trir_avg')::NUMERIC;
  v_perf := CASE WHEN v_trir IS NULL THEN 30 WHEN v_trir <= 0.5 THEN 100 WHEN v_trir <= 1.0 THEN 80 WHEN v_trir <= 2.0 THEN 60 ELSE 30 END;
  v_total := round(0.4 * (p_scores ->> 'hse_program')::NUMERIC + 0.3 * v_perf + 0.2 * (p_scores ->> 'training')::NUMERIC
                   + 0.1 * (p_scores ->> 'equipment')::NUMERIC, 2);
  v_rec := CASE WHEN NOT COALESCE((p_scores ->> 'legal_gate')::BOOLEAN, FALSE) THEN 'reject'
                WHEN v_total >= 75 THEN 'approve' WHEN v_total >= 60 THEN 'conditional' ELSE 'reject' END;
  v_s := p_scores || jsonb_build_object('performance', v_perf, 'trir_avg', v_trir);
  INSERT INTO vendor_evaluations (contractor_id, self_assessment_id, scores, total, recommendation, conditions, screened_by)
  VALUES (p_contractor, v_sa.id, v_s, v_total, v_rec, _clean_text(p_conditions, 2000), v_uid);
  RETURN jsonb_build_object('total', v_total, 'recommendation', v_rec, 'scores', v_s);
END $$;

CREATE OR REPLACE FUNCTION decide_asl(p_contractor UUID, p_decision TEXT, p_conditions TEXT, p_reason TEXT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_access('vendor.asl.decide', NULL, TRUE, p_contractor); v_reason TEXT := _require_reason(p_reason);
        v_c contractors; v_fat INT; v_status vendor_status; v_tpl INT; v_missing TEXT;
BEGIN
  IF p_decision NOT IN ('approve','conditional','reject') THEN RAISE EXCEPTION 'Keputusan tidak valid' USING ERRCODE = '22023'; END IF;
  SELECT * INTO v_c FROM contractors WHERE id = p_contractor FOR UPDATE;
  IF v_c.status NOT IN ('under_review','asl_expired','asl_approved','asl_conditional') THEN
    RAISE EXCEPTION 'Status vendor tidak bisa diputuskan (%).', v_c.status USING ERRCODE = '22023';
  END IF;
  IF p_decision <> 'reject' THEN
    IF NOT EXISTS (SELECT 1 FROM vendor_evaluations WHERE contractor_id = p_contractor) THEN
      RAISE EXCEPTION 'Screening belum dilakukan' USING ERRCODE = '22023'; END IF;
    IF NOT EXISTS (SELECT 1 FROM tasks WHERE contractor_id = p_contractor AND scope = 'vendor') THEN
      RAISE EXCEPTION 'Task dokumen vendor belum dibuat (akun contractor belum aktif?)' USING ERRCODE = '22023'; END IF;
    SELECT string_agg(d.code, ', ') INTO v_missing FROM doc_type_catalog d
    WHERE d.active AND d.vendor_requirement IN ('mandatory','conditional')
      AND EXISTS (SELECT 1 FROM tasks t WHERE t.contractor_id = p_contractor AND t.scope = 'vendor' AND t.doc_type_code = d.code AND t.is_mandatory)
      AND NOT _doc_satisfied(p_contractor, NULL, NULL, d.code);
    IF v_missing IS NOT NULL THEN RAISE EXCEPTION 'Dokumen vendor wajib belum approved: %', v_missing USING ERRCODE = '22023'; END IF;
    SELECT (computed ->> 'fatality_3y')::INT INTO v_fat FROM self_assessments
    WHERE contractor_id = p_contractor AND status = 'submitted' ORDER BY period_year DESC LIMIT 1;
    IF COALESCE(v_fat, 0) > 0 AND NOT has_permission('risk.approve.critical') THEN
      PERFORM _deny('forbidden', 'Vendor dengan fatality 3 tahun terakhir hanya bisa disetujui HSE Director');
    END IF;
    IF p_decision = 'conditional' AND _clean_text(p_conditions, 2000) IS NULL THEN
      RAISE EXCEPTION 'Syarat ASL conditional wajib diisi' USING ERRCODE = '22023'; END IF;
  END IF;
  v_status := CASE p_decision WHEN 'approve' THEN 'asl_approved' WHEN 'conditional' THEN 'asl_conditional' ELSE 'rejected' END;
  v_tpl := CASE p_decision WHEN 'approve' THEN 1003 WHEN 'conditional' THEN 1004 ELSE 1005 END;
  UPDATE contractors SET status = v_status, status_reason = v_reason, asl_conditions = _clean_text(p_conditions, 2000),
         asl_expires_on = CASE WHEN p_decision = 'reject' THEN NULL ELSE (CURRENT_DATE + INTERVAL '2 years')::DATE END,
         asl_decided_by = v_uid, asl_decided_at = NOW(), updated_at = NOW()
  WHERE id = p_contractor;
  PERFORM _notify_contractor(p_contractor, 'asl_decision', 'Keputusan ASL: ' || v_status, v_reason, '/my-company',
                             CASE WHEN p_decision = 'reject' THEN 'warning' ELSE 'info' END, v_tpl,
                             jsonb_build_object('status', v_status, 'conditions', p_conditions), 'asl:' || p_contractor || ':' || extract(epoch FROM NOW())::BIGINT);
END $$;

CREATE OR REPLACE FUNCTION set_vendor_status(p_contractor UUID, p_status vendor_status, p_reason TEXT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_access('vendor.suspend', NULL, TRUE, p_contractor); v_reason TEXT := _require_reason(p_reason); v_c contractors;
        v_k RECORD;
BEGIN
  SELECT * INTO v_c FROM contractors WHERE id = p_contractor FOR UPDATE;
  IF p_status NOT IN ('suspended','blacklisted','asl_approved','asl_conditional') THEN
    RAISE EXCEPTION 'Status hanya suspended/blacklisted/reinstate' USING ERRCODE = '22023'; END IF;
  IF p_status IN ('asl_approved','asl_conditional') AND (v_c.status <> 'suspended' OR v_c.asl_expires_on < CURRENT_DATE) THEN
    RAISE EXCEPTION 'Reinstate hanya dari suspended dengan ASL belum kedaluwarsa' USING ERRCODE = '22023'; END IF;
  UPDATE contractors SET status = p_status, status_reason = v_reason, updated_at = NOW() WHERE id = p_contractor;
  IF p_status IN ('suspended','blacklisted') THEN
    FOR v_k IN SELECT id, process_owner_id FROM contracts WHERE contractor_id = p_contractor AND status NOT IN ('closed','terminated') LOOP
      PERFORM _notify(v_k.process_owner_id, 'vendor_suspended', 'Vendor ' || p_status || ': pertimbangkan hold kontrak', v_reason,
                      '/contracts/' || v_k.id, 'critical', NULL, '{}'::jsonb, 'vsusp:' || v_k.id || ':' || extract(epoch FROM NOW())::BIGINT);
    END LOOP;
  END IF;
  PERFORM _notify_contractor(p_contractor, 'vendor_status', 'Status vendor: ' || p_status, v_reason, '/my-company', 'warning');
END $$;

-- ═════════════ KONTRAK ═════════════
CREATE OR REPLACE FUNCTION _assert_contract_people(p_po UUID, p_reviewer UUID) RETURNS VOID
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
BEGIN
  IF NOT _user_has_role(p_po, 'process_owner') THEN
    RAISE EXCEPTION 'Process Owner harus user aktif dengan role process_owner' USING ERRCODE = '22023'; END IF;
  IF NOT (_user_has_role(p_reviewer, 'hse_reviewer') OR _user_has_role(p_reviewer, 'hse_admin')) THEN
    RAISE EXCEPTION 'HSE Reviewer harus user aktif dengan role hse_reviewer/hse_admin' USING ERRCODE = '22023'; END IF;
END $$;

CREATE OR REPLACE FUNCTION create_contract(p_contractor UUID, p_title TEXT, p_scope_of_work TEXT, p_geozone TEXT, p_site TEXT,
  p_risk_class TEXT, p_start DATE, p_end DATE, p_target_mob DATE, p_awarded_at DATE, p_process_owner UUID, p_hse_reviewer UUID,
  p_review_mailbox TEXT) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_access('contract.create', NULL, TRUE, NULL, p_geozone); v_c contractors; v_gz geozones; v_id UUID; v_no TEXT;
BEGIN
  SELECT * INTO v_c FROM contractors WHERE id = p_contractor;
  IF NOT FOUND OR v_c.status NOT IN ('asl_approved','asl_conditional') OR v_c.asl_expires_on < CURRENT_DATE THEN
    RAISE EXCEPTION 'Kontrak hanya untuk vendor dengan ASL aktif' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO v_gz FROM geozones WHERE code = p_geozone AND active;
  IF NOT FOUND THEN RAISE EXCEPTION 'Geozone tidak valid' USING ERRCODE = '22023'; END IF;
  IF p_risk_class NOT IN ('low','medium','high') THEN RAISE EXCEPTION 'Kelas risiko tidak valid' USING ERRCODE = '22023'; END IF;
  PERFORM _assert_contract_people(p_process_owner, p_hse_reviewer);

  INSERT INTO contracts (contractor_id, title, scope_of_work, geozone, site, risk_class, start_date, end_date, target_mob_date,
                         awarded_at, process_owner_id, hse_reviewer_id, review_mailbox, created_by)
  VALUES (p_contractor, _clean_text(p_title, 200, TRUE), _clean_text(p_scope_of_work, 8000), p_geozone, _clean_text(p_site, 200),
          p_risk_class, p_start, p_end, p_target_mob, COALESCE(p_awarded_at, CURRENT_DATE), p_process_owner, p_hse_reviewer,
          COALESCE(_clean_email(p_review_mailbox, FALSE), v_gz.review_mailbox), v_uid)
  RETURNING id, contract_no INTO v_id, v_no;

  PERFORM build_contract_requirements(v_id);
  PERFORM generate_contract_tasks(v_id, 'post_award');
  PERFORM _sync_contract_channel(v_id);
  PERFORM _notify_permission_holders('upload_link.manage', v_id, 'onedrive_setup', 'Siapkan folder OneDrive ' || v_no,
            'Buat folder kontrak & masukkan link', '/contracts/' || v_id || '/onedrive', 'warning', NULL, '{}'::jsonb, 'odsetup:' || v_id);
  PERFORM _notify_contractor(p_contractor, 'contract_awarded', 'Kontrak baru: ' || v_no, p_title, '/contracts/' || v_id, 'info', 4001,
                             jsonb_build_object('contract_no', v_no, 'title', p_title), 'awarded:' || v_id);
  RETURN v_id;
END $$;

-- p_patch keys: title, scope_of_work, site, end_date, target_mob_date, process_owner_id, hse_reviewer_id, review_mailbox, risk_class
CREATE OR REPLACE FUNCTION update_contract(p_contract UUID, p_patch JSONB, p_reason TEXT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_access('contract.edit', p_contract); v_reason TEXT := _require_reason(p_reason); v_k contracts; v_people BOOLEAN;
BEGIN
  SELECT * INTO v_k FROM contracts WHERE id = p_contract FOR UPDATE;
  IF v_k.status IN ('closed','terminated') THEN RAISE EXCEPTION 'Kontrak sudah ditutup' USING ERRCODE = '22023'; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_object_keys(p_patch) k WHERE k NOT IN
      ('title','scope_of_work','site','end_date','target_mob_date','process_owner_id','hse_reviewer_id','review_mailbox','risk_class')) THEN
    RAISE EXCEPTION 'Field tidak boleh diubah' USING ERRCODE = '22023'; END IF;
  IF p_patch ? 'risk_class' AND v_k.status NOT IN ('awarded','post_award') THEN
    RAISE EXCEPTION 'Kelas risiko hanya bisa diubah sebelum pre-mobilization' USING ERRCODE = '22023'; END IF;
  v_people := p_patch ? 'process_owner_id' OR p_patch ? 'hse_reviewer_id';
  IF v_people THEN
    PERFORM _assert_contract_people(COALESCE((p_patch ->> 'process_owner_id')::UUID, v_k.process_owner_id),
                                    COALESCE((p_patch ->> 'hse_reviewer_id')::UUID, v_k.hse_reviewer_id));
  END IF;
  UPDATE contracts SET
    title = COALESCE(_clean_text(p_patch ->> 'title', 200), title),
    scope_of_work = CASE WHEN p_patch ? 'scope_of_work' THEN _clean_text(p_patch ->> 'scope_of_work', 8000) ELSE scope_of_work END,
    site = CASE WHEN p_patch ? 'site' THEN _clean_text(p_patch ->> 'site', 200) ELSE site END,
    end_date = COALESCE((p_patch ->> 'end_date')::DATE, end_date),
    target_mob_date = COALESCE((p_patch ->> 'target_mob_date')::DATE, target_mob_date),
    process_owner_id = COALESCE((p_patch ->> 'process_owner_id')::UUID, process_owner_id),
    hse_reviewer_id = COALESCE((p_patch ->> 'hse_reviewer_id')::UUID, hse_reviewer_id),
    review_mailbox = COALESCE(_clean_email(p_patch ->> 'review_mailbox', FALSE), review_mailbox),
    risk_class = COALESCE(p_patch ->> 'risk_class', risk_class),
    updated_at = NOW()
  WHERE id = p_contract;
  IF p_patch ? 'risk_class' THEN PERFORM build_contract_requirements(p_contract); END IF;
  IF v_people THEN PERFORM _sync_contract_channel(p_contract); END IF;
END $$;

CREATE OR REPLACE FUNCTION _premob_complete(p_q JSONB) RETURNS BOOLEAN
LANGUAGE sql IMMUTABLE AS $$
  SELECT NOT EXISTS (SELECT 1 FROM unnest(ARRAY['has_confined_space','has_hot_work','has_work_at_height','has_chemicals',
                                                'near_water','has_driving','generates_waste','has_subcontractor']) k
                     WHERE jsonb_typeof(p_q -> k) IS DISTINCT FROM 'boolean')
     AND jsonb_typeof(p_q -> 'max_workers_on_site') = 'number' AND (p_q ->> 'max_workers_on_site')::NUMERIC >= 0
$$;

CREATE OR REPLACE FUNCTION save_premob_questionnaire(p_contract UUID, p_answers JSONB) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_k contracts;
BEGIN
  IF auth_is_wfrd() THEN PERFORM assert_access('contract.edit', p_contract); ELSE PERFORM assert_access('record.submit', p_contract); END IF;
  SELECT * INTO v_k FROM contracts WHERE id = p_contract FOR UPDATE;
  IF v_k.status NOT IN ('awarded','post_award') THEN
    RAISE EXCEPTION 'Questionnaire terkunci setelah pre-mobilization (gunakan MOC)' USING ERRCODE = '22023'; END IF;
  IF jsonb_typeof(p_answers) <> 'object' OR EXISTS (SELECT 1 FROM jsonb_object_keys(p_answers) k WHERE k NOT IN
      ('has_confined_space','has_hot_work','has_work_at_height','has_chemicals','near_water','has_driving','generates_waste',
       'has_subcontractor','max_workers_on_site')) THEN
    RAISE EXCEPTION 'Jawaban questionnaire tidak valid' USING ERRCODE = '22023'; END IF;
  UPDATE contracts SET premob_questionnaire = p_answers, updated_at = NOW() WHERE id = p_contract;
END $$;

CREATE OR REPLACE FUNCTION mobilization_blockers(p_contract UUID)
RETURNS TABLE (code TEXT, ref TEXT, detail TEXT)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_k contracts;
BEGIN
  PERFORM assert_session(FALSE);
  IF NOT can_view_contract(p_contract) THEN PERFORM _deny('forbidden'); END IF;
  SELECT * INTO v_k FROM contracts WHERE id = p_contract;
  RETURN QUERY
    SELECT 'gate_document'::TEXT, cr.doc_type_code, d.label FROM contract_requirements cr JOIN doc_type_catalog d ON d.code = cr.doc_type_code
    WHERE cr.contract_id = p_contract AND cr.applicable AND cr.is_mob_gate AND d.phase = 'pre_mobilization'
      AND NOT _doc_satisfied(v_k.contractor_id, p_contract, NULL, cr.doc_type_code)
  UNION ALL
    SELECT 'subcontractor_pending', s.id::TEXT, s.legal_name FROM subcontractors s WHERE s.contract_id = p_contract AND s.status = 'pending'
  UNION ALL
    SELECT 'finding_open', f.finding_no, f.severity || ': ' || left(f.description, 120) FROM audit_findings f
    WHERE f.contract_id = p_contract AND f.severity IN ('critical','major') AND f.status IN ('open','closure_submitted')
  UNION ALL
    SELECT 'blocker_task', t.task_id, t.title FROM tasks t
    WHERE t.contract_id = p_contract AND t.is_blocker AND t.status = ANY(_open_statuses())
  UNION ALL
    SELECT CASE WHEN r.residual_score >= 20 THEN 'residual_critical' ELSE 'residual_high' END, r.id::TEXT, left(r.hazard, 120)
    FROM risk_items r WHERE r.contract_id = p_contract AND r.residual_score >= 10 AND r.residual_approved_at IS NULL;
END $$;

CREATE OR REPLACE FUNCTION demob_blockers(p_contract UUID)
RETURNS TABLE (code TEXT, ref TEXT, detail TEXT)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
BEGIN
  PERFORM assert_session(FALSE);
  IF NOT can_view_contract(p_contract) THEN PERFORM _deny('forbidden'); END IF;
  RETURN QUERY
    SELECT 'incident_open'::TEXT, i.incident_no, i.title FROM incidents i WHERE i.contract_id = p_contract AND i.status <> 'closed'
  UNION ALL
    SELECT 'finding_open', f.finding_no, left(f.description, 120) FROM audit_findings f
    WHERE f.contract_id = p_contract AND f.status IN ('open','closure_submitted')
  UNION ALL
    SELECT 'task_open', t.task_id, t.title FROM tasks t
    WHERE t.contract_id = p_contract AND t.is_mandatory AND t.status = ANY(_open_statuses()) AND t.doc_type_code <> 'OPRSLF'
  UNION ALL
    SELECT 'demob_checklist', 'DMBCHK', 'Checklist demobilisasi belum approved'
    WHERE NOT _doc_satisfied((SELECT contractor_id FROM contracts WHERE id = p_contract), p_contract, NULL, 'DMBCHK');
END $$;

CREATE OR REPLACE FUNCTION transition_contract(p_contract UUID, p_target contract_status, p_reason TEXT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_access('contract.transition', p_contract); v_reason TEXT := _require_reason(p_reason);
        v_k contracts; v_from contract_status; v_n INT;
BEGIN
  SELECT * INTO v_k FROM contracts WHERE id = p_contract FOR UPDATE;
  v_from := v_k.status;
  IF v_from IN ('closed','terminated') THEN RAISE EXCEPTION 'Kontrak sudah final' USING ERRCODE = '22023'; END IF;

  IF p_target = 'suspended' THEN
    IF v_from = 'suspended' THEN RAISE EXCEPTION 'Kontrak sudah di-hold' USING ERRCODE = '22023'; END IF;
    UPDATE contracts SET status = 'suspended', status_before_hold = v_from, updated_at = NOW() WHERE id = p_contract;
  ELSIF v_from = 'suspended' AND p_target <> 'terminated' THEN
    IF p_target IS DISTINCT FROM v_k.status_before_hold THEN
      RAISE EXCEPTION 'Resume hanya ke status sebelum hold (%)', v_k.status_before_hold USING ERRCODE = '22023'; END IF;
    UPDATE contracts SET status = p_target, status_before_hold = NULL, updated_at = NOW() WHERE id = p_contract;
  ELSIF p_target = 'terminated' THEN
    UPDATE contracts SET status = 'terminated', status_before_hold = NULL, closed_at = NOW(), updated_at = NOW() WHERE id = p_contract;
    UPDATE tasks SET status = 'cancelled', status_reason = 'Kontrak diterminasi: ' || v_reason, updated_at = NOW()
    WHERE contract_id = p_contract AND status = ANY(_open_statuses());
    UPDATE audit_findings SET status = 'cancelled' WHERE contract_id = p_contract AND status IN ('open','closure_submitted');
  ELSE
    CASE
      WHEN v_from = 'awarded' AND p_target = 'post_award' THEN NULL;
      WHEN v_from = 'post_award' AND p_target = 'pre_mobilization' THEN
        IF NOT EXISTS (SELECT 1 FROM meetings WHERE contract_id = p_contract AND meeting_type = 'post_award' AND status = 'signed') THEN
          RAISE EXCEPTION 'MoM post-award belum ditandatangani kedua pihak' USING ERRCODE = '22023'; END IF;
        IF NOT _premob_complete(v_k.premob_questionnaire) THEN
          RAISE EXCEPTION 'Pre-mob questionnaire belum lengkap' USING ERRCODE = '22023'; END IF;
      WHEN v_from = 'pre_mobilization' AND p_target = 'mobilization' THEN
        SELECT count(*) INTO v_n FROM mobilization_blockers(p_contract);
        IF v_n > 0 THEN RAISE EXCEPTION 'Masih ada % blocker mobilisasi', v_n USING ERRCODE = '22023'; END IF;
      WHEN v_from = 'active' AND p_target = 'demobilization' THEN NULL;
      WHEN v_from = 'demobilization' AND p_target = 'final_evaluation' THEN
        SELECT count(*) INTO v_n FROM demob_blockers(p_contract);
        IF v_n > 0 THEN RAISE EXCEPTION 'Masih ada % blocker demobilisasi', v_n USING ERRCODE = '22023'; END IF;
      WHEN v_from = 'final_evaluation' AND p_target = 'closed' THEN
        IF NOT EXISTS (SELECT 1 FROM opr_reviews WHERE contract_id = p_contract AND status = 'signed') THEN
          RAISE EXCEPTION 'OPR belum ditandatangani' USING ERRCODE = '22023'; END IF;
        IF EXISTS (SELECT 1 FROM tasks WHERE contract_id = p_contract AND doc_type_code = 'OPRSLF' AND status = ANY(_open_statuses())) THEN
          RAISE EXCEPTION 'OPR self-evaluation contractor belum selesai (approve atau waive)' USING ERRCODE = '22023'; END IF;
      WHEN v_from = 'mobilization' AND p_target = 'active' THEN
        RAISE EXCEPTION 'Gunakan Request/Approve Go-Live' USING ERRCODE = '22023';
      ELSE
        RAISE EXCEPTION 'Transisi % → % tidak diizinkan', v_from, p_target USING ERRCODE = '22023';
    END CASE;
    UPDATE contracts SET status = p_target, updated_at = NOW(),
                         closed_at = CASE WHEN p_target = 'closed' THEN NOW() ELSE closed_at END
    WHERE id = p_contract;
    IF p_target IN ('pre_mobilization','mobilization','demobilization','final_evaluation') THEN
      PERFORM build_contract_requirements(p_contract);
      PERFORM generate_contract_tasks(p_contract, p_target::TEXT::lifecycle_phase);
    END IF;
  END IF;

  PERFORM _bot_contract(p_contract, 'system', 'Status kontrak: ' || v_from || ' → ' || p_target || ' · ' || v_reason, 'normal');
  PERFORM _notify_contractor(v_k.contractor_id, 'contract_status', v_k.contract_no || ': ' || p_target, v_reason, '/contracts/' || p_contract,
            CASE WHEN p_target IN ('suspended','terminated') THEN 'warning' ELSE 'info' END,
            CASE p_target WHEN 'mobilization' THEN 4003 WHEN 'demobilization' THEN 4006 WHEN 'closed' THEN 4008 ELSE NULL END,
            jsonb_build_object('contract_no', v_k.contract_no, 'status', p_target), 'ctr:' || p_contract || ':' || p_target || ':' || extract(epoch FROM NOW())::BIGINT);
  IF p_target IN ('closed','terminated') THEN
    UPDATE chat_channels SET is_archived = TRUE WHERE contract_id = p_contract;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION request_go_live(p_contract UUID) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_access('contract.golive.request', p_contract); v_k contracts;
BEGIN
  SELECT * INTO v_k FROM contracts WHERE id = p_contract FOR UPDATE;
  IF v_k.status <> 'mobilization' THEN RAISE EXCEPTION 'Kontrak tidak dalam mobilisasi' USING ERRCODE = '22023'; END IF;
  IF NOT _doc_satisfied(v_k.contractor_id, p_contract, NULL, 'MOBCHK') THEN
    RAISE EXCEPTION 'Checklist mobilisasi belum 100%% terverifikasi & approved' USING ERRCODE = '22023'; END IF;
  UPDATE contracts SET golive_requested_at = NOW(), golive_requested_by = v_uid WHERE id = p_contract;
  PERFORM _notify(v_k.process_owner_id, 'golive_request', 'Permintaan Go-Live ' || v_k.contract_no, NULL,
                  '/contracts/' || p_contract, 'warning', NULL, '{}'::jsonb, 'golivereq:' || p_contract || ':' || extract(epoch FROM NOW())::BIGINT);
  PERFORM _bot_contract(p_contract, 'system', 'Contractor mengajukan Go-Live — menunggu persetujuan PO/Director', 'important');
END $$;

CREATE OR REPLACE FUNCTION approve_go_live(p_contract UUID, p_reason TEXT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_access('contract.golive.approve', p_contract); v_reason TEXT := _require_reason(p_reason); v_k contracts;
BEGIN
  SELECT * INTO v_k FROM contracts WHERE id = p_contract FOR UPDATE;
  IF v_uid <> v_k.process_owner_id AND NOT _user_has_role(v_uid, 'hse_director') AND NOT _user_has_role(v_uid, 'super_admin') THEN
    PERFORM _deny('forbidden', 'Go-Live hanya oleh PO kontrak ini atau HSE Director');
  END IF;
  IF v_k.status <> 'mobilization' OR v_k.golive_requested_at IS NULL THEN
    RAISE EXCEPTION 'Belum ada permintaan Go-Live' USING ERRCODE = '22023'; END IF;
  IF NOT _doc_satisfied(v_k.contractor_id, p_contract, NULL, 'MOBCHK') THEN
    RAISE EXCEPTION 'Checklist mobilisasi belum approved' USING ERRCODE = '22023'; END IF;
  UPDATE contracts SET status = 'active', golive_approved_at = NOW(), golive_approved_by = v_uid, updated_at = NOW() WHERE id = p_contract;
  PERFORM _notify_contractor(v_k.contractor_id, 'golive', 'Go-Live disetujui: ' || v_k.contract_no, v_reason, '/contracts/' || p_contract,
                             'info', 4004, jsonb_build_object('contract_no', v_k.contract_no), 'golive:' || p_contract);
  PERFORM _bot_contract(p_contract, 'system', '✅ Go-Live disetujui — kontrak ACTIVE', 'important');
END $$;

-- ═════════════ SUBCONTRACTOR ═════════════
CREATE OR REPLACE FUNCTION add_subcontractor(p_contract UUID, p_data JSONB) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID; v_k contracts; v_seq INT; v_id UUID;
BEGIN
  IF auth_is_wfrd() THEN v_uid := assert_access('contract.edit', p_contract); ELSE v_uid := assert_access('record.submit', p_contract); END IF;
  SELECT * INTO v_k FROM contracts WHERE id = p_contract FOR UPDATE;
  IF v_k.status NOT IN ('post_award','pre_mobilization','mobilization','active') THEN
    RAISE EXCEPTION 'Subcontractor tidak bisa ditambahkan pada status ini' USING ERRCODE = '22023'; END IF;
  SELECT COALESCE(max(sub_seq), 0) + 1 INTO v_seq FROM subcontractors WHERE contract_id = p_contract;
  IF v_seq > 99 THEN RAISE EXCEPTION 'Maksimum 99 subcontractor per kontrak' USING ERRCODE = '22023'; END IF;
  INSERT INTO subcontractors (contract_id, sub_seq, legal_name, scope_of_work, pic_name, pic_email, hse_manager, est_manpower,
                              on_site_from, on_site_to, created_by)
  VALUES (p_contract, v_seq, _clean_text(p_data ->> 'legal_name', 200, TRUE), _clean_text(p_data ->> 'scope_of_work', 4000, TRUE),
          _clean_text(p_data ->> 'pic_name', 120), _clean_email(p_data ->> 'pic_email', FALSE), _clean_text(p_data ->> 'hse_manager', 120),
          (p_data ->> 'est_manpower')::INT, (p_data ->> 'on_site_from')::DATE, (p_data ->> 'on_site_to')::DATE, v_uid)
  RETURNING id INTO v_id;
  PERFORM generate_subcontractor_tasks(v_id);
  PERFORM _notify_permission_holders('subcon.approve', p_contract, 'subcon_request', 'Subcontractor baru: ' || (p_data ->> 'legal_name'),
            v_k.contract_no, '/contracts/' || p_contract, 'info', 3005, jsonb_build_object('contract_no', v_k.contract_no), 'subreq:' || v_id);
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION decide_subcontractor(p_sub UUID, p_decision TEXT, p_reason TEXT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_s subcontractors; v_k contracts; v_uid UUID; v_reason TEXT := _require_reason(p_reason); v_missing TEXT;
BEGIN
  SELECT * INTO v_s FROM subcontractors WHERE id = p_sub FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Subcontractor tidak ditemukan' USING ERRCODE = '22023'; END IF;
  v_uid := assert_access('subcon.approve', v_s.contract_id);
  SELECT * INTO v_k FROM contracts WHERE id = v_s.contract_id;
  IF p_decision NOT IN ('approved','rejected','removed') THEN RAISE EXCEPTION 'Keputusan tidak valid' USING ERRCODE = '22023'; END IF;
  IF p_decision = 'approved' THEN
    SELECT string_agg(DISTINCT t.doc_type_code, ', ') INTO v_missing FROM tasks t
    WHERE t.subcontractor_id = p_sub AND t.is_mandatory AND NOT _doc_satisfied(v_k.contractor_id, v_k.id, p_sub, t.doc_type_code);
    IF v_missing IS NOT NULL THEN RAISE EXCEPTION 'Dokumen subcontractor belum approved: %', v_missing USING ERRCODE = '22023'; END IF;
  ELSE
    UPDATE tasks SET status = 'cancelled', status_reason = 'Subcontractor ' || p_decision, updated_at = NOW()
    WHERE subcontractor_id = p_sub AND status = ANY(_open_statuses());
  END IF;
  UPDATE subcontractors SET status = p_decision, decided_by = v_uid, decided_at = NOW(), decision_reason = v_reason WHERE id = p_sub;
  PERFORM _notify_contractor(v_k.contractor_id, 'subcon_decision', 'Subcontractor ' || v_s.legal_name || ': ' || p_decision, v_reason,
                             '/contracts/' || v_k.id, 'info');
END $$;

-- ═════════════ RISK (JRA) ═════════════
CREATE OR REPLACE FUNCTION upsert_risk_item(p_contract UUID, p_id UUID, p_data JSONB) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID; v_id UUID := p_id; v_old risk_items;
BEGIN
  IF auth_is_wfrd() THEN v_uid := assert_access('contract.edit', p_contract); ELSE v_uid := assert_access('record.submit', p_contract); END IF;
  IF EXISTS (SELECT 1 FROM contracts WHERE id = p_contract AND status IN ('closed','terminated')) THEN
    RAISE EXCEPTION 'Kontrak sudah ditutup' USING ERRCODE = '22023'; END IF;
  IF v_id IS NULL THEN
    INSERT INTO risk_items (contract_id, task_id, hazard, category, location_activity, exposed, existing_controls, likelihood, severity,
                            additional_controls, residual_likelihood, residual_severity, action_owner, due_date, evidence_ref, created_by)
    VALUES (p_contract, (SELECT id FROM tasks WHERE contract_id = p_contract AND doc_type_code = 'JRAREG' ORDER BY revision DESC LIMIT 1),
            _clean_text(p_data ->> 'hazard', 500, TRUE), _clean_text(p_data ->> 'category', 80), _clean_text(p_data ->> 'location_activity', 300),
            _clean_text(p_data ->> 'exposed', 300), COALESCE(p_data -> 'existing_controls', '{}'::jsonb),
            (p_data ->> 'likelihood')::SMALLINT, (p_data ->> 'severity')::SMALLINT, _clean_text(p_data ->> 'additional_controls', 2000),
            (p_data ->> 'residual_likelihood')::SMALLINT, (p_data ->> 'residual_severity')::SMALLINT,
            _clean_text(p_data ->> 'action_owner', 120), (p_data ->> 'due_date')::DATE, _clean_text(p_data ->> 'evidence_ref', 500), v_uid)
    RETURNING id INTO v_id;
  ELSE
    SELECT * INTO v_old FROM risk_items WHERE id = v_id AND contract_id = p_contract FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Risk item tidak ditemukan' USING ERRCODE = '22023'; END IF;
    UPDATE risk_items SET
      hazard = _clean_text(p_data ->> 'hazard', 500, TRUE), category = _clean_text(p_data ->> 'category', 80),
      location_activity = _clean_text(p_data ->> 'location_activity', 300), exposed = _clean_text(p_data ->> 'exposed', 300),
      existing_controls = COALESCE(p_data -> 'existing_controls', '{}'::jsonb),
      likelihood = (p_data ->> 'likelihood')::SMALLINT, severity = (p_data ->> 'severity')::SMALLINT,
      additional_controls = _clean_text(p_data ->> 'additional_controls', 2000),
      residual_likelihood = (p_data ->> 'residual_likelihood')::SMALLINT, residual_severity = (p_data ->> 'residual_severity')::SMALLINT,
      action_owner = _clean_text(p_data ->> 'action_owner', 120), due_date = (p_data ->> 'due_date')::DATE,
      evidence_ref = _clean_text(p_data ->> 'evidence_ref', 500), updated_at = NOW(),
      residual_approved_by = CASE WHEN (p_data ->> 'residual_likelihood')::SMALLINT = v_old.residual_likelihood
                                   AND (p_data ->> 'residual_severity')::SMALLINT = v_old.residual_severity THEN residual_approved_by END,
      residual_approved_at = CASE WHEN (p_data ->> 'residual_likelihood')::SMALLINT = v_old.residual_likelihood
                                   AND (p_data ->> 'residual_severity')::SMALLINT = v_old.residual_severity THEN residual_approved_at END
    WHERE id = v_id;
  END IF;
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION delete_risk_item(p_id UUID, p_reason TEXT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_r risk_items; v_reason TEXT := _require_reason(p_reason);
BEGIN
  SELECT * INTO v_r FROM risk_items WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Risk item tidak ditemukan' USING ERRCODE = '22023'; END IF;
  PERFORM assert_access('contract.edit', v_r.contract_id);                  -- hanya WFRD
  DELETE FROM risk_items WHERE id = p_id;
END $$;

CREATE OR REPLACE FUNCTION approve_residual_risk(p_risk UUID, p_reason TEXT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_r risk_items; v_uid UUID; v_reason TEXT := _require_reason(p_reason);
BEGIN
  SELECT * INTO v_r FROM risk_items WHERE id = p_risk FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Risk item tidak ditemukan' USING ERRCODE = '22023'; END IF;
  IF v_r.residual_score >= 20 THEN v_uid := assert_access('risk.approve.critical', v_r.contract_id);
  ELSIF v_r.residual_score >= 10 THEN v_uid := assert_access('risk.approve.high', v_r.contract_id);
  ELSE RAISE EXCEPTION 'Residual Low/Medium tidak memerlukan approval' USING ERRCODE = '22023'; END IF;
  UPDATE risk_items SET residual_approved_by = v_uid, residual_approved_at = NOW() WHERE id = p_risk;
END $$;

-- ═════════════ MEETING & TANDA TANGAN ═════════════
CREATE OR REPLACE FUNCTION create_meeting(p_contract UUID, p_type TEXT, p_scheduled_at TIMESTAMPTZ, p_location TEXT, p_agenda JSONB)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_access('meeting.manage', p_contract); v_id UUID;
BEGIN
  IF p_type NOT IN ('post_award','progress','audit_closing','other') THEN RAISE EXCEPTION 'Tipe meeting tidak valid' USING ERRCODE = '22023'; END IF;
  INSERT INTO meetings (contract_id, meeting_type, mom_no, scheduled_at, location, agenda, created_by)
  VALUES (p_contract, p_type, _next_record_no('MOM', p_contract), p_scheduled_at, _clean_text(p_location, 200),
          COALESCE(p_agenda, CASE WHEN p_type = 'post_award' THEN '["Perkenalan & peran","Scope of Work","Persyaratan HSE","HSE Plan",
            "Bridging Document","Rencana JRA","Subcontractor","Training","Equipment","Emergency response","Pelaporan insiden",
            "KPI & laporan","Jadwal audit","Jadwal mobilisasi","AOB & action items"]'::jsonb ELSE '[]'::jsonb END), v_uid)
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- p_attendees = [{user_id?, name, party, role_title}]
CREATE OR REPLACE FUNCTION update_meeting(p_meeting UUID, p_minutes JSONB, p_attendees JSONB) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_m meetings;
BEGIN
  SELECT * INTO v_m FROM meetings WHERE id = p_meeting FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Meeting tidak ditemukan' USING ERRCODE = '22023'; END IF;
  PERFORM assert_access('meeting.manage', v_m.contract_id);
  IF v_m.status <> 'draft' THEN RAISE EXCEPTION 'MoM sudah final' USING ERRCODE = '22023'; END IF;
  UPDATE meetings SET minutes = COALESCE(p_minutes, minutes) WHERE id = p_meeting;
  IF p_attendees IS NOT NULL THEN
    DELETE FROM meeting_attendees WHERE meeting_id = p_meeting;
    INSERT INTO meeting_attendees (meeting_id, user_id, name, party, role_title)
    SELECT p_meeting, NULLIF(a ->> 'user_id', '')::UUID, _clean_text(a ->> 'name', 120, TRUE), a ->> 'party', _clean_text(a ->> 'role_title', 120)
    FROM jsonb_array_elements(p_attendees) a;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION finalize_meeting(p_meeting UUID) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_m meetings; v_k contracts;
BEGIN
  SELECT * INTO v_m FROM meetings WHERE id = p_meeting FOR UPDATE;
  PERFORM assert_access('meeting.manage', v_m.contract_id);
  IF v_m.status <> 'draft' THEN RAISE EXCEPTION 'MoM sudah final' USING ERRCODE = '22023'; END IF;
  UPDATE meetings SET status = 'final', finalized_at = NOW() WHERE id = p_meeting;
  SELECT * INTO v_k FROM contracts WHERE id = v_m.contract_id;
  PERFORM _notify_contractor(v_k.contractor_id, 'mom_ready', 'MoM siap ditandatangani: ' || v_m.mom_no, v_k.contract_no,
                             '/contracts/' || v_k.id || '/meetings/' || p_meeting, 'info', 4002,
                             jsonb_build_object('mom_no', v_m.mom_no, 'contract_no', v_k.contract_no), 'mom:' || p_meeting);
END $$;

CREATE OR REPLACE FUNCTION sign_entity(p_entity TEXT, p_entity_id UUID, p_method TEXT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_contract UUID; v_status TEXT; v_snapshot JSONB; v_uid UUID; v_party TEXT;
BEGIN
  IF p_entity = 'meeting' THEN
    SELECT contract_id, status, to_jsonb(m) - 'status' - 'signed_at' INTO v_contract, v_status, v_snapshot FROM meetings m WHERE id = p_entity_id;
  ELSIF p_entity = 'opr_review' THEN
    SELECT contract_id, status, to_jsonb(o) - 'status' - 'signed_at' - 'updated_at' INTO v_contract, v_status, v_snapshot FROM opr_reviews o WHERE id = p_entity_id;
  ELSIF p_entity = 'jra' THEN
    SELECT contract_id, CASE WHEN status IN ('submitted','under_review') THEN 'final' ELSE 'draft' END,
           jsonb_build_object('task', task_id, 'risks', (SELECT jsonb_agg(to_jsonb(r) ORDER BY r.created_at) FROM risk_items r WHERE r.contract_id = t.contract_id))
      INTO v_contract, v_status, v_snapshot FROM tasks t WHERE id = p_entity_id AND doc_type_code = 'JRAREG';
  ELSE
    RAISE EXCEPTION 'Entitas tidak valid' USING ERRCODE = '22023';
  END IF;
  IF v_contract IS NULL THEN RAISE EXCEPTION 'Dokumen tidak ditemukan' USING ERRCODE = '22023'; END IF;
  v_uid := assert_access('meeting.sign', v_contract);
  IF v_status <> 'final' THEN RAISE EXCEPTION 'Dokumen harus final sebelum ditandatangani' USING ERRCODE = '22023'; END IF;
  IF p_method NOT IN ('typed_name','drawn') THEN RAISE EXCEPTION 'Metode tanda tangan tidak valid' USING ERRCODE = '22023'; END IF;
  v_party := CASE WHEN auth_is_wfrd() THEN 'wfrd' ELSE 'contractor' END;
  INSERT INTO signatures (entity, entity_id, signer_id, party, method, sig_hash)
  VALUES (p_entity, p_entity_id, v_uid, v_party, p_method,
          encode(digest(v_snapshot::TEXT || '|' || v_uid || '|' || (EXTRACT(EPOCH FROM NOW()) * 1000000)::BIGINT, 'sha256'), 'hex'))
  ON CONFLICT (entity, entity_id, signer_id) DO NOTHING;
  IF EXISTS (SELECT 1 FROM signatures WHERE entity = p_entity AND entity_id = p_entity_id AND party = 'wfrd')
     AND EXISTS (SELECT 1 FROM signatures WHERE entity = p_entity AND entity_id = p_entity_id AND party = 'contractor') THEN
    IF p_entity = 'meeting' THEN UPDATE meetings SET status = 'signed', signed_at = NOW() WHERE id = p_entity_id AND status = 'final';
    ELSIF p_entity = 'opr_review' THEN
      UPDATE opr_reviews SET status = 'signed', signed_at = NOW() WHERE id = p_entity_id AND status = 'final';
      PERFORM _notify_contractor((SELECT contractor_id FROM contracts WHERE id = v_contract), 'opr_complete', 'OPR selesai', NULL,
                                 '/contracts/' || v_contract, 'info', 4007, '{}'::jsonb, 'opr:' || p_entity_id);
    END IF;
  END IF;
END $$;

-- ═════════════ AUDIT, FINDING, INSPEKSI ═════════════
-- p_results = {"area_key": "pass"|"fail"|"na"}
CREATE OR REPLACE FUNCTION save_audit(p_contract UUID, p_id UUID, p_type TEXT, p_results JSONB, p_finalize BOOLEAN) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_access('audit.conduct', p_contract); v_id UUID := p_id; v_pass INT; v_fail INT;
BEGIN
  IF EXISTS (SELECT 1 FROM jsonb_each_text(p_results) e WHERE e.value NOT IN ('pass','fail','na')) THEN
    RAISE EXCEPTION 'Nilai area: pass/fail/na' USING ERRCODE = '22023'; END IF;
  SELECT count(*) FILTER (WHERE value = 'pass'), count(*) FILTER (WHERE value = 'fail') INTO v_pass, v_fail FROM jsonb_each_text(p_results);
  IF v_id IS NULL THEN
    INSERT INTO audits (contract_id, audit_type, results, conducted_by) VALUES (p_contract, p_type, p_results, v_uid) RETURNING id INTO v_id;
  ELSE
    UPDATE audits SET results = p_results WHERE id = v_id AND contract_id = p_contract AND status = 'draft';
    IF NOT FOUND THEN RAISE EXCEPTION 'Audit tidak ditemukan atau sudah final' USING ERRCODE = '22023'; END IF;
  END IF;
  IF p_finalize THEN
    UPDATE audits SET status = 'final', conducted_at = NOW(),
                      score = CASE WHEN v_pass + v_fail = 0 THEN 100 ELSE round(v_pass * 100.0 / (v_pass + v_fail), 2) END
    WHERE id = v_id;
  END IF;
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION record_inspection(p_contract UUID, p_inspected_at TIMESTAMPTZ, p_area TEXT, p_result JSONB, p_notes TEXT)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_access('inspection.conduct', p_contract); v_id UUID;
BEGIN
  INSERT INTO inspections (contract_id, inspected_at, inspector_id, area, result, notes)
  VALUES (p_contract, COALESCE(p_inspected_at, NOW()), v_uid, _clean_text(p_area, 200, TRUE), COALESCE(p_result, '{}'::jsonb), _clean_text(p_notes, 4000))
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION create_finding(p_contract UUID, p_audit UUID, p_inspection UUID, p_area TEXT, p_description TEXT, p_severity TEXT)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID; v_k contracts; v_no TEXT; v_due DATE; v_id UUID; v_task UUID;
BEGIN
  IF p_inspection IS NOT NULL THEN v_uid := assert_access('inspection.conduct', p_contract); ELSE v_uid := assert_access('audit.conduct', p_contract); END IF;
  IF p_severity NOT IN ('critical','major','minor') THEN RAISE EXCEPTION 'Severity tidak valid' USING ERRCODE = '22023'; END IF;
  SELECT * INTO v_k FROM contracts WHERE id = p_contract;
  IF v_k.status IN ('closed','terminated') THEN RAISE EXCEPTION 'Kontrak sudah ditutup' USING ERRCODE = '22023'; END IF;
  v_no := _next_record_no('FND', p_contract);
  v_due := _local_today(v_k.geozone) + CASE p_severity WHEN 'critical' THEN 3 WHEN 'major' THEN 7 ELSE 30 END;
  INSERT INTO audit_findings (finding_no, contract_id, audit_id, inspection_id, area, description, severity, due_date, created_by)
  VALUES (v_no, p_contract, p_audit, p_inspection, _clean_text(p_area, 200, TRUE), _clean_text(p_description, 4000, TRUE), p_severity, v_due, v_uid)
  RETURNING id INTO v_id;
  v_task := _create_task('contract', v_k.contractor_id, p_contract, NULL, 'FNDCLS', 'Penutupan ' || v_no || ' (' || p_severity || ')',
                         v_due, p_severity IN ('critical','major'), NULL, v_no, left(p_description, 4000), TRUE, NULL);
  UPDATE audit_findings SET fndcls_task_id = v_task WHERE id = v_id;
  IF p_severity = 'critical' THEN
    PERFORM _notify_permission_holders('incident.escalate', p_contract, 'critical_finding', 'Finding CRITICAL ' || v_no, p_description,
              '/contracts/' || p_contract, 'critical', 3003, jsonb_build_object('finding_no', v_no), 'fndcrit:' || v_id);
  END IF;
  PERFORM _bot_contract(p_contract, 'task_card', 'Finding ' || v_no || ' (' || p_severity || ') — due ' || v_due, 
                        CASE WHEN p_severity = 'critical' THEN 'urgent' ELSE 'important' END);
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION cancel_finding(p_finding UUID, p_reason TEXT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_f audit_findings; v_reason TEXT := _require_reason(p_reason);
BEGIN
  SELECT * INTO v_f FROM audit_findings WHERE id = p_finding FOR UPDATE;
  PERFORM assert_access('finding.verify', v_f.contract_id);
  IF v_f.status IN ('closed','cancelled') THEN RAISE EXCEPTION 'Finding sudah final' USING ERRCODE = '22023'; END IF;
  UPDATE audit_findings SET status = 'cancelled' WHERE id = p_finding;
  UPDATE tasks SET status = 'cancelled', status_reason = v_reason, updated_at = NOW()
  WHERE source_ref = v_f.finding_no AND contract_id = v_f.contract_id AND status = ANY(_open_statuses());
END $$;

-- ═════════════ OPR ═════════════
-- p_ratings = {compliance, responsiveness, reporting, subcon_mgmt, capability} (0–100)
CREATE OR REPLACE FUNCTION save_opr_review(p_contract UUID, p_ratings JSONB, p_recommendation TEXT, p_comments TEXT, p_finalize BOOLEAN)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_access('opr.conduct', p_contract); v_hse NUMERIC; v_wfrd NUMERIC; v_final NUMERIC; v_rec TEXT; v_id UUID;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM contracts WHERE id = p_contract AND status = 'final_evaluation') THEN
    RAISE EXCEPTION 'OPR hanya pada fase final evaluation' USING ERRCODE = '22023'; END IF;
  IF EXISTS (SELECT 1 FROM unnest(ARRAY['compliance','responsiveness','reporting','subcon_mgmt','capability']) k
             WHERE (p_ratings ->> k) IS NULL OR (p_ratings ->> k)::NUMERIC NOT BETWEEN 0 AND 100) THEN
    RAISE EXCEPTION 'Semua rating 0–100 wajib' USING ERRCODE = '22023'; END IF;
  SELECT round(avg(score), 2) INTO v_hse FROM kpi_snapshots WHERE contract_id = p_contract AND period_month >= (CURRENT_DATE - INTERVAL '12 months');
  v_hse := COALESCE(v_hse, 100);
  SELECT round(avg(v::NUMERIC), 2) INTO v_wfrd FROM jsonb_each_text(p_ratings) e(k, v);
  v_final := round(0.5 * v_hse + 0.5 * v_wfrd, 2);
  v_rec := COALESCE(p_recommendation, CASE WHEN v_final >= 85 THEN 'renew' WHEN v_final >= 70 THEN 'renew_conditional'
                                           WHEN v_final >= 55 THEN 'conditional' ELSE 'remove' END);
  INSERT INTO opr_reviews (contract_id, final_hse_score, ratings, wfrd_score, final_score, recommendation, comments, created_by)
  VALUES (p_contract, v_hse, p_ratings, v_wfrd, v_final, v_rec, _clean_text(p_comments, 4000), v_uid)
  ON CONFLICT (contract_id) DO UPDATE SET final_hse_score = EXCLUDED.final_hse_score, ratings = EXCLUDED.ratings,
    wfrd_score = EXCLUDED.wfrd_score, final_score = EXCLUDED.final_score, recommendation = EXCLUDED.recommendation,
    comments = EXCLUDED.comments, updated_at = NOW()
    WHERE opr_reviews.status = 'draft'
  RETURNING id INTO v_id;
  IF v_id IS NULL THEN RAISE EXCEPTION 'OPR sudah final' USING ERRCODE = '22023'; END IF;
  IF p_finalize THEN UPDATE opr_reviews SET status = 'final' WHERE id = v_id; END IF;
  RETURN v_id;
END $$;
