-- ═════════════ HELPER ═════════════
CREATE OR REPLACE FUNCTION _call_edge(p_function TEXT, p_body JSONB DEFAULT '{}'::jsonb) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
BEGIN
  RETURN net.http_post(
    url := _secret('edge_base_url') || '/' || p_function,
    body := p_body,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-secret', _secret('cron_secret')),
    timeout_milliseconds := 15000);
END $$;

-- Health kontrak = kondisi terburuk dari KPI, task overdue, dokumen gate expired, finding lewat due
CREATE OR REPLACE FUNCTION _refresh_health(p_contract UUID) RETURNS TEXT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_k contracts; v_today DATE; v_kpi TEXT; v_red BOOLEAN; v_warn BOOLEAN; v_flag TEXT;
BEGIN
  SELECT * INTO v_k FROM contracts WHERE id = p_contract FOR UPDATE;
  IF v_k.status NOT IN ('mobilization','active','demobilization','suspended') THEN RETURN v_k.health_flag; END IF;
  v_today := _local_today(v_k.geozone);
  SELECT color INTO v_kpi FROM kpi_snapshots WHERE contract_id = p_contract ORDER BY period_month DESC LIMIT 1;
  v_red := COALESCE(v_kpi = 'red', FALSE)
    OR EXISTS (SELECT 1 FROM tasks t WHERE t.contract_id = p_contract AND t.is_mandatory AND t.renewal_of IS NULL
               AND t.status IN ('open','awaiting_email','file_issue','rejected') AND t.due_date <= v_today - 7)
    OR EXISTS (SELECT 1 FROM tasks t JOIN contract_requirements r ON r.contract_id = t.contract_id AND r.doc_type_code = t.doc_type_code
               WHERE t.contract_id = p_contract AND t.status = 'expired' AND (r.is_mob_gate OR t.is_blocker) AND t.expiry_date <= v_today - 7);
  v_warn := COALESCE(v_kpi = 'yellow', FALSE)
    OR EXISTS (SELECT 1 FROM tasks t WHERE t.contract_id = p_contract AND t.is_mandatory
               AND t.status IN ('open','awaiting_email','file_issue','rejected') AND t.due_date < v_today)
    OR EXISTS (SELECT 1 FROM tasks t WHERE t.contract_id = p_contract AND t.status = 'expired')
    OR EXISTS (SELECT 1 FROM audit_findings f WHERE f.contract_id = p_contract AND f.status IN ('open','closure_submitted') AND f.due_date < v_today);
  v_flag := CASE WHEN v_red THEN 'red' WHEN v_warn THEN 'warning' ELSE 'normal' END;
  IF v_flag <> v_k.health_flag THEN
    UPDATE contracts SET health_flag = v_flag WHERE id = p_contract;
    IF v_flag = 'red' THEN
      PERFORM _notify(v_k.process_owner_id, 'contract_health', v_k.contract_no || ' berstatus RED', 'Periksa task overdue, dokumen expired, dan KPI',
                      '/contracts/' || p_contract, 'critical', NULL, '{}'::jsonb, 'health:' || p_contract || ':' || v_today);
      PERFORM _bot_contract(p_contract, 'system', '🔴 Health kontrak RED — tindak lanjuti task overdue & dokumen expired', 'important');
    END IF;
  END IF;
  RETURN v_flag;
END $$;

CREATE OR REPLACE FUNCTION _next_recurrence(p_freq TEXT, p_dow SMALLINT[], p_time TIME, p_tz TEXT, p_after TIMESTAMPTZ)
RETURNS TIMESTAMPTZ LANGUAGE plpgsql STABLE SET search_path = public, extensions AS $$
DECLARE v_local DATE := (p_after AT TIME ZONE p_tz)::DATE; v_day INT := EXTRACT(DAY FROM (p_after AT TIME ZONE p_tz))::INT; v_cand DATE; i INT;
BEGIN
  IF p_freq = 'daily' THEN v_cand := v_local + 1;
  ELSIF p_freq = 'weekly' THEN
    FOR i IN 1..7 LOOP
      IF EXTRACT(ISODOW FROM v_local + i)::SMALLINT = ANY(p_dow) THEN v_cand := v_local + i; EXIT; END IF;
    END LOOP;
  ELSIF p_freq = 'monthly' THEN
    v_cand := LEAST((date_trunc('month', v_local) + INTERVAL '1 month')::DATE + (v_day - 1),
                    (date_trunc('month', v_local) + INTERVAL '2 months')::DATE - 1);
  ELSE RETURN NULL; END IF;
  RETURN (v_cand + p_time) AT TIME ZONE p_tz;
END $$;

