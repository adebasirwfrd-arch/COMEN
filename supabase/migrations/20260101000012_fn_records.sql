CREATE OR REPLACE FUNCTION _assert_record_contract(p_contract UUID, p_perm TEXT DEFAULT 'record.submit') RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_access(p_perm, p_contract); v_status contract_status;
BEGIN
  SELECT status INTO v_status FROM contracts WHERE id = p_contract;
  IF v_status NOT IN ('pre_mobilization','mobilization','active','demobilization') THEN
    RAISE EXCEPTION 'Record operasional tidak bisa diisi pada status kontrak %', v_status USING ERRCODE = '22023';
  END IF;
  PERFORM hit_rate_limit('record:' || v_uid, 120, INTERVAL '1 hour');
  RETURN v_uid;
END $$;

-- ═════════════ INSIDEN (eskalasi sinkron) ═════════════
CREATE OR REPLACE FUNCTION report_incident(p_contract UUID, p_occurred_at TIMESTAMPTZ, p_type TEXT, p_severity TEXT, p_title TEXT,
  p_description TEXT, p_lat NUMERIC, p_lng NUMERIC, p_location_text TEXT, p_evidence_ref TEXT,
  p_is_preventable_vehicle BOOLEAN DEFAULT FALSE, p_high_potential BOOLEAN DEFAULT FALSE) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_access('incident.report', p_contract); v_k contracts; v_c contractors; v_no TEXT; v_id UUID;
        v_sev TEXT := CASE WHEN p_type = 'fatality' THEN 'critical' ELSE p_severity END; v_task UUID; v_rca BOOLEAN;
BEGIN
  PERFORM hit_rate_limit('incident:' || v_uid, 20, INTERVAL '1 hour');
  SELECT * INTO v_k FROM contracts WHERE id = p_contract;
  IF v_k.status IN ('closed','terminated') THEN RAISE EXCEPTION 'Kontrak sudah ditutup' USING ERRCODE = '22023'; END IF;
  IF p_occurred_at IS NULL OR p_occurred_at > NOW() + INTERVAL '5 minutes' THEN RAISE EXCEPTION 'Waktu kejadian tidak valid' USING ERRCODE = '22023'; END IF;
  SELECT * INTO v_c FROM contractors WHERE id = v_k.contractor_id;
  v_no := _next_record_no('INC', p_contract);
  INSERT INTO incidents (incident_no, contract_id, occurred_at, type, severity, is_preventable_vehicle, high_potential, title, description,
                         lat, lng, location_text, evidence_ref, flash_due_at, flash_at, full_report_due_at, reported_by)
  VALUES (v_no, p_contract, p_occurred_at, p_type, v_sev, COALESCE(p_is_preventable_vehicle, FALSE), COALESCE(p_high_potential, FALSE),
          _clean_text(p_title, 200, TRUE), _clean_text(p_description, 8000, TRUE), p_lat, p_lng, _clean_text(p_location_text, 300),
          _clean_text(p_evidence_ref, 500),
          CASE WHEN v_sev IN ('high','critical') THEN p_occurred_at + INTERVAL '1 hour' END,
          CASE WHEN v_sev IN ('high','critical') THEN NOW() END,
          p_occurred_at + INTERVAL '24 hours', v_uid)
  RETURNING id INTO v_id;

  v_rca := v_sev <> 'low' OR p_high_potential OR p_type IN ('mtc','rwc','lti','fatality');
  IF v_rca THEN
    v_task := _create_task('contract', v_k.contractor_id, p_contract, NULL, 'INVRPT', 'RCA ' || v_no || ' — ' || left(p_title, 120),
                           (p_occurred_at AT TIME ZONE _tz(v_k.geozone))::DATE + 14, v_sev IN ('high','critical'), NULL, v_no, NULL, TRUE);
    UPDATE incidents SET rca_task_id = v_task WHERE id = v_id;
  END IF;

  IF v_sev IN ('high','critical') THEN
    PERFORM _bot_contract(p_contract, 'security', '🚨 INSIDEN ' || upper(v_sev) || ' ' || v_no || ' — ' || p_title, 'urgent');
    PERFORM _notify_permission_holders('incident.escalate', p_contract, 'incident_high', '🚨 Insiden ' || upper(v_sev) || ': ' || v_no,
              p_title, '/incidents/' || v_id, 'critical', 3001, jsonb_build_object('incident_no', v_no, 'title', p_title, 'severity', v_sev,
              'contract_no', v_k.contract_no), 'inc:' || v_id);
    PERFORM _notify_permission_holders('incident.manage', p_contract, 'incident_high', '🚨 Insiden ' || upper(v_sev) || ': ' || v_no,
              p_title, '/incidents/' || v_id, 'critical', 3001, jsonb_build_object('incident_no', v_no, 'title', p_title, 'severity', v_sev,
              'contract_no', v_k.contract_no), 'inc:' || v_id);
    PERFORM _notify(v_k.process_owner_id, 'incident_high', '🚨 Insiden ' || upper(v_sev) || ': ' || v_no, p_title, '/incidents/' || v_id,
                    'critical', 3001, jsonb_build_object('incident_no', v_no, 'title', p_title), 'inc:' || v_id || ':' || v_k.process_owner_id);
    PERFORM _email(3001, v_c.hse_manager_email, jsonb_build_object('incident_no', v_no, 'title', p_title, 'severity', v_sev), 'inc:' || v_id || ':hsem');
  ELSE
    PERFORM _bot_contract(p_contract, 'system', 'Insiden dilaporkan: ' || v_no || ' (' || v_sev || ')', 'normal');
  END IF;
  RETURN jsonb_build_object('id', v_id, 'incident_no', v_no, 'rca_task', v_task);
END $$;

CREATE OR REPLACE FUNCTION submit_incident_report(p_incident UUID, p_full_report JSONB) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_i incidents;
BEGIN
  SELECT * INTO v_i FROM incidents WHERE id = p_incident FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Insiden tidak ditemukan' USING ERRCODE = '22023'; END IF;
  IF auth_is_wfrd() THEN PERFORM assert_access('incident.manage', v_i.contract_id); ELSE PERFORM assert_access('record.submit', v_i.contract_id); END IF;
  IF v_i.status = 'closed' THEN RAISE EXCEPTION 'Insiden sudah ditutup' USING ERRCODE = '22023'; END IF;
  IF jsonb_typeof(p_full_report) <> 'object' OR length(p_full_report::TEXT) > 100000 THEN RAISE EXCEPTION 'Laporan tidak valid' USING ERRCODE = '22023'; END IF;
  UPDATE incidents SET full_report = p_full_report, full_report_at = COALESCE(full_report_at, NOW()), status = 'investigating', updated_at = NOW()
  WHERE id = p_incident;
END $$;

CREATE OR REPLACE FUNCTION manage_incident(p_incident UUID, p_type TEXT, p_severity TEXT, p_high_potential BOOLEAN, p_close BOOLEAN, p_reason TEXT)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_i incidents; v_uid UUID; v_reason TEXT := _require_reason(p_reason);
BEGIN
  SELECT * INTO v_i FROM incidents WHERE id = p_incident FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Insiden tidak ditemukan' USING ERRCODE = '22023'; END IF;
  v_uid := assert_access('incident.manage', v_i.contract_id);
  IF v_i.status = 'closed' THEN RAISE EXCEPTION 'Insiden sudah ditutup' USING ERRCODE = '22023'; END IF;
  IF p_close THEN
    IF v_i.full_report IS NULL THEN RAISE EXCEPTION 'Full report belum ada' USING ERRCODE = '22023'; END IF;
    IF v_i.rca_task_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM tasks t WHERE t.base_task_id = (SELECT base_task_id FROM tasks WHERE id = v_i.rca_task_id)
                                                     AND t.status IN ('approved','waived')) THEN
      RAISE EXCEPTION 'RCA (INVRPT) belum approved/waived' USING ERRCODE = '22023'; END IF;
  END IF;
  UPDATE incidents SET type = COALESCE(p_type, type),
                       severity = CASE WHEN COALESCE(p_type, type) = 'fatality' THEN 'critical' ELSE COALESCE(p_severity, severity) END,
                       high_potential = COALESCE(p_high_potential, high_potential),
                       status = CASE WHEN p_close THEN 'closed' ELSE status END,
                       closed_by = CASE WHEN p_close THEN v_uid END, closed_at = CASE WHEN p_close THEN NOW() END, updated_at = NOW()
  WHERE id = p_incident;
END $$;

-- ═════════════ RECORD HARIAN ═════════════
CREATE OR REPLACE FUNCTION submit_daily_briefing(p_contract UUID, p_briefing_at TIMESTAMPTZ, p_location TEXT, p_topics TEXT,
  p_attendee_ids UUID[], p_attendees_count INT, p_hazards TEXT, p_key_message TEXT, p_evidence_ref TEXT) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := _assert_record_contract(p_contract); v_id UUID;