-- ═════════════ TASK ═════════════
-- Ladder Part 12.2 (harian 08:00 WIB). Reminder task document/evidence tanpa link OneDrive DITAHAN (R21).
CREATE OR REPLACE FUNCTION svc_task_reminders() RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE r RECORD; v_u UUID; v_digest INT := 0; v_overdue INT := 0;
BEGIN
  -- Digest H-14 (lead > 21 hari) · H-7 · H-3 · H-1, maks 1 email/hari/user
  FOR r IN
    WITH due AS (
      SELECT t.id, t.task_id, t.title, t.due_date, t.contractor_id, t.assigned_to, t.created_at,
             t.due_date - _local_today(k.geozone) AS d
      FROM tasks t LEFT JOIN contracts k ON k.id = t.contract_id
      WHERE t.status IN ('open','file_issue') AND t.due_date IS NOT NULL
        AND (k.id IS NULL OR k.status NOT IN ('suspended','closed','terminated'))
        AND (t.kind NOT IN ('document','evidence') OR resolve_upload_link(t.id) IS NOT NULL)
        AND (t.assigned_to IS NULL OR EXISTS (SELECT 1 FROM profiles p WHERE p.id = t.assigned_to AND p.contractor_id IS NOT NULL)))
    SELECT u.uid, jsonb_agg(jsonb_build_object('task_id', due.task_id, 'title', due.title, 'due', due.due_date, 'days', due.d)
                            ORDER BY due.d) AS items
    FROM due CROSS JOIN LATERAL (SELECT x AS uid FROM _contractor_users(due.contractor_id) x
                                 WHERE due.assigned_to IS NULL OR x = due.assigned_to) u
    WHERE due.d IN (7, 3, 1) OR (due.d = 14 AND due.due_date - due.created_at::DATE > 21)
    GROUP BY u.uid
  LOOP
    PERFORM _notify(r.uid, 'task_digest', 'Ringkasan task mendekati due (' || jsonb_array_length(r.items) || ')', NULL, '/tasks', 'info',
                    2010, jsonb_build_object('items', r.items), 'digest:' || r.uid || ':' || CURRENT_DATE);
    v_digest := v_digest + 1;
  END LOOP;

  -- awaiting_email ≥ 24 jam (R22), maks 1/hari/task
  FOR r IN SELECT t.* FROM tasks t LEFT JOIN contracts k ON k.id = t.contract_id
           WHERE t.status = 'awaiting_email' AND t.upload_confirmed_at < NOW() - INTERVAL '24 hours'
             AND (k.id IS NULL OR k.status NOT IN ('suspended','closed','terminated')) LOOP
    PERFORM _notify_contractor(r.contractor_id, 'email_pending', 'Email konfirmasi belum diterima: ' || r.task_id,
              'Kirim email konfirmasi berisi Task ID & KODE', '/tasks/' || r.id, 'warning', 2013,
              jsonb_build_object('task_id', r.task_id, 'title', r.title), 'awaitmail:' || r.id || ':' || CURRENT_DATE);
  END LOOP;

  -- Overdue ladder H+1 / H+3 / H+7 / H+14 / H+30 (dedupe per anak tangga → tidak pernah ganda, tidak terlewat bila job sempat mati)
  FOR r IN
    SELECT t.*, k.contract_no, k.process_owner_id, k.geozone, c.legal_name, c.hse_manager_email,
           _local_today(k.geozone) - t.due_date AS late
    FROM tasks t JOIN contractors c ON c.id = t.contractor_id LEFT JOIN contracts k ON k.id = t.contract_id
    WHERE t.status IN ('open','file_issue','awaiting_email') AND t.due_date IS NOT NULL
      AND t.due_date < _local_today(k.geozone)
      AND (k.id IS NULL OR k.status NOT IN ('suspended','closed','terminated'))
      AND (t.kind NOT IN ('document','evidence') OR t.status = 'awaiting_email' OR resolve_upload_link(t.id) IS NOT NULL)
  LOOP
    v_overdue := v_overdue + 1;
    IF EXISTS (SELECT 1 FROM profiles p WHERE p.id = r.assigned_to AND p.contractor_id IS NULL) THEN   -- action WFRD
      PERFORM _notify(r.assigned_to, 'action_overdue', 'Action overdue: ' || r.task_id, r.title, '/tasks/' || r.id, 'warning',
                      2003, jsonb_build_object('task_id', r.task_id, 'title', r.title, 'due', r.due_date), 'od1:' || r.id);
      CONTINUE;
    END IF;
    PERFORM _notify_contractor(r.contractor_id, 'task_overdue', 'Overdue: ' || r.task_id, r.title, '/tasks/' || r.id, 'warning', 2003,
              jsonb_build_object('task_id', r.task_id, 'title', r.title, 'due', r.due_date, 'company', r.legal_name), 'od1:' || r.id);
    IF r.contract_id IS NOT NULL THEN
      PERFORM _notify(r.process_owner_id, 'task_overdue', 'Overdue: ' || r.task_id || ' (' || r.legal_name || ')', r.title, '/tasks/' || r.id,
                      'warning', 2003, jsonb_build_object('task_id', r.task_id, 'title', r.title, 'due', r.due_date, 'company', r.legal_name), 'od1po:' || r.id);
      IF NOT EXISTS (SELECT 1 FROM task_events WHERE task_id = r.id AND event = 'auto_reminder' AND payload ->> 'step' = 'od1') THEN
        PERFORM _bot_contract(r.contract_id, 'reminder', '⏰ Overdue: ' || r.task_id || ' — ' || r.title, 'important', ARRAY[r.task_id]);
        INSERT INTO task_events (task_id, event, payload) VALUES (r.id, 'auto_reminder', jsonb_build_object('step', 'od1'));
      END IF;
    END IF;
    IF r.late >= 3 THEN
      PERFORM _email(2003, r.hse_manager_email, jsonb_build_object('task_id', r.task_id, 'title', r.title, 'due', r.due_date,
                     'company', r.legal_name, 'escalation', 'hse_manager'), 'od3:' || r.id);
    END IF;
    IF r.late >= 7 THEN
      FOR v_u IN SELECT p.id FROM profiles p WHERE p.status = 'active' AND _user_has_role(p.id, 'hse_director')
                   AND (r.contract_id IS NULL OR _uid_has_contract_permission(p.id, 'task.view', r.contract_id)) LOOP
        PERFORM _notify(v_u, 'task_overdue_escalation', 'Eskalasi overdue H+7: ' || r.task_id, r.legal_name || ' — ' || r.title,
                        '/tasks/' || r.id, 'critical', 2003, jsonb_build_object('task_id', r.task_id, 'title', r.title, 'due', r.due_date,
                        'company', r.legal_name, 'escalation', 'director'), 'od7:' || r.id || ':' || v_u);
      END LOOP;
      IF r.contract_id IS NOT NULL THEN PERFORM _refresh_health(r.contract_id); END IF;
    END IF;
    IF r.late >= 14 AND r.contract_id IS NOT NULL THEN
      PERFORM _notify(r.process_owner_id, 'hold_recommendation', 'Rekomendasi hold ' || r.contract_no, r.task_id || ' overdue ≥ 14 hari',
                      '/contracts/' || r.contract_id, 'critical', NULL, '{}'::jsonb, 'od14:' || r.id);
    END IF;
    IF r.late >= 30 THEN
      PERFORM _notify_permission_holders('vendor.asl.decide', NULL, 'asl_review_recommendation', 'Rekomendasi review ASL: ' || r.legal_name,
                r.task_id || ' overdue ≥ 30 hari', '/vendors/' || r.contractor_id, 'warning', NULL, '{}'::jsonb, 'od30:' || r.id);
    END IF;
  END LOOP;
  RETURN jsonb_build_object('digests', v_digest, 'overdue', v_overdue);
END $$;

-- Review SLA (per jam): lewat SLA → reviewer #2011; SLA + 3 hari kerja → hse_admin & hse_director
CREATE OR REPLACE FUNCTION svc_review_sla() RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE r RECORD; v_u UUID; v_n INT := 0; v_p JSONB;
BEGIN
  FOR r IN SELECT t.*, k.geozone FROM tasks t LEFT JOIN contracts k ON k.id = t.contract_id
           WHERE t.status IN ('submitted','under_review') AND t.review_due_at < NOW() LOOP
    v_n := v_n + 1;
    v_p := jsonb_build_object('task_id', r.task_id, 'title', r.title, 'review_due_at', r.review_due_at);
    IF r.reviewer_id IS NOT NULL THEN
      PERFORM _notify(r.reviewer_id, 'review_sla', 'SLA review lewat: ' || r.task_id, r.title, '/tasks/' || r.id, 'warning', 2011, v_p,
                      'sla:' || r.id || ':' || (r.review_due_at AT TIME ZONE _tz(r.geozone))::DATE);
    END IF;
    IF r.reviewer_id IS NULL OR add_business_days((r.review_due_at AT TIME ZONE _tz(r.geozone))::DATE, 3, r.geozone) <= _local_today(r.geozone) THEN
      FOR v_u IN SELECT p.id FROM profiles p WHERE p.status = 'active' AND p.contractor_id IS NULL
                   AND (_user_has_role(p.id, 'hse_admin') OR _user_has_role(p.id, 'hse_director'))
                   AND (r.contract_id IS NULL OR _uid_has_contract_permission(p.id, 'task.view', r.contract_id)) LOOP
        PERFORM _notify(v_u, 'review_sla_escalation', 'Eskalasi SLA review: ' || r.task_id, r.title, '/tasks/' || r.id, 'critical', 2011,
                        v_p || jsonb_build_object('escalation', TRUE), 'slaesc:' || r.id || ':' || v_u);
      END LOOP;
    END IF;
  END LOOP;
  RETURN v_n;
END $$;