BEGIN
  IF EXISTS (SELECT 1 FROM unnest(COALESCE(p_attendee_ids, '{}')) a WHERE NOT EXISTS (SELECT 1 FROM manning m WHERE m.id = a AND m.contract_id = p_contract)) THEN
    RAISE EXCEPTION 'Attendee harus dari manning kontrak ini' USING ERRCODE = '22023'; END IF;
  INSERT INTO daily_briefings (contract_id, briefing_at, location, topics, attendee_ids, attendees_count, hazards, key_message, evidence_ref, submitted_by)
  VALUES (p_contract, COALESCE(p_briefing_at, NOW()), _clean_text(p_location, 200, TRUE), _clean_text(p_topics, 2000, TRUE),
          COALESCE(p_attendee_ids, '{}'), GREATEST(COALESCE(p_attendees_count, cardinality(p_attendee_ids)), 0),
          _clean_text(p_hazards, 2000), _clean_text(p_key_message, 1000), _clean_text(p_evidence_ref, 500), v_uid)
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION submit_bbs(p_contract UUID, p_observed_at TIMESTAMPTZ, p_observer_name TEXT, p_result TEXT, p_category TEXT,
  p_description TEXT, p_corrective_action TEXT, p_evidence_ref TEXT) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := _assert_record_contract(p_contract); v_id UUID;
BEGIN
  INSERT INTO bbs_observations (contract_id, observed_at, observer_name, result, category, description, corrective_action, evidence_ref, submitted_by)
  VALUES (p_contract, COALESCE(p_observed_at, NOW()), _clean_text(p_observer_name, 120, TRUE), p_result, _clean_text(p_category, 80, TRUE),
          _clean_text(p_description, 2000, TRUE), _clean_text(p_corrective_action, 2000), _clean_text(p_evidence_ref, 500), v_uid)
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION submit_stop_work(p_contract UUID, p_occurred_at TIMESTAMPTZ, p_raised_by_name TEXT, p_reason TEXT, p_location TEXT,
  p_corrective_action TEXT, p_resumed_at TIMESTAMPTZ, p_verifier_name TEXT) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := _assert_record_contract(p_contract); v_id UUID; v_k contracts;
BEGIN
  SELECT * INTO v_k FROM contracts WHERE id = p_contract;
  INSERT INTO stop_work_events (contract_id, occurred_at, raised_by_name, reason, location, corrective_action, resumed_at, verifier_name, submitted_by)
  VALUES (p_contract, COALESCE(p_occurred_at, NOW()), _clean_text(p_raised_by_name, 120, TRUE), _clean_text(p_reason, 2000, TRUE),
          _clean_text(p_location, 200), _clean_text(p_corrective_action, 2000), p_resumed_at, _clean_text(p_verifier_name, 120), v_uid)
  RETURNING id INTO v_id;
  PERFORM _notify(v_k.process_owner_id, 'stop_work', '✋ Stop-Work: ' || v_k.contract_no, p_reason, '/contracts/' || p_contract, 'warning', 3004,
                  jsonb_build_object('contract_no', v_k.contract_no, 'reason', p_reason), 'sw:' || v_id);
  PERFORM _notify(v_k.hse_reviewer_id, 'stop_work', '✋ Stop-Work: ' || v_k.contract_no, p_reason, '/contracts/' || p_contract, 'warning', 3004,
                  jsonb_build_object('contract_no', v_k.contract_no, 'reason', p_reason), 'sw:' || v_id || ':rev');
  PERFORM _bot_contract(p_contract, 'system', '✋ Stop-Work dicatat — terima kasih atas budaya keselamatan', 'important');
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION upsert_manning(p_contract UUID, p_id UUID, p_data JSONB) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID; v_id UUID := p_id;
BEGIN
  IF auth_is_wfrd() THEN v_uid := assert_access('contract.edit', p_contract); ELSE v_uid := assert_access('record.submit', p_contract); END IF;
  IF (p_data ->> 'subcontractor_id') IS NOT NULL AND NOT EXISTS (SELECT 1 FROM subcontractors WHERE id = (p_data ->> 'subcontractor_id')::UUID AND contract_id = p_contract) THEN
    RAISE EXCEPTION 'Subcontractor bukan bagian kontrak ini' USING ERRCODE = '22023'; END IF;
  IF v_id IS NULL THEN
    INSERT INTO manning (contract_id, subcontractor_id, full_name, position, competencies, cert_expiry, on_site)
    VALUES (p_contract, NULLIF(p_data ->> 'subcontractor_id', '')::UUID, _clean_text(p_data ->> 'full_name', 120, TRUE),
            _clean_text(p_data ->> 'position', 120, TRUE), ARRAY(SELECT left(jsonb_array_elements_text(COALESCE(p_data -> 'competencies', '[]'::jsonb)), 80)),
            (p_data ->> 'cert_expiry')::DATE, COALESCE((p_data ->> 'on_site')::BOOLEAN, TRUE))
    RETURNING id INTO v_id;
  ELSE
    UPDATE manning SET subcontractor_id = NULLIF(p_data ->> 'subcontractor_id', '')::UUID, full_name = _clean_text(p_data ->> 'full_name', 120, TRUE),
                       position = _clean_text(p_data ->> 'position', 120, TRUE),
                       competencies = ARRAY(SELECT left(jsonb_array_elements_text(COALESCE(p_data -> 'competencies', '[]'::jsonb)), 80)),
                       cert_expiry = (p_data ->> 'cert_expiry')::DATE, on_site = COALESCE((p_data ->> 'on_site')::BOOLEAN, on_site), updated_at = NOW()
    WHERE id = v_id AND contract_id = p_contract;
    IF NOT FOUND THEN RAISE EXCEPTION 'Data manning tidak ditemukan' USING ERRCODE = '22023'; END IF;
  END IF;
  RETURN v_id;