-- Task tanpa link OneDrive (R21): alert PO per kontrak + pemegang upload_link.manage global (#2012)
CREATE OR REPLACE FUNCTION svc_link_coverage() RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE r RECORD; v_total INT := 0;
BEGIN
  FOR r IN SELECT t.contract_id, count(*) AS n FROM tasks t
           WHERE t.status IN ('open','file_issue') AND t.kind IN ('document','evidence') AND resolve_upload_link(t.id) IS NULL
           GROUP BY t.contract_id LOOP
    v_total := v_total + r.n;
    IF r.contract_id IS NOT NULL THEN
      PERFORM _notify((SELECT process_owner_id FROM contracts WHERE id = r.contract_id), 'link_missing',
                      r.n || ' task belum punya link OneDrive', NULL, '/contracts/' || r.contract_id || '/onedrive', 'warning',
                      NULL, '{}'::jsonb, 'linkgap:' || r.contract_id || ':' || CURRENT_DATE);
    END IF;
  END LOOP;
  -- Ringkasan global hanya untuk pemegang upload_link.manage yang punya Admin Console (PO sudah menerima per kontrak di atas)
  IF v_total > 0 THEN
    FOR r IN SELECT u.uid FROM _users_with_permission('upload_link.manage', NULL) AS u(uid)
             WHERE EXISTS (SELECT 1 FROM permissions pm WHERE pm.key LIKE 'admin.%' AND EXISTS (SELECT 1 FROM _perm_grants(u.uid, pm.key))) LOOP
      PERFORM _notify(r.uid, 'link_missing', v_total || ' task belum punya link OneDrive', NULL, '/admin/onedrive-links', 'warning',
                      2012, jsonb_build_object('count', v_total), 'linkgap:all:' || CURRENT_DATE || ':' || r.uid);
    END LOOP;
  END IF;
  RETURN v_total;
END $$;

-- Expiry dokumen: H-30 renewal + #2009 · H-14/H-7 in-app · lewat → expired + WARNING · H+7 → RED + rekomendasi hold
CREATE OR REPLACE FUNCTION svc_doc_expiry() RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE r RECORD; v_today DATE; v_d INT; v_new UUID; v_renew INT := 0; v_exp INT := 0; v_p JSONB;
BEGIN
  FOR r IN SELECT t.*, k.geozone, k.status AS k_status, k.end_date AS k_end, k.process_owner_id, c.status AS vendor_status
           FROM tasks t JOIN contractors c ON c.id = t.contractor_id LEFT JOIN contracts k ON k.id = t.contract_id
           WHERE t.status IN ('approved','expired') AND t.expiry_date IS NOT NULL
             AND (k.id IS NULL OR k.status NOT IN ('closed','terminated'))
             AND (k.id IS NOT NULL OR c.status IN ('under_review','asl_approved','asl_conditional')) LOOP
    v_today := _local_today(r.geozone);
    v_d := r.expiry_date - v_today;
    v_p := jsonb_build_object('task_id', r.task_id, 'title', r.title, 'expiry_date', r.expiry_date, 'days', v_d);

    IF v_d <= 30 AND (r.contract_id IS NULL OR r.k_end > r.expiry_date)
       AND NOT EXISTS (SELECT 1 FROM tasks x WHERE x.renewal_of = r.id AND x.status NOT IN ('cancelled','waived')) THEN
      v_new := _create_task(r.scope, r.contractor_id, r.contract_id, r.subcontractor_id, r.doc_type_code,
                            left(r.title, 180) || ' (Perpanjangan)', GREATEST(r.expiry_date, v_today + 3), r.is_blocker, r.assigned_to,
                            'RENEW:' || r.task_id, 'Perpanjangan ' || r.task_id || ' — berlaku s/d ' || r.expiry_date, r.is_mandatory, r.phase, r.id);
      INSERT INTO task_events (task_id, event, payload) VALUES (r.id, 'renewal_created', jsonb_build_object('renewal', v_new));
      PERFORM _notify_contractor(r.contractor_id, 'doc_expiry', 'Dokumen akan kedaluwarsa: ' || r.task_id, 'Task perpanjangan dibuat',
                '/tasks/' || v_new, 'warning', 2009, v_p || jsonb_build_object('renewal_task_id', (SELECT task_id FROM tasks WHERE id = v_new)),
                'renew:' || r.id);
      IF r.contract_id IS NOT NULL THEN
        PERFORM _bot_contract(r.contract_id, 'task_card', '♻️ Perpanjangan ' || r.task_id || ' (exp ' || r.expiry_date || ')', 'normal',
                              ARRAY[r.task_id, (SELECT task_id FROM tasks WHERE id = v_new)]);
      END IF;
      v_renew := v_renew + 1;
    END IF;

    IF r.status = 'approved' AND v_d IN (14, 7) THEN
      PERFORM _notify_contractor(r.contractor_id, 'doc_expiry', r.task_id || ' kedaluwarsa dalam ' || v_d || ' hari', r.title,
                                 '/tasks/' || r.id, 'warning', NULL, v_p, 'exp' || v_d || ':' || r.id);
    END IF;

    IF r.status = 'approved' AND v_d < 0 THEN
      UPDATE tasks SET status = 'expired', status_reason = 'Kedaluwarsa ' || r.expiry_date WHERE id = r.id;
      INSERT INTO task_events (task_id, event, payload) VALUES (r.id, 'expired', jsonb_build_object('expiry_date', r.expiry_date));
      PERFORM _notify_contractor(r.contractor_id, 'doc_expired', 'Dokumen kedaluwarsa: ' || r.task_id, r.title, '/tasks/' || r.id,
                                 'critical', 2009, v_p, 'expired:' || r.id);
      IF r.contract_id IS NOT NULL THEN
        PERFORM _notify(r.process_owner_id, 'doc_expired', 'Dokumen kontrak kedaluwarsa: ' || r.task_id, r.title, '/tasks/' || r.id,
                        'warning', NULL, '{}'::jsonb, 'expiredpo:' || r.id);
        PERFORM _refresh_health(r.contract_id);
      ELSE
        PERFORM _notify_permission_holders('vendor.asl.decide', NULL, 'doc_expired', 'Dokumen vendor kedaluwarsa: ' || r.task_id, r.title,
                                           '/vendors/' || r.contractor_id, 'warning', NULL, '{}'::jsonb, 'expiredv:' || r.id);
      END IF;
      v_exp := v_exp + 1;
    END IF;

    IF v_d <= -7 AND r.contract_id IS NOT NULL AND r.k_status IN ('mobilization','active') THEN
      PERFORM _notify(r.process_owner_id, 'hold_recommendation', 'Rekomendasi hold: ' || r.task_id || ' expired ≥ 7 hari', r.title,
                      '/contracts/' || r.contract_id, 'critical', NULL, '{}'::jsonb, 'exphold:' || r.id);
      PERFORM _refresh_health(r.contract_id);
    END IF;
  END LOOP;
  RETURN jsonb_build_object('renewals', v_renew, 'expired', v_exp);
END $$;

-- MONRPT bulan lalu untuk kontrak active/demobilization (dijalankan harian; idempoten; due tanggal 5)
CREATE OR REPLACE FUNCTION svc_monthly_reports() RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE r RECORD; v_today DATE; v_period TEXT; v_due DATE; v_new UUID; v_n INT := 0;
BEGIN
  FOR r IN SELECT * FROM contracts WHERE status IN ('active','demobilization') AND golive_approved_at IS NOT NULL LOOP
    v_today := _local_today(r.geozone);
    IF (r.golive_approved_at AT TIME ZONE _tz(r.geozone))::DATE >= date_trunc('month', v_today)::DATE THEN CONTINUE; END IF;
    v_period := to_char(date_trunc('month', v_today) - INTERVAL '1 month', 'YYYY-MM');
    IF EXISTS (SELECT 1 FROM tasks WHERE contract_id = r.id AND doc_type_code = 'MONRPT' AND source_ref = 'MONRPT:' || v_period
               AND revision = 0 AND status <> 'cancelled') THEN CONTINUE; END IF;
    v_due := GREATEST(date_trunc('month', v_today)::DATE + 4, v_today + 2);
    v_new := _create_task('contract', r.contractor_id, r.id, NULL, 'MONRPT', 'Laporan Bulanan HSE ' || v_period, v_due, FALSE, NULL,
                          'MONRPT:' || v_period, NULL, TRUE, 'execution');
    UPDATE tasks SET form_data = jsonb_build_object('period', v_period) WHERE id = v_new;
    PERFORM _notify_contractor(r.contractor_id, 'monthly_report', 'Laporan bulanan ' || v_period || ' — due ' || v_due, r.contract_no,
              '/tasks/' || v_new, 'info', 5002, jsonb_build_object('period', v_period, 'due', v_due, 'contract_no', r.contract_no),
              'monrpt:' || r.id || ':' || v_period);
    PERFORM _bot_contract(r.id, 'task_card', '📊 Laporan bulanan ' || v_period || ' dibuat — due ' || v_due, 'normal',
                          ARRAY[(SELECT task_id FROM tasks WHERE id = v_new)]);
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END $$;

-- ═════════════ KPI & KONTRAK & VENDOR ═════════════
CREATE OR REPLACE FUNCTION svc_kpi_recalc() RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE r RECORD; v_k RECORD; v_prev TEXT; v_today DATE; v_month DATE; m DATE; v_n INT := 0; v_po RECORD;
BEGIN
  FOR r IN SELECT * FROM contracts WHERE status IN ('mobilization','active','demobilization','final_evaluation','suspended') LOOP
    v_today := _local_today(r.geozone);
    v_month := date_trunc('month', v_today)::DATE;
    FOREACH m IN ARRAY CASE WHEN EXTRACT(DAY FROM v_today) <= 5 THEN ARRAY[(v_month - INTERVAL '1 month')::DATE, v_month] ELSE ARRAY[v_month] END LOOP
      SELECT * INTO v_k FROM _compute_kpi(r.id, m);
      SELECT color INTO v_prev FROM kpi_snapshots WHERE contract_id = r.id AND period_month = m;
      INSERT INTO kpi_snapshots (contract_id, period_month, metrics, score, color)
      VALUES (r.id, m, v_k.metrics, COALESCE(v_k.score, 0), v_k.color)
      ON CONFLICT (contract_id, period_month) DO UPDATE SET metrics = EXCLUDED.metrics, score = EXCLUDED.score, color = EXCLUDED.color, computed_at = NOW();
      IF m = v_month AND v_k.color = 'red' AND v_prev IS DISTINCT FROM 'red' THEN
        PERFORM _notify(r.process_owner_id, 'kpi_red', 'KPI ' || r.contract_no || ' RED (' || COALESCE(v_k.score, 0) || ')', NULL,
                        '/contracts/' || r.id || '?tab=kpi', 'critical', NULL, '{}'::jsonb, 'kpired:' || r.id || ':' || m);
      END IF;
    END LOOP;
    IF r.status = 'active' AND (v_k.metrics -> 'components' ->> 'bbs')::NUMERIC < 100 THEN          -- R25
      PERFORM _notify(r.process_owner_id, 'bbs_below_target', 'BBS ' || r.contract_no || ' di bawah target', NULL,
                      '/contracts/' || r.id || '?tab=kpi', 'warning', NULL, '{}'::jsonb, 'bbs:' || r.id || ':' || to_char(v_today, 'IYYY-IW'));
    END IF;
    PERFORM _refresh_health(r.id);
    v_n := v_n + 1;
  END LOOP;

  -- Weekly KPI digest (#5001) tiap Senin per PO
  IF EXTRACT(ISODOW FROM _local_today()) = 1 THEN
    FOR v_po IN SELECT k.process_owner_id AS uid, jsonb_agg(jsonb_build_object('contract_no', k.contract_no, 'score', s.score, 'color', s.color,
                         'health', k.health_flag) ORDER BY s.score NULLS LAST) AS items
                FROM contracts k LEFT JOIN LATERAL (SELECT score, color FROM kpi_snapshots WHERE contract_id = k.id ORDER BY period_month DESC LIMIT 1) s ON TRUE
                WHERE k.status IN ('mobilization','active','demobilization') GROUP BY k.process_owner_id LOOP
      PERFORM _notify(v_po.uid, 'kpi_weekly', 'Ringkasan KPI mingguan', NULL, '/dashboard', 'info', 5001,
                      jsonb_build_object('items', v_po.items), 'kpiweek:' || v_po.uid || ':' || to_char(_local_today(), 'IYYY-IW'));
    END LOOP;
  END IF;
  RETURN v_n;
END $$;

CREATE OR REPLACE FUNCTION svc_asl_expiry() RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE r RECORD; v_d INT; v_n INT := 0; v_p JSONB;
BEGIN
  FOR r IN SELECT * FROM contractors WHERE status IN ('asl_approved','asl_conditional') AND asl_expires_on IS NOT NULL LOOP
    v_d := r.asl_expires_on - _local_today();
    v_p := jsonb_build_object('company', r.legal_name, 'expires_on', r.asl_expires_on, 'days', v_d);
    IF v_d IN (60, 30, 7) THEN
      PERFORM _notify_contractor(r.id, 'asl_expiry', 'ASL berakhir dalam ' || v_d || ' hari', NULL, '/my-company', 'warning', 1006, v_p,
                                 'aslexp:' || r.id || ':' || v_d);
      PERFORM _notify_permission_holders('vendor.asl.decide', NULL, 'asl_expiry', 'ASL ' || r.legal_name || ' berakhir dalam ' || v_d || ' hari',
                                         NULL, '/vendors/' || r.id, 'warning', NULL, '{}'::jsonb, 'aslexp:' || r.id || ':' || v_d);
    ELSIF v_d < 0 THEN
      UPDATE contractors SET status = 'asl_expired', status_reason = 'ASL kedaluwarsa ' || r.asl_expires_on, updated_at = NOW() WHERE id = r.id;
      PERFORM _notify_contractor(r.id, 'asl_expired', 'ASL kedaluwarsa', 'Hubungi Procurement untuk evaluasi ulang', '/my-company', 'critical',
                                 1006, v_p, 'aslexpired:' || r.id || ':' || r.asl_expires_on);
      PERFORM _notify_permission_holders('vendor.asl.decide', NULL, 'asl_expired', 'ASL ' || r.legal_name || ' kedaluwarsa', NULL,
                                         '/vendors/' || r.id, 'warning', NULL, '{}'::jsonb, 'aslexpired:' || r.id || ':' || r.asl_expires_on);
      v_n := v_n + 1;
    END IF;
  END LOOP;
  RETURN v_n;
END $$;

CREATE OR REPLACE FUNCTION svc_contract_expiry() RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE r RECORD; v_d INT; v_n INT := 0; v_p JSONB;
BEGIN
  FOR r IN SELECT * FROM contracts WHERE status IN ('pre_mobilization','mobilization','active') LOOP
    v_d := r.end_date - _local_today(r.geozone);
    v_p := jsonb_build_object('contract_no', r.contract_no, 'end_date', r.end_date, 'days', v_d);
    IF v_d = 60 THEN
      PERFORM _notify(r.process_owner_id, 'contract_expiry', r.contract_no || ' berakhir dalam 60 hari', NULL, '/contracts/' || r.id,
                      'warning', 4005, v_p, 'ctrexp60:' || r.id);
      PERFORM _notify_contractor(r.contractor_id, 'contract_expiry', r.contract_no || ' berakhir dalam 60 hari', NULL, '/contracts/' || r.id,
                                 'info', 4005, v_p, 'ctrexp60:' || r.id);
    ELSIF v_d IN (30, 14) THEN
      PERFORM _notify(r.process_owner_id, 'contract_expiry', r.contract_no || ' berakhir dalam ' || v_d || ' hari', 'Siapkan demobilisasi',
                      '/contracts/' || r.id, 'warning', NULL, '{}'::jsonb, 'ctrexp' || v_d || ':' || r.id);
    ELSIF v_d < 0 AND r.status = 'active' THEN
      PERFORM _notify(r.process_owner_id, 'contract_past_end', r.contract_no || ' melewati end date', 'Mulai demobilisasi atau perpanjang kontrak',
                      '/contracts/' || r.id, 'critical', NULL, '{}'::jsonb, 'ctrpast:' || r.id || ':' || to_char(_local_today(r.geozone), 'IYYY-IW'));
      v_n := v_n + 1;
    END IF;
  END LOOP;
  RETURN v_n;
END $$;

CREATE OR REPLACE FUNCTION svc_incident_overdue() RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE r RECORD; v_n INT := 0; v_p JSONB;
BEGIN
  FOR r IN SELECT i.*, k.contractor_id, k.contract_no FROM incidents i JOIN contracts k ON k.id = i.contract_id
           WHERE i.status <> 'closed' AND i.full_report_at IS NULL AND i.full_report_due_at < NOW() LOOP
    v_p := jsonb_build_object('incident_no', r.incident_no, 'title', r.title, 'due', r.full_report_due_at, 'contract_no', r.contract_no);
    PERFORM _notify_contractor(r.contractor_id, 'incident_overdue', 'Laporan lengkap ' || r.incident_no || ' terlambat', r.title,
                               '/incidents/' || r.id, 'critical', 3002, v_p, 'incod:' || r.id || ':' || CURRENT_DATE);
    PERFORM _notify_permission_holders('incident.manage', r.contract_id, 'incident_overdue', 'Laporan ' || r.incident_no || ' terlambat', r.title,
                                       '/incidents/' || r.id, 'warning', 3002, v_p, 'incod:' || r.id || ':' || CURRENT_DATE);
    v_n := v_n + 1;
  END LOOP;
  FOR r IN SELECT i.*, k.contractor_id FROM incidents i JOIN contracts k ON k.id = i.contract_id
           WHERE i.status <> 'closed' AND i.flash_due_at < NOW() AND i.flash_at IS NULL LOOP
    PERFORM _notify_contractor(r.contractor_id, 'incident_flash_overdue', 'Flash report ' || r.incident_no || ' terlambat', r.title,
                               '/incidents/' || r.id, 'critical', NULL, '{}'::jsonb, 'flashod:' || r.id);
  END LOOP;
  RETURN v_n;
END $$;

-- ═════════════ CHAT ═════════════
CREATE OR REPLACE FUNCTION svc_chat_scheduler() RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE s chat_scheduled; v_next TIMESTAMPTZ; v_n INT := 0; v_tid TEXT;
BEGIN
  FOR s IN SELECT * FROM chat_scheduled WHERE status = 'scheduled' AND send_at <= NOW() ORDER BY send_at LIMIT 200 FOR UPDATE SKIP LOCKED LOOP
    BEGIN
      IF NOT EXISTS (SELECT 1 FROM chat_members m JOIN profiles p ON p.id = m.user_id AND p.status = 'active'
                     JOIN chat_channels c ON c.id = m.channel_id AND NOT c.is_archived AND NOT c.is_locked
                     WHERE m.channel_id = s.channel_id AND m.user_id = s.sender_id AND m.member_role <> 'readonly'
                       AND COALESCE(m.silenced_until, '-infinity') < NOW()) THEN
        UPDATE chat_scheduled SET status = 'failed', last_error = 'Pengirim tidak lagi bisa mengirim ke channel ini' WHERE id = s.id;
        CONTINUE;
      END IF;
      IF s.task_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM tasks WHERE id = s.task_id AND status = ANY(_open_statuses())) THEN
        UPDATE chat_scheduled SET status = 'cancelled', last_error = 'Task sudah selesai' WHERE id = s.id;
        CONTINUE;
      END IF;
      SELECT task_id INTO v_tid FROM tasks WHERE id = s.task_id;
      PERFORM _post_message(s.channel_id, s.sender_id, _decrypt(s.body_enc, 'chat', s.key_ver),
                            CASE WHEN s.task_id IS NOT NULL THEN 'reminder' ELSE 'text' END, s.priority, s.requires_ack,
                            NULL, NULL, '{}', gen_random_uuid(), CASE WHEN v_tid IS NOT NULL THEN ARRAY[v_tid] ELSE '{}'::TEXT[] END);
      v_n := v_n + 1;
      v_next := NULL;
      IF s.recur_freq <> 'none' THEN
        v_next := _next_recurrence(s.recur_freq, s.recur_dow, s.recur_time, s.recur_tz, s.send_at);
        WHILE v_next IS NOT NULL AND v_next <= NOW() LOOP
          v_next := _next_recurrence(s.recur_freq, s.recur_dow, s.recur_time, s.recur_tz, v_next);
        END LOOP;
        IF s.recur_until IS NOT NULL AND (v_next AT TIME ZONE s.recur_tz)::DATE > s.recur_until THEN v_next := NULL; END IF;
      END IF;
      UPDATE chat_scheduled SET last_sent_at = NOW(), last_error = NULL, send_at = COALESCE(v_next, send_at),
                                status = CASE WHEN v_next IS NULL THEN 'sent' ELSE 'scheduled' END
      WHERE id = s.id;
    EXCEPTION WHEN OTHERS THEN
      UPDATE chat_scheduled SET status = 'failed', last_error = left(SQLERRM, 500) WHERE id = s.id;
    END;
  END LOOP;
  RETURN v_n;
END $$;

-- Urgent: push ulang tiap 2 menit selama ≤ 20 menit sampai dibaca/di-ack
CREATE OR REPLACE FUNCTION svc_chat_urgent_repeat() RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_n INT;
BEGIN
  INSERT INTO notification_outbox (channel, template_id, to_user, params, dedupe_key)
  SELECT 'push', 6002, cm.user_id, jsonb_build_object('channel', m.channel_id, 'message', m.id),
         'push:urg:' || m.id || ':' || cm.user_id || ':' || floor(EXTRACT(EPOCH FROM NOW() - m.created_at) / 120)::INT
  FROM chat_messages m
  JOIN chat_members cm ON cm.channel_id = m.channel_id AND cm.user_id IS DISTINCT FROM m.sender_id AND cm.last_read_seq < m.seq
  JOIN profiles p ON p.id = cm.user_id AND p.status = 'active'
  WHERE m.priority = 'urgent' AND m.deleted_at IS NULL
    AND m.created_at BETWEEN NOW() - INTERVAL '20 minutes' AND NOW() - INTERVAL '2 minutes'
    AND NOT EXISTS (SELECT 1 FROM chat_acks a WHERE a.message_id = m.id AND a.user_id = cm.user_id)
  ON CONFLICT (dedupe_key) DO NOTHING;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $$;

-- Email fallback mention/DM belum dibaca > 2 jam (#6001, tanpa isi, maks 1/hari/user)
CREATE OR REPLACE FUNCTION svc_chat_digest() RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_n INT;
BEGIN
  INSERT INTO notification_outbox (template_id, to_user, params, dedupe_key)
  SELECT 6001, x.user_id, jsonb_build_object('unread', x.n, 'link', '/chat'), 'chatdigest:' || x.user_id || ':' || CURRENT_DATE
  FROM (SELECT cm.user_id, count(*) AS n
        FROM chat_members cm
        JOIN chat_channels c ON c.id = cm.channel_id
        JOIN profiles p ON p.id = cm.user_id AND p.status = 'active'
        JOIN chat_messages m ON m.channel_id = cm.channel_id AND m.seq > cm.last_read_seq AND m.deleted_at IS NULL
             AND m.sender_id IS DISTINCT FROM cm.user_id
             AND m.created_at BETWEEN NOW() - INTERVAL '7 days' AND NOW() - INTERVAL '2 hours'
        WHERE cm.notify_level <> 'none' AND COALESCE(cm.muted_until, '-infinity') < NOW()
          AND ((c.type = 'direct' AND cm.notify_level = 'all') OR cm.user_id = ANY(m.mentions))
        GROUP BY cm.user_id) x
  ON CONFLICT (dedupe_key) DO NOTHING;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $$;

-- ═════════════ KEAMANAN ═════════════
CREATE OR REPLACE FUNCTION svc_security_scan() RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE r RECORD; v_anom INT := 0; v_exp INT := 0; v_open INT;
BEGIN
  -- 1. Rate limit tersaturasi (indikasi brute force / abuse)
  FOR r IN SELECT key, window_start, hits FROM rate_limits WHERE hits >= limit_value AND window_start > NOW() - INTERVAL '30 minutes' LOOP
    INSERT INTO security_events (event, severity, detail)
    SELECT 'anomaly', 'warning', jsonb_build_object('type', 'rate_limit_saturated', 'key', r.key, 'window', r.window_start, 'hits', r.hits)
    WHERE NOT EXISTS (SELECT 1 FROM security_events WHERE event = 'anomaly' AND detail ->> 'key' = r.key AND detail -> 'window' = to_jsonb(r.window_start));
    v_anom := v_anom + 1;
  END LOOP;
  -- 2. > 3 perangkat baru per user dalam 24 jam
  FOR r IN SELECT user_id, count(*) AS n FROM trusted_devices WHERE first_seen > NOW() - INTERVAL '24 hours' GROUP BY user_id HAVING count(*) > 3 LOOP
    INSERT INTO security_events (user_id, event, severity, detail)
    SELECT r.user_id, 'anomaly', 'critical', jsonb_build_object('type', 'many_new_devices', 'count', r.n, 'day', CURRENT_DATE)
    WHERE NOT EXISTS (SELECT 1 FROM security_events WHERE user_id = r.user_id AND event = 'anomaly'
                        AND detail ->> 'type' = 'many_new_devices' AND detail ->> 'day' = CURRENT_DATE::TEXT);
  END LOOP;
  -- 2b. > 10 akun pending baru dalam 1 jam (gelombang pendaftaran bot / akun palsu)
  INSERT INTO security_events (event, severity, detail)
  SELECT 'anomaly', 'warning', jsonb_build_object('type', 'signup_burst', 'count', n, 'hour', to_char(date_trunc('hour', NOW()), 'YYYYMMDDHH24'))
  FROM (SELECT count(*) AS n FROM profiles WHERE status = 'pending' AND created_at > NOW() - INTERVAL '1 hour') s
  WHERE n > 10 AND NOT EXISTS (SELECT 1 FROM security_events WHERE event = 'anomaly' AND detail ->> 'type' = 'signup_burst'
                                 AND detail ->> 'hour' = to_char(date_trunc('hour', NOW()), 'YYYYMMDDHH24'));
  -- 3. Role sementara (JIT) yang kedaluwarsa dicabut → trigger sinkron chat + audit
  FOR r IN SELECT ur.id, ur.user_id, ro.name FROM user_roles ur JOIN roles ro ON ro.id = ur.role_id WHERE ur.expires_at <= NOW() LOOP
    DELETE FROM user_roles WHERE id = r.id;
    PERFORM _security_event(r.user_id, 'role_changed', 'info', jsonb_build_object('action', 'expired', 'role', r.name));
    PERFORM _notify(r.user_id, 'role_expired', 'Akses sementara berakhir', 'Role ' || r.name || ' telah berakhir', '/', 'info', 7007,
                    jsonb_build_object('role', r.name), 'roleexp:' || r.id);
    v_exp := v_exp + 1;
  END LOOP;
  -- 4. Alert admin keamanan (#7005), maks 1/jam
  SELECT count(*) INTO v_open FROM security_events WHERE handled_at IS NULL AND severity IN ('warning','critical')
                                                     AND created_at > NOW() - INTERVAL '15 minutes';
  IF v_open > 0 THEN
    PERFORM _notify_permission_holders('admin.security.manage', NULL, 'security_alert', v_open || ' security event baru', NULL,
              '/admin/security', 'critical', 7005, jsonb_build_object('count', v_open), 'secalert:' || to_char(date_trunc('hour', NOW()), 'YYYYMMDDHH24'));
  END IF;
  RETURN jsonb_build_object('anomalies', v_anom, 'roles_expired', v_exp, 'open_recent', v_open);
END $$;

-- Partisi audit tahun berjalan + tahun depan (bulanan). Trigger immutability parent di-clone otomatis ke partisi baru.
CREATE OR REPLACE FUNCTION svc_ensure_audit_partition() RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE y INT;
BEGIN
  FOR y IN EXTRACT(YEAR FROM NOW())::INT .. EXTRACT(YEAR FROM NOW())::INT + 1 LOOP
    IF to_regclass('public.audit_logs_' || y) IS NULL THEN
      BEGIN
        EXECUTE format('CREATE TABLE public.%I PARTITION OF public.audit_logs FOR VALUES FROM (%L) TO (%L)',
                       'audit_logs_' || y, make_date(y, 1, 1), make_date(y + 1, 1, 1));
        EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC, anon, authenticated', 'audit_logs_' || y);
      EXCEPTION WHEN OTHERS THEN
        INSERT INTO security_events (event, severity, detail) VALUES ('anomaly', 'critical',
          jsonb_build_object('type', 'audit_partition_failed', 'year', y, 'error', SQLERRM));
      END;
    END IF;
  END LOOP;
END $$;

-- Anchor harian: head hash chain dikirim keluar DB (Edge audit-anchor → email out-of-band) + #7006 ke pemegang admin.audit.verify
CREATE OR REPLACE FUNCTION svc_audit_anchor() RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_h audit_chain_head; v JSONB;
BEGIN
  SELECT * INTO v_h FROM audit_chain_head WHERE id = 1;
  v := jsonb_build_object('last_id', v_h.last_id, 'last_hash', v_h.last_hash, 'anchored_at', NOW(),
                          'rows_24h', (SELECT count(*) FROM audit_logs WHERE created_at > NOW() - INTERVAL '24 hours'));
  INSERT INTO security_events (event, severity, detail) VALUES ('audit_anchor', 'info', v);
  PERFORM _notify_permission_holders('admin.audit.verify', NULL, 'audit_anchor', 'Audit anchor harian', v_h.last_hash, '/admin/audit',
                                     'info', 7006, v, 'anchor:' || CURRENT_DATE);
  RETURN v;
END $$;

-- ═════════════ RETENSI ═════════════
CREATE OR REPLACE FUNCTION _purge_messages(p_ids UUID[]) RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_n INT;
BEGIN
  IF p_ids IS NULL OR cardinality(p_ids) = 0 THEN RETURN 0; END IF;
  UPDATE chat_messages SET reply_to = NULL WHERE reply_to = ANY(p_ids) AND NOT (id = ANY(p_ids));
  DELETE FROM chat_reactions     WHERE message_id = ANY(p_ids);
  DELETE FROM chat_acks          WHERE message_id = ANY(p_ids);
  DELETE FROM chat_pins          WHERE message_id = ANY(p_ids);
  DELETE FROM chat_saved         WHERE message_id = ANY(p_ids);
  DELETE FROM chat_message_edits WHERE message_id = ANY(p_ids);
  DELETE FROM chat_messages      WHERE id = ANY(p_ids);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $$;

CREATE OR REPLACE FUNCTION svc_retention() RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v JSONB := '{}'::jsonb; v_n INT; v_chat INT := 0; r RECORD; v_ids UUID[];
BEGIN
  PERFORM set_config('comen.retention_purge', 'on', TRUE);

  DELETE FROM notifications WHERE (read_at IS NOT NULL AND created_at < NOW() - INTERVAL '180 days') OR created_at < NOW() - INTERVAL '365 days';
  GET DIAGNOSTICS v_n = ROW_COUNT; v := v || jsonb_build_object('notifications', v_n);
  DELETE FROM notification_outbox WHERE (status IN ('sent','skipped') AND created_at < NOW() - INTERVAL '90 days')
                                     OR (status = 'failed' AND created_at < NOW() - INTERVAL '180 days');
  GET DIAGNOSTICS v_n = ROW_COUNT; v := v || jsonb_build_object('outbox', v_n);
  DELETE FROM rate_limits WHERE window_start < NOW() - INTERVAL '2 days';
  DELETE FROM security_events WHERE severity = 'info' AND handled_at IS NOT NULL AND created_at < NOW() - INTERVAL '2 years';
  DELETE FROM chat_scheduled WHERE status IN ('sent','cancelled','failed') AND created_at < NOW() - INTERVAL '90 days';
  DELETE FROM trusted_devices WHERE revoked_at < NOW() - INTERVAL '1 year';

  -- Chat: hormati retention_days per channel & legal hold. Balasan thread dulu, lalu root yang sudah tanpa balasan.
  FOR r IN SELECT id, retention_days FROM chat_channels WHERE NOT legal_hold LOOP
    SELECT array_agg(id) INTO v_ids FROM (
      SELECT id FROM chat_messages WHERE channel_id = r.id AND thread_root IS NOT NULL
        AND created_at < NOW() - make_interval(days => r.retention_days) LIMIT 5000) a;
    v_chat := v_chat + _purge_messages(v_ids);
    SELECT array_agg(id) INTO v_ids FROM (
      SELECT m.id FROM chat_messages m WHERE m.channel_id = r.id AND m.thread_root IS NULL
        AND m.created_at < NOW() - make_interval(days => r.retention_days)
        AND NOT EXISTS (SELECT 1 FROM chat_messages x WHERE x.thread_root = m.id) LIMIT 5000) b;
    v_chat := v_chat + _purge_messages(v_ids);
  END LOOP;
  v := v || jsonb_build_object('chat_messages', v_chat);
  INSERT INTO security_events (event, severity, detail) VALUES ('retention', 'info', v);
  RETURN v;
END $$;

-- Rotasi kunci: tambah secret chat_key_v{n+1}/comen_data_key_v{n+1} di Vault → admin_upsert_setting('<kind>_key_ver', n+1)
-- → jalankan svc_rekey berulang sampai 0. Data lama tetap terbaca selama secret versi lama masih ada.
CREATE OR REPLACE FUNCTION svc_rekey(p_kind TEXT, p_batch INT DEFAULT 1000) RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_ver SMALLINT := _active_key_ver(p_kind); v_n INT := 0; v_x INT;
BEGIN
  IF p_kind = 'chat' THEN
    UPDATE chat_messages m SET body_enc = _encrypt(_decrypt(m.body_enc, 'chat', m.key_ver), 'chat', v_ver), key_ver = v_ver
    WHERE m.id IN (SELECT id FROM chat_messages WHERE key_ver <> v_ver LIMIT p_batch);
    GET DIAGNOSTICS v_n = ROW_COUNT;
    UPDATE chat_scheduled s SET body_enc = _encrypt(_decrypt(s.body_enc, 'chat', s.key_ver), 'chat', v_ver), key_ver = v_ver
    WHERE s.status = 'scheduled' AND s.key_ver <> v_ver;
  ELSIF p_kind = 'data' THEN
    UPDATE profiles SET phone_enc = _encrypt(_decrypt(phone_enc, 'data', enc_key_ver), 'data', v_ver), enc_key_ver = v_ver
    WHERE id IN (SELECT id FROM profiles WHERE enc_key_ver <> v_ver AND anonymized_at IS NULL LIMIT p_batch);
    GET DIAGNOSTICS v_x = ROW_COUNT; v_n := v_n + v_x;
    UPDATE contractors SET primary_contact_phone_enc = _encrypt(_decrypt(primary_contact_phone_enc, 'data', enc_key_ver), 'data', v_ver), enc_key_ver = v_ver
    WHERE id IN (SELECT id FROM contractors WHERE enc_key_ver <> v_ver LIMIT p_batch);
    GET DIAGNOSTICS v_x = ROW_COUNT; v_n := v_n + v_x;
    UPDATE push_subscriptions SET auth_secret_enc = _encrypt(_decrypt(auth_secret_enc, 'data', enc_key_ver), 'data', v_ver), enc_key_ver = v_ver
    WHERE id IN (SELECT id FROM push_subscriptions WHERE enc_key_ver <> v_ver LIMIT p_batch);
    GET DIAGNOSTICS v_x = ROW_COUNT; v_n := v_n + v_x;
  ELSE
    RAISE EXCEPTION 'kind harus chat|data' USING ERRCODE = '22023';
  END IF;
  RETURN v_n;
END $$;

-- ═════════════ OUTBOX (dipanggil Edge notify-dispatch, service_role) ═════════════
CREATE OR REPLACE FUNCTION svc_claim_outbox(p_limit INT DEFAULT 50) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v JSONB;
BEGIN
  UPDATE notification_outbox SET status = 'failed', last_error = COALESCE(last_error, 'lock_timeout'), locked_until = NULL
  WHERE status = 'sending' AND locked_until < NOW() AND attempts >= 5;
  UPDATE notification_outbox o SET status = 'skipped', last_error = 'recipient_inactive'
  WHERE o.status = 'queued' AND o.to_user IS NOT NULL
    AND EXISTS (SELECT 1 FROM profiles p WHERE p.id = o.to_user AND p.status <> 'active');

  WITH c AS (
    SELECT id FROM notification_outbox
    WHERE (status = 'queued' AND send_after <= NOW()) OR (status = 'sending' AND locked_until < NOW())
    ORDER BY send_after, id
    LIMIT LEAST(GREATEST(p_limit, 1), 200)
    FOR UPDATE SKIP LOCKED),
  u AS (
    UPDATE notification_outbox o SET status = 'sending', locked_until = NOW() + INTERVAL '5 minutes', attempts = o.attempts + 1
    FROM c WHERE o.id = c.id
    RETURNING o.*)
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'id', u.id, 'channel', u.channel, 'template_id', u.template_id,
           'brevo_template_id', setting('brevo_template_map') ->> u.template_id::TEXT,
           'to_email', COALESCE(u.to_email, p.email), 'to_name', p.full_name, 'locale', COALESCE(p.locale, 'id'),
           'params', u.params || jsonb_build_object('app_url', _setting_text('app_url', 'https://comen.vercel.app')),
           'push', CASE WHEN u.channel = 'push' THEN (
                     SELECT COALESCE(jsonb_agg(jsonb_build_object('endpoint', s.endpoint, 'p256dh', s.p256dh,
                              'auth', _decrypt(s.auth_secret_enc, 'data', s.enc_key_ver))), '[]'::jsonb)
                     FROM push_subscriptions s JOIN trusted_devices d ON d.id = s.device_id AND d.revoked_at IS NULL
                     WHERE s.user_id = u.to_user) END)), '[]'::jsonb)
  INTO v
  FROM u LEFT JOIN profiles p ON p.id = u.to_user;
  RETURN v;
END $$;

CREATE OR REPLACE FUNCTION svc_mark_outbox(p_id BIGINT, p_ok BOOLEAN, p_provider_msg_id TEXT DEFAULT NULL, p_error TEXT DEFAULT NULL,
  p_permanent BOOLEAN DEFAULT FALSE) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
BEGIN
  UPDATE notification_outbox SET
    status          = CASE WHEN p_ok THEN 'sent' WHEN p_permanent OR attempts >= 5 THEN 'failed' ELSE 'queued' END,
    sent_at         = CASE WHEN p_ok THEN NOW() END,
    provider_msg_id = COALESCE(left(p_provider_msg_id, 200), provider_msg_id),
    last_error      = CASE WHEN p_ok THEN NULL ELSE left(p_error, 1000) END,
    send_after      = CASE WHEN p_ok THEN send_after ELSE NOW() + make_interval(mins => power(2, LEAST(attempts, 8))::INT) END,
    locked_until    = NULL
  WHERE id = p_id AND status = 'sending';
END $$;

CREATE OR REPLACE FUNCTION svc_delete_push_subscription(p_endpoint TEXT) RETURNS VOID
LANGUAGE sql SECURITY DEFINER SET search_path = public, extensions AS $$
  DELETE FROM push_subscriptions WHERE endpoint = p_endpoint