END $$;

-- ═════════════ KPI (rolling 12 bulan, Part 11) ═════════════
CREATE OR REPLACE FUNCTION _lower_better(p_rate NUMERIC, p_target NUMERIC, p_count INT) RETURNS NUMERIC
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN p_rate IS NULL THEN CASE WHEN p_count = 0 THEN 100 ELSE 0 END
              WHEN p_rate <= p_target THEN 100
              WHEN p_rate >= 2 * p_target THEN 0
              ELSE round(100 * (2 * p_target - p_rate) / p_target, 2) END
$$;

CREATE OR REPLACE FUNCTION _compute_kpi(p_contract UUID, p_month DATE, OUT metrics JSONB, OUT score NUMERIC, OUT color TEXT)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_end DATE := (date_trunc('month', p_month) + INTERVAL '1 month')::DATE;      -- eksklusif
  v_start DATE := (v_end - INTERVAL '12 months')::DATE;
  v_n NUMERIC := _setting_int('kpi_normalizer', 200000);
  v_tg JSONB := COALESCE(setting('kpi_targets'), '{}'::jsonb); v_w JSONB := COALESCE(setting('kpi_weights'), '{}'::jsonb);
  v_mh NUMERIC; v_km NUMERIC; v_rec INT; v_lti INT; v_pvi INT; v_hipo INT; v_fat INT;
  v_trir NUMERIC; v_ltir NUMERIC; v_pvir NUMERIC; s JSONB; v_bbs INT; v_bbs_target INT := _setting_int('bbs_weekly_target', 30);
  v_f_tot INT; v_f_ok INT; v_m_tot INT; v_m_ok INT; v_t_tot INT; v_t_ok INT; v_mr_tot INT; v_mr_ok INT; v_sw INT; v_audit NUMERIC;
BEGIN
  SELECT COALESCE(sum((form_data ->> 'man_hours')::NUMERIC), 0), COALESCE(sum((form_data ->> 'km_driven')::NUMERIC), 0) INTO v_mh, v_km
  FROM tasks WHERE contract_id = p_contract AND doc_type_code = 'MONRPT' AND status IN ('submitted','under_review','approved')
    AND to_date(form_data ->> 'period', 'YYYY-MM') >= v_start AND to_date(form_data ->> 'period', 'YYYY-MM') < v_end;
  SELECT count(*) FILTER (WHERE type IN ('mtc','rwc','lti','fatality')), count(*) FILTER (WHERE type IN ('lti','fatality')),
         count(*) FILTER (WHERE type = 'vehicle' AND is_preventable_vehicle), count(*) FILTER (WHERE high_potential),
         count(*) FILTER (WHERE type = 'fatality')
    INTO v_rec, v_lti, v_pvi, v_hipo, v_fat
  FROM incidents WHERE contract_id = p_contract AND occurred_at >= v_start AND occurred_at < v_end;
  v_trir := CASE WHEN v_mh > 0 THEN round(v_rec * v_n / v_mh, 3) END;
  v_ltir := CASE WHEN v_mh > 0 THEN round(v_lti * v_n / v_mh, 3) END;
  v_pvir := CASE WHEN v_km > 0 THEN round(v_pvi * 1000000 / v_km, 3) END;

  SELECT count(*) INTO v_bbs FROM bbs_observations WHERE contract_id = p_contract AND observed_at >= v_end - 28 AND observed_at < v_end;
  SELECT count(*), count(*) FILTER (WHERE status = 'closed' AND verified_at::DATE <= due_date) INTO v_f_tot, v_f_ok
  FROM audit_findings WHERE contract_id = p_contract AND due_date >= v_start AND due_date < v_end AND status <> 'cancelled';
  SELECT count(*), count(*) FILTER (WHERE cert_expiry >= v_end) INTO v_m_tot, v_m_ok FROM manning WHERE contract_id = p_contract AND on_site;
  SELECT count(*) INTO v_sw FROM stop_work_events WHERE contract_id = p_contract AND occurred_at >= v_end - 90 AND occurred_at < v_end;
  SELECT count(*), count(*) FILTER (WHERE upload_confirmed_at IS NOT NULL AND upload_confirmed_at::DATE <= due_date) INTO v_t_tot, v_t_ok
  FROM tasks WHERE contract_id = p_contract AND revision = 0 AND due_date >= v_start AND due_date < v_end AND status NOT IN ('waived','cancelled')
    AND doc_type_code <> 'MONRPT';
  SELECT count(*), count(*) FILTER (WHERE upload_confirmed_at IS NOT NULL AND upload_confirmed_at::DATE <= due_date) INTO v_mr_tot, v_mr_ok
  FROM tasks WHERE contract_id = p_contract AND doc_type_code = 'MONRPT' AND revision = 0 AND due_date >= v_start AND due_date < v_end
    AND status NOT IN ('waived','cancelled');
  SELECT avg(a.score) INTO v_audit FROM audits a WHERE a.contract_id = p_contract AND a.status = 'final' AND a.conducted_at >= v_start AND a.conducted_at < v_end;

  s := jsonb_build_object(
    'trir',           _lower_better(v_trir, COALESCE((v_tg ->> 'trir')::NUMERIC, 1.0), v_rec),
    'ltir',           _lower_better(v_ltir, COALESCE((v_tg ->> 'ltir')::NUMERIC, 0.5), v_lti),
    'pvir',           _lower_better(v_pvir, COALESCE((v_tg ->> 'pvir')::NUMERIC, 1.0), v_pvi),
    'hipo',           GREATEST(0, 100 - 50 * v_hipo),
    'bbs',            LEAST(100, round(v_bbs * 100.0 / GREATEST(4 * v_bbs_target, 1), 2)),
    'finding_ontime', CASE WHEN v_f_tot = 0 THEN 100 ELSE round(v_f_ok * 100.0 / v_f_tot, 2) END,
    'training',       CASE WHEN v_m_tot = 0 THEN 100 ELSE round(v_m_ok * 100.0 / v_m_tot, 2) END,
    'stopwork',       LEAST(100, v_sw * 50),
    'task_ontime',    CASE WHEN v_t_tot = 0 THEN 100 ELSE round(v_t_ok * 100.0 / v_t_tot, 2) END,
    'monrpt_ontime',  CASE WHEN v_mr_tot = 0 THEN 100 ELSE round(v_mr_ok * 100.0 / v_mr_tot, 2) END,
    'audit',          COALESCE(round(v_audit, 2), 100));
  SELECT round(sum((s ->> k)::NUMERIC * COALESCE((v_w ->> k)::NUMERIC, 0)) / 100, 2) INTO score FROM jsonb_object_keys(s) k;
  color := CASE WHEN v_fat > 0 OR score < 70 THEN 'red' WHEN score < 85 THEN 'yellow' ELSE 'green' END;
  metrics := jsonb_build_object('man_hours', v_mh, 'km', v_km, 'recordables', v_rec, 'lti', v_lti, 'pvi', v_pvi, 'hipo', v_hipo,
               'fatality', v_fat, 'trir', v_trir, 'ltir', v_ltir, 'pvir', v_pvir, 'bbs_4w', v_bbs, 'stopwork_90d', v_sw,
               'components', s, 'window', jsonb_build_object('from', v_start, 'to', v_end));
END $$;