$$;

-- Event Brevo (webhook): bounce/spam/blocked → outbox failed + security event
CREATE OR REPLACE FUNCTION svc_email_event(p_provider_msg_id TEXT, p_event TEXT, p_email TEXT, p_reason TEXT DEFAULT NULL) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
BEGIN
  IF p_event IN ('hard_bounce','soft_bounce','blocked','invalid_email','spam','error') THEN
    UPDATE notification_outbox SET status = 'failed', last_error = left(p_event || ': ' || COALESCE(p_reason, ''), 1000)
    WHERE provider_msg_id = p_provider_msg_id AND status = 'sent' AND p_event <> 'soft_bounce';
    INSERT INTO security_events (event, severity, detail)
    VALUES ('email_' || p_event, CASE WHEN p_event IN ('spam','blocked') THEN 'warning' ELSE 'info' END,
            jsonb_build_object('provider_msg_id', p_provider_msg_id, 'email', lower(p_email), 'reason', left(p_reason, 500)));
  END IF;
END $$;

SELECT cron.schedule('comen-notify-dispatch',   '* * * * *',     $$SELECT public._call_edge('notify-dispatch')$$);
SELECT cron.schedule('comen-chat-scheduler',    '* * * * *',     $$SELECT public.svc_chat_scheduler()$$);
SELECT cron.schedule('comen-chat-urgent',       '*/2 * * * *',   $$SELECT public.svc_chat_urgent_repeat()$$);
SELECT cron.schedule('comen-chat-digest',       '*/30 * * * *',  $$SELECT public.svc_chat_digest()$$);
SELECT cron.schedule('comen-security-scan',     '*/15 * * * *',  $$SELECT public.svc_security_scan()$$);
SELECT cron.schedule('comen-incident-overdue',  '*/15 * * * *',  $$SELECT public.svc_incident_overdue()$$);
SELECT cron.schedule('comen-review-sla',        '5 * * * *',     $$SELECT public.svc_review_sla()$$);
SELECT cron.schedule('comen-doc-expiry',        '30 23 * * *',   $$SELECT public.svc_doc_expiry()$$);          -- 06:30 WIB
SELECT cron.schedule('comen-asl-expiry',        '40 23 * * *',   $$SELECT public.svc_asl_expiry()$$);
SELECT cron.schedule('comen-contract-expiry',   '50 23 * * *',   $$SELECT public.svc_contract_expiry()$$);
SELECT cron.schedule('comen-monthly-reports',   '0 0 * * *',     $$SELECT public.svc_monthly_reports()$$);     -- 07:00 WIB
SELECT cron.schedule('comen-task-reminders',    '0 1 * * *',     $$SELECT public.svc_task_reminders()$$);      -- 08:00 WIB
SELECT cron.schedule('comen-link-coverage',     '0 2 * * 1-5',   $$SELECT public.svc_link_coverage()$$);       -- 09:00 WIB
SELECT cron.schedule('comen-audit-anchor',      '55 16 * * *',   $$SELECT public._call_edge('audit-anchor')$$); -- 23:55 WIB
SELECT cron.schedule('comen-kpi-recalc',        '0 19 * * *',    $$SELECT public.svc_kpi_recalc()$$);          -- 02:00 WIB
SELECT cron.schedule('comen-retention',         '0 20 * * *',    $$SELECT public.svc_retention()$$);           -- 03:00 WIB
SELECT cron.schedule('comen-audit-partition',   '0 0 1 * *',     $$SELECT public.svc_ensure_audit_partition()$$);
SELECT cron.schedule('comen-cron-history-gc',   '0 21 * * 0',    $$DELETE FROM cron.job_run_details WHERE end_time < NOW() - INTERVAL '14 days'$$);

DO $$ DECLARE s TEXT; BEGIN
  FOREACH s IN ARRAY ARRAY['chat_key_v1','comen_data_key_v1','ip_pepper','confirm_code_secret'] LOOP
    IF NOT EXISTS (SELECT 1 FROM vault.secrets WHERE name = s) THEN
      PERFORM vault.create_secret(encode(extensions.gen_random_bytes(32), 'base64'), s, 'COMEN auto-generated');
    END IF;
  END LOOP;
END $$;
-- Manual (sekali per environment, nilai sama dengan env Edge):
--   SELECT vault.create_secret('https://<project-ref>.supabase.co/functions/v1', 'edge_base_url');
--   SELECT vault.create_secret('<openssl rand -base64 32>', 'cron_secret');          -- = CRON_SECRET di Edge
--   SELECT vault.create_secret('<openssl rand -base64 32>', 'edge_attest_secret');   -- = EDGE_ATTEST_SECRET di Edge
