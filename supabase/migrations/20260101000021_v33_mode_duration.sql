-- 21 · Blueprint v3.3 — Contract Mode × Duration → access tier, level user contractor (PIC / Supervisor / Employee)
-- Idempoten. Semua RPC baru default-deny (migration 16) → GRANT eksplisit di akhir file.

-- ═════════════ TIPE ═════════════
DO $$ BEGIN
  IF to_regtype('public.contract_mode') IS NULL THEN CREATE TYPE contract_mode AS ENUM ('mode_1','mode_2','mode_3'); END IF;
  IF to_regtype('public.duration_category') IS NULL THEN CREATE TYPE duration_category AS ENUM ('long_term','short_term'); END IF;
  IF to_regtype('public.access_tier') IS NULL THEN CREATE TYPE access_tier AS ENUM ('full','streamlined','minimal','visitor'); END IF;
  IF to_regtype('public.contractor_user_level') IS NULL THEN CREATE TYPE contractor_user_level AS ENUM ('pic','supervisor','employee'); END IF;
END $$;
COMMENT ON TYPE contract_mode IS 'GL-WFT-OEPS-L3-78: Mode 1 (WFRD manage penuh), Mode 2 (via pihak ketiga), Mode 3 (independen, HSE-MS sendiri)';
COMMENT ON TYPE duration_category IS 'long_term > 90 hari; short_term ≤ 90 hari (end_date - start_date)';
COMMENT ON TYPE access_tier IS 'Turunan mode × durasi — menentukan set dokumen, menu, SLA review, target BBS';
COMMENT ON TYPE contractor_user_level IS 'PIC (legal/representative) > Supervisor (operasional) > Employee (pekerja)';

-- ═════════════ KONTRAK: MODE + KOLOM TURUNAN (R27/R28: tidak bisa di-set manual) ═════════════
ALTER TABLE contracts ADD COLUMN IF NOT EXISTS contract_mode contract_mode NOT NULL DEFAULT 'mode_1';
ALTER TABLE contracts ADD COLUMN IF NOT EXISTS hse_oversight_notes TEXT;
ALTER TABLE contracts ADD COLUMN IF NOT EXISTS duration_days INT GENERATED ALWAYS AS (end_date - start_date) STORED;
ALTER TABLE contracts ADD COLUMN IF NOT EXISTS duration_category duration_category GENERATED ALWAYS AS (
  CASE WHEN end_date - start_date > 90 THEN 'long_term'::duration_category ELSE 'short_term'::duration_category END) STORED;
ALTER TABLE contracts ADD COLUMN IF NOT EXISTS access_tier access_tier GENERATED ALWAYS AS (
  CASE WHEN contract_mode IN ('mode_1','mode_2') AND end_date - start_date > 90 THEN 'full'::access_tier
       WHEN contract_mode IN ('mode_1','mode_2') THEN 'streamlined'::access_tier
       WHEN end_date - start_date > 90 THEN 'minimal'::access_tier
       ELSE 'visitor'::access_tier END) STORED;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'contracts_oversight_notes_len') THEN
    ALTER TABLE contracts ADD CONSTRAINT contracts_oversight_notes_len CHECK (hse_oversight_notes IS NULL OR length(hse_oversight_notes) <= 2000);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'contracts_mode3_requires_notes') THEN
    ALTER TABLE contracts ADD CONSTRAINT contracts_mode3_requires_notes
      CHECK (contract_mode <> 'mode_3' OR length(btrim(COALESCE(hse_oversight_notes, ''))) >= 20);
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS idx_contracts_access_tier ON contracts (access_tier) WHERE status NOT IN ('closed','terminated');
COMMENT ON COLUMN contracts.contract_mode IS 'Di-set saat create_contract; diubah hanya via change_contract_mode sebelum pre-mobilization (R26/R34)';
COMMENT ON COLUMN contracts.access_tier IS 'GENERATED dari contract_mode × durasi (R28)';

-- Kolom turunan tidak dihitung ulang di BEFORE trigger → dikecualikan dari pembanding kontrak final
CREATE OR REPLACE FUNCTION _contracts_guard() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.contract_no IS DISTINCT FROM OLD.contract_no OR NEW.contract_seq <> OLD.contract_seq OR NEW.contractor_id <> OLD.contractor_id THEN
    RAISE EXCEPTION 'Nomor & contractor kontrak immutable' USING ERRCODE = '42501'; END IF;
  IF OLD.status IN ('closed','terminated') AND auth.uid() IS NOT NULL
     AND (to_jsonb(NEW) - ARRAY['updated_at','health_flag','duration_days','duration_category','access_tier'])
         <> (to_jsonb(OLD) - ARRAY['updated_at','health_flag','duration_days','duration_category','access_tier']) THEN
    RAISE EXCEPTION 'Kontrak final tidak bisa diubah' USING ERRCODE = '42501'; END IF;
  RETURN NEW;
END $$;

-- ═════════════ HELPER MURNI ═════════════
CREATE OR REPLACE FUNCTION resolve_access_tier(p_mode contract_mode, p_duration_days INT) RETURNS access_tier
LANGUAGE sql IMMUTABLE SET search_path = public, extensions AS $$
  SELECT CASE WHEN p_mode IN ('mode_1','mode_2') AND p_duration_days > 90 THEN 'full'::access_tier
              WHEN p_mode IN ('mode_1','mode_2') THEN 'streamlined'::access_tier
              WHEN p_duration_days > 90 THEN 'minimal'::access_tier
              ELSE 'visitor'::access_tier END
$$;
COMMENT ON FUNCTION resolve_access_tier IS 'Sama persis dengan ekspresi kolom contracts.access_tier (dipakai validasi sebelum baris dihitung)';

CREATE OR REPLACE FUNCTION _tier_rank(p_tier access_tier) RETURNS INT LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_tier WHEN 'full' THEN 4 WHEN 'streamlined' THEN 3 WHEN 'minimal' THEN 2 WHEN 'visitor' THEN 1 END
$$;

CREATE OR REPLACE FUNCTION _level_rank(p_level contractor_user_level) RETURNS INT LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_level WHEN 'pic' THEN 3 WHEN 'supervisor' THEN 2 ELSE 1 END
$$;

-- SLA review (hari kerja) & target BBS per minggu per tier — matriks 25.2
CREATE OR REPLACE FUNCTION _tier_review_sla(p_tier access_tier) RETURNS INT LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_tier WHEN 'full' THEN 5 WHEN 'streamlined' THEN 2 WHEN 'minimal' THEN 3 ELSE 1 END
$$;

CREATE OR REPLACE FUNCTION _bbs_target_for_tier(p_tier access_tier) RETURNS INT
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT CASE p_tier WHEN 'full' THEN _setting_int('bbs_weekly_target', 30) WHEN 'streamlined' THEN 10 WHEN 'minimal' THEN 5 ELSE 0 END
$$;

-- Level minimum per permission untuk user contractor (matriks 27.2). NULL = semua level.
CREATE OR REPLACE FUNCTION _perm_min_level(p_perm TEXT) RETURNS contractor_user_level LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_perm WHEN 'company.edit' THEN 'pic'::contractor_user_level
                     WHEN 'contract.golive.request' THEN 'pic'::contractor_user_level
                     WHEN 'meeting.sign' THEN 'pic'::contractor_user_level END
$$;

-- ═════════════ KATALOG: TIER YANG BERLAKU ═════════════
-- Spec min_tier/max_tier diganti daftar eksplisit: rentang default (full..visitor) membuat semua tier gagal,
-- dan tier tidak berurutan rapi (minimal bukan subset streamlined).
DO $$
DECLARE v_new BOOLEAN := NOT EXISTS (SELECT 1 FROM information_schema.columns
                                     WHERE table_schema = 'public' AND table_name = 'doc_type_catalog' AND column_name = 'applicable_tiers');
BEGIN
  IF v_new THEN
    ALTER TABLE doc_type_catalog ADD COLUMN applicable_tiers access_tier[] NOT NULL DEFAULT '{full}'
      CHECK (cardinality(applicable_tiers) >= 1);
    UPDATE doc_type_catalog SET applicable_tiers = applicable_tiers || '{streamlined}'::access_tier[]
    WHERE code IN ('CNTRCT','HSEPLN','JRAREG','TRNCRT','EQPCRT','INSCRT','PRMLIC','MANLST',
                   'MOBCHK','DMBCHK','OPRSLF','MONRPT','SUBDOC',
                   'CNFSPC','HOTWRK','WAHRSC','MSDSXX','WTRSAF','JRNMGT','WSTPLN','WSTMNF',
                   'ACTITM','FNDCLS','INVRPT');
    UPDATE doc_type_catalog SET applicable_tiers = applicable_tiers || '{minimal}'::access_tier[]
    WHERE code IN ('CNTRCT','HSEPLN','INSCRT','PRMLIC','MONRPT',
                   'CNFSPC','HOTWRK','WAHRSC','MSDSXX','WTRSAF','JRNMGT','WSTPLN','WSTMNF',
                   'ACTITM','FNDCLS','INVRPT');
    UPDATE doc_type_catalog SET applicable_tiers = applicable_tiers || '{visitor}'::access_tier[] WHERE code = 'ACTITM';
  END IF;
END $$;
COMMENT ON COLUMN doc_type_catalog.applicable_tiers IS 'Tier kontrak yang mewajibkan dokumen ini (R29). Hanya relevan untuk scope contract.';

INSERT INTO doc_type_catalog (code, label, allowed_scopes, kind, phase, requirement, condition_key, min_risk_class,
  vendor_requirement, vendor_condition_key, subcon_required, reviewer_role, requires_email, requires_expiry,
  requires_fingerprint, sensitive, due_anchor, due_offset_days, review_sla_days, is_mob_gate, checklist_template, applicable_tiers)
VALUES ('VISACK', 'Visitor Site Rules Acknowledgement', '{contract}', 'checklist', 'pre_mobilization', 'mandatory', NULL, NULL,
  NULL, NULL, FALSE, 'process_owner', FALSE, FALSE, FALSE, FALSE, 'target_mob_date', -1, 1, TRUE,
  '[{"category":"Induction","label":"Safety induction / briefing site diikuti seluruh personel"},
    {"category":"Site Rules","label":"Aturan site dipahami: APD wajib, area terlarang, larangan merokok"},
    {"category":"Emergency","label":"Prosedur darurat & titik kumpul dipahami"},
    {"category":"Escort","label":"Selalu didampingi host/escort WFRD selama di lokasi"},
    {"category":"Scope","label":"Tidak melakukan pekerjaan berisiko tinggi (hot work, confined space, ketinggian, bahan kimia)"},
    {"category":"Stop Work","label":"Stop Work Authority dipahami — siapa pun berhak menghentikan pekerjaan tidak aman"},
    {"category":"Host","label":"Host WFRD mengonfirmasi kunjungan & akses site","owner_party":"wfrd"}]'::jsonb,
  '{visitor}')
ON CONFLICT (code) DO NOTHING;

-- ═════════════ REQUIREMENT PER TIER ═════════════
CREATE OR REPLACE FUNCTION build_contract_requirements(p_contract UUID) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_k contracts;
BEGIN
  SELECT * INTO v_k FROM contracts WHERE id = p_contract;
  INSERT INTO contract_requirements (contract_id, doc_type_code, applicable, is_mandatory, is_mob_gate, reason, computed_at)
  SELECT p_contract, d.code, a.applicable, a.applicable AND d.requirement <> 'optional',
         a.applicable AND d.requirement <> 'optional' AND d.is_mob_gate, a.reason, NOW()
  FROM doc_type_catalog d
  CROSS JOIN LATERAL (SELECT v_k.access_tier = ANY(d.applicable_tiers) AS tier_ok) t
  CROSS JOIN LATERAL (SELECT
     t.tier_ok AND CASE d.requirement
       WHEN 'mandatory'   THEN d.min_risk_class IS NULL OR _risk_rank(v_k.risk_class) >= _risk_rank(d.min_risk_class)
       WHEN 'conditional' THEN COALESCE((v_k.premob_questionnaire ->> d.condition_key)::BOOLEAN, FALSE)
                               OR (d.min_risk_class IS NOT NULL AND _risk_rank(v_k.risk_class) >= _risk_rank(d.min_risk_class))
       WHEN 'optional'    THEN TRUE END AS applicable,
     CASE
       WHEN NOT t.tier_ok THEN 'not_applicable_tier:' || v_k.access_tier
       WHEN d.requirement = 'mandatory' THEN 'mandatory'
       WHEN d.requirement = 'conditional' THEN concat_ws(' / ',
                                 CASE WHEN COALESCE((v_k.premob_questionnaire ->> d.condition_key)::BOOLEAN, FALSE) THEN d.condition_key END,
                                 CASE WHEN d.min_risk_class IS NOT NULL AND _risk_rank(v_k.risk_class) >= _risk_rank(d.min_risk_class)
                                      THEN 'risk ≥ ' || d.min_risk_class END)
       ELSE 'optional' END AS reason) a
  WHERE d.active AND 'contract' = ANY(d.allowed_scopes) AND d.requirement IN ('mandatory','conditional','optional')
  ON CONFLICT (contract_id, doc_type_code) DO UPDATE SET applicable = EXCLUDED.applicable, is_mandatory = EXCLUDED.is_mandatory,
    is_mob_gate = EXCLUDED.is_mob_gate, reason = EXCLUDED.reason, computed_at = NOW();
END $$;

-- Dokumen wajib untuk kontrak ini? (gate MOBCHK/DMBCHK hanya bila berlaku — R32)
CREATE OR REPLACE FUNCTION _doc_required(p_contract UUID, p_code TEXT) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT COALESCE((SELECT applicable FROM contract_requirements WHERE contract_id = p_contract AND doc_type_code = p_code), FALSE)
$$;

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
    WHERE _doc_required(p_contract, 'DMBCHK')
      AND NOT _doc_satisfied((SELECT contractor_id FROM contracts WHERE id = p_contract), p_contract, NULL, 'DMBCHK');
END $$;

CREATE OR REPLACE FUNCTION request_go_live(p_contract UUID) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_access('contract.golive.request', p_contract); v_k contracts;
BEGIN
  SELECT * INTO v_k FROM contracts WHERE id = p_contract FOR UPDATE;
  IF v_k.status <> 'mobilization' THEN RAISE EXCEPTION 'Kontrak tidak dalam mobilisasi' USING ERRCODE = '22023'; END IF;
  IF _doc_required(p_contract, 'MOBCHK') AND NOT _doc_satisfied(v_k.contractor_id, p_contract, NULL, 'MOBCHK') THEN
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
  IF _doc_required(p_contract, 'MOBCHK') AND NOT _doc_satisfied(v_k.contractor_id, p_contract, NULL, 'MOBCHK') THEN
    RAISE EXCEPTION 'Checklist mobilisasi belum approved' USING ERRCODE = '22023'; END IF;
  UPDATE contracts SET status = 'active', golive_approved_at = NOW(), golive_approved_by = v_uid, updated_at = NOW() WHERE id = p_contract;
  PERFORM _notify_contractor(v_k.contractor_id, 'golive', 'Go-Live disetujui: ' || v_k.contract_no, v_reason, '/contracts/' || p_contract,
                             'info', 4004, jsonb_build_object('contract_no', v_k.contract_no), 'golive:' || p_contract);
  PERFORM _bot_contract(p_contract, 'system', '✅ Go-Live disetujui — kontrak ACTIVE', 'important');
END $$;

-- MONRPT hanya untuk tier yang mewajibkannya
CREATE OR REPLACE FUNCTION svc_monthly_reports() RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE r RECORD; v_today DATE; v_period TEXT; v_due DATE; v_new UUID; v_n INT := 0;
        v_tiers access_tier[] := COALESCE((SELECT applicable_tiers FROM doc_type_catalog WHERE code = 'MONRPT' AND active), '{}');
BEGIN
  FOR r IN SELECT * FROM contracts WHERE status IN ('active','demobilization') AND golive_approved_at IS NOT NULL
                                     AND access_tier = ANY(v_tiers) LOOP
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

-- ═════════════ GUARD KONTRAK (R32/R33/R34) ═════════════
CREATE OR REPLACE FUNCTION _contracts_mode_guard() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_tier access_tier := resolve_access_tier(NEW.contract_mode, NEW.end_date - NEW.start_date);
        v_q JSONB := COALESCE(NEW.premob_questionnaire, '{}'::jsonb);
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.contract_mode IS DISTINCT FROM OLD.contract_mode
     AND OLD.status NOT IN ('awarded','post_award') AND auth.uid() IS NOT NULL THEN
    RAISE EXCEPTION 'Mode kontrak hanya bisa diubah sebelum pre-mobilization; setelahnya wajib Management of Change'
      USING ERRCODE = '42501', HINT = 'use_moc';
  END IF;
  IF NEW.contract_mode = 'mode_3' AND length(btrim(COALESCE(NEW.hse_oversight_notes, ''))) < 20 THEN
    RAISE EXCEPTION 'Mode 3 wajib catatan HSE oversight (minimal 20 karakter)' USING ERRCODE = '22023';
  END IF;
  IF TG_OP = 'INSERT' OR NEW.contract_mode IS DISTINCT FROM OLD.contract_mode OR NEW.end_date IS DISTINCT FROM OLD.end_date
     OR NEW.start_date IS DISTINCT FROM OLD.start_date OR NEW.premob_questionnaire IS DISTINCT FROM OLD.premob_questionnaire THEN
    IF NEW.contract_mode = 'mode_3' AND v_q -> 'has_subcontractor' = 'true'::jsonb THEN
      RAISE EXCEPTION 'Kontrak Mode 3 tidak boleh memakai subcontractor' USING ERRCODE = '22023';
    END IF;
    IF TG_OP = 'UPDATE' AND NEW.contract_mode = 'mode_3'
       AND EXISTS (SELECT 1 FROM subcontractors WHERE contract_id = NEW.id AND status IN ('pending','approved')) THEN
      RAISE EXCEPTION 'Kontrak masih memiliki subcontractor aktif — Mode 3 tidak boleh memakai subcontractor' USING ERRCODE = '22023';
    END IF;
    IF v_tier = 'visitor' AND EXISTS (SELECT 1 FROM unnest(ARRAY['has_confined_space','has_hot_work','has_work_at_height','has_chemicals']) k
                                      WHERE v_q -> k = 'true'::jsonb) THEN
      RAISE EXCEPTION 'Kategori visitor (Mode 3 · ≤ 90 hari) tidak boleh mencakup pekerjaan berisiko tinggi — ubah mode atau durasi'
        USING ERRCODE = '22023';
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_contracts_mode_guard ON contracts;
CREATE TRIGGER trg_contracts_mode_guard BEFORE INSERT OR UPDATE ON contracts FOR EACH ROW EXECUTE FUNCTION _contracts_mode_guard();

CREATE OR REPLACE FUNCTION _contract_entered_phases(p_status contract_status) RETURNS lifecycle_phase[] LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_status
    WHEN 'awarded' THEN '{post_award}' WHEN 'post_award' THEN '{post_award}'
    WHEN 'pre_mobilization' THEN '{post_award,pre_mobilization}'
    WHEN 'mobilization' THEN '{post_award,pre_mobilization,mobilization}'
    WHEN 'active' THEN '{post_award,pre_mobilization,mobilization}'
    WHEN 'demobilization' THEN '{post_award,pre_mobilization,mobilization,demobilization}'
    WHEN 'final_evaluation' THEN '{post_award,pre_mobilization,mobilization,demobilization,final_evaluation}'
    ELSE '{}' END::lifecycle_phase[]
$$;

-- Tier berubah (mode diubah / end_date diperpanjang): hitung ulang requirement, batalkan task yang tidak berlaku lagi,
-- lengkapi task untuk fase yang sudah dilewati.
CREATE OR REPLACE FUNCTION _contracts_tier_changed() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_ph lifecycle_phase; v_cancel INT;
BEGIN
  IF NEW.status IN ('closed','terminated') THEN RETURN NULL; END IF;
  PERFORM build_contract_requirements(NEW.id);
  UPDATE tasks t SET status = 'cancelled', status_reason = 'Tidak berlaku untuk kategori ' || NEW.access_tier, updated_at = NOW()
  FROM doc_type_catalog d
  WHERE t.contract_id = NEW.id AND t.scope = 'contract' AND t.status IN ('open','file_issue') AND d.code = t.doc_type_code
    AND d.requirement IN ('mandatory','conditional','optional','recurring') AND NOT (NEW.access_tier = ANY(d.applicable_tiers));
  GET DIAGNOSTICS v_cancel = ROW_COUNT;
  FOREACH v_ph IN ARRAY _contract_entered_phases(COALESCE(NEW.status_before_hold, NEW.status)) LOOP
    PERFORM generate_contract_tasks(NEW.id, v_ph);
  END LOOP;
  PERFORM _bot_contract(NEW.id, 'system', 'Kategori kontrak: ' || OLD.access_tier || ' → ' || NEW.access_tier
          || CASE WHEN v_cancel > 0 THEN ' · ' || v_cancel || ' task tidak berlaku dibatalkan' ELSE '' END, 'important');
  PERFORM _notify_contractor(NEW.contractor_id, 'contract_tier', 'Kategori ' || NEW.contract_no || ': ' || upper(NEW.access_tier::TEXT),
          'Daftar dokumen wajib menyesuaikan kategori baru', '/contracts/' || NEW.id, 'info', NULL, '{}'::jsonb,
          'tier:' || NEW.id || ':' || NEW.access_tier);
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_contracts_tier_changed ON contracts;
CREATE TRIGGER trg_contracts_tier_changed AFTER UPDATE ON contracts
  FOR EACH ROW WHEN (OLD.access_tier IS DISTINCT FROM NEW.access_tier) EXECUTE FUNCTION _contracts_tier_changed();

-- Subcontractor: dilarang untuk Mode 3 (R32)
CREATE OR REPLACE FUNCTION _subcontractors_mode_guard() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
BEGIN
  IF (SELECT contract_mode FROM contracts WHERE id = NEW.contract_id) = 'mode_3' THEN
    RAISE EXCEPTION 'Kontrak Mode 3 tidak boleh memakai subcontractor' USING ERRCODE = '22023';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_subcontractors_mode_guard ON subcontractors;
CREATE TRIGGER trg_subcontractors_mode_guard BEFORE INSERT ON subcontractors FOR EACH ROW EXECUTE FUNCTION _subcontractors_mode_guard();

-- SLA review mengikuti tier (diambil yang lebih ketat dari SLA dokumen & SLA tier)
CREATE OR REPLACE FUNCTION _tasks_tier_sla() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_tier access_tier; v_gz TEXT;
BEGIN
  IF NEW.review_due_at IS NOT NULL AND NEW.contract_id IS NOT NULL
     AND (TG_OP = 'INSERT' OR NEW.review_due_at IS DISTINCT FROM OLD.review_due_at) THEN
    SELECT access_tier, geozone INTO v_tier, v_gz FROM contracts WHERE id = NEW.contract_id;
    NEW.review_due_at := LEAST(NEW.review_due_at, _business_deadline(_tier_review_sla(v_tier), v_gz));
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_tasks_tier_sla ON tasks;
CREATE TRIGGER trg_tasks_tier_sla BEFORE INSERT OR UPDATE OF review_due_at ON tasks FOR EACH ROW EXECUTE FUNCTION _tasks_tier_sla();

-- ═════════════ LEVEL USER CONTRACTOR ═════════════
CREATE TABLE IF NOT EXISTS contractor_users (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  contractor_id UUID NOT NULL REFERENCES contractors(id) ON DELETE CASCADE,
  user_id       UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  user_level    contractor_user_level NOT NULL,
  job_title     TEXT CHECK (length(job_title) <= 120),
  department    TEXT CHECK (length(department) <= 120),
  employee_no   TEXT CHECK (length(employee_no) <= 60),
  join_date     DATE,
  exit_date     DATE,
  verified_by   UUID REFERENCES profiles(id),
  verified_at   TIMESTAMPTZ,
  is_active     BOOLEAN NOT NULL DEFAULT TRUE,
  created_by    UUID REFERENCES profiles(id),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (contractor_id, user_id),
  CHECK (exit_date IS NULL OR join_date IS NULL OR exit_date >= join_date)
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_contractor_users_active_user ON contractor_users (user_id) WHERE is_active;
CREATE INDEX IF NOT EXISTS idx_contractor_users_contractor ON contractor_users (contractor_id) WHERE is_active;
-- Tanpa GRANT ke authenticated: dibaca/ditulis hanya lewat RPC (my_session_state, list_contractor_users, admin_*)
ALTER TABLE contractor_users ENABLE ROW LEVEL SECURITY;
COMMENT ON TABLE contractor_users IS 'Level user contractor (PIC/Supervisor/Employee) — RPC-only';
DROP TRIGGER IF EXISTS trg_updated_at ON contractor_users;
CREATE TRIGGER trg_updated_at BEFORE UPDATE ON contractor_users FOR EACH ROW EXECUTE FUNCTION _touch_updated_at();
DROP TRIGGER IF EXISTS trg_audit ON contractor_users;
CREATE TRIGGER trg_audit AFTER INSERT OR UPDATE OR DELETE ON contractor_users FOR EACH ROW EXECUTE FUNCTION log_change('id');

-- Backfill: perilaku lama dipertahankan (contractor_rep = PIC, lainnya employee)
INSERT INTO contractor_users (contractor_id, user_id, user_level, verified_at)
SELECT p.contractor_id, p.id,
       CASE WHEN EXISTS (SELECT 1 FROM user_roles ur JOIN roles r ON r.id = ur.role_id
                         WHERE ur.user_id = p.id AND r.key = 'contractor_rep') THEN 'pic' ELSE 'employee' END::contractor_user_level,
       NOW()
FROM profiles p
WHERE p.contractor_id IS NOT NULL AND p.anonymized_at IS NULL
ON CONFLICT (contractor_id, user_id) DO NOTHING;

-- Level efektif: hanya baris aktif untuk perusahaan user saat ini; tanpa baris = employee (paling terbatas). WFRD = NULL.
CREATE OR REPLACE FUNCTION _contractor_level_of(p_uid UUID DEFAULT auth.uid()) RETURNS contractor_user_level
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
  SELECT CASE WHEN p.contractor_id IS NULL THEN NULL
              ELSE COALESCE((SELECT cu.user_level FROM contractor_users cu
                             WHERE cu.user_id = p.id AND cu.contractor_id = p.contractor_id AND cu.is_active), 'employee') END
  FROM profiles p WHERE p.id = p_uid
$$;

CREATE OR REPLACE FUNCTION _assert_level(p_min contractor_user_level, p_msg TEXT DEFAULT NULL) RETURNS VOID
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_lvl contractor_user_level;
BEGIN
  IF auth.uid() IS NULL THEN PERFORM _deny('unauthenticated', 'Tidak terautentikasi'); END IF;
  v_lvl := _contractor_level_of(auth.uid());
  IF v_lvl IS NULL THEN RETURN; END IF;                                  -- user WFRD
  IF _level_rank(v_lvl) < _level_rank(p_min) THEN
    PERFORM _deny('insufficient_level', COALESCE(p_msg, 'Aksi ini membutuhkan level ' || upper(p_min::TEXT) || ' (level Anda: ' || upper(v_lvl::TEXT) || ')'));
  END IF;
END $$;
COMMENT ON FUNCTION _assert_level IS 'PIC > Supervisor > Employee. WFRD selalu lolos.';

-- Perusahaan user berubah → level di perusahaan lama tidak berlaku lagi
CREATE OR REPLACE FUNCTION _profiles_contractor_level() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
BEGIN
  UPDATE contractor_users SET is_active = FALSE
  WHERE user_id = NEW.id AND is_active AND contractor_id IS DISTINCT FROM NEW.contractor_id;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_profiles_contractor_level ON profiles;
CREATE TRIGGER trg_profiles_contractor_level AFTER UPDATE OF contractor_id ON profiles
  FOR EACH ROW WHEN (OLD.contractor_id IS DISTINCT FROM NEW.contractor_id) EXECUTE FUNCTION _profiles_contractor_level();

CREATE OR REPLACE FUNCTION _upsert_contractor_level(p_user UUID, p_contractor UUID, p_level contractor_user_level, p_by UUID)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_id UUID;
BEGIN
  UPDATE contractor_users SET is_active = FALSE WHERE user_id = p_user AND is_active AND contractor_id <> p_contractor;
  INSERT INTO contractor_users (contractor_id, user_id, user_level, verified_by, verified_at, created_by)
  VALUES (p_contractor, p_user, p_level, p_by, NOW(), p_by)
  ON CONFLICT (contractor_id, user_id) DO UPDATE SET user_level = EXCLUDED.user_level, is_active = TRUE,
    verified_by = EXCLUDED.verified_by, verified_at = NOW()
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- Undangan diterima → level dari undangan (hanya bila perusahaan undangan = perusahaan user)
ALTER TABLE user_invites ADD COLUMN IF NOT EXISTS contractor_level contractor_user_level;
CREATE OR REPLACE FUNCTION _user_invites_level() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
BEGIN
  IF NEW.contractor_id IS NOT NULL AND NEW.accepted_by IS NOT NULL
     AND EXISTS (SELECT 1 FROM profiles WHERE id = NEW.accepted_by AND contractor_id = NEW.contractor_id) THEN
    PERFORM _upsert_contractor_level(NEW.accepted_by, NEW.contractor_id, COALESCE(NEW.contractor_level, 'employee'), NEW.invited_by);
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS trg_user_invites_level ON user_invites;
CREATE TRIGGER trg_user_invites_level AFTER UPDATE OF accepted_at ON user_invites
  FOR EACH ROW WHEN (OLD.accepted_at IS NULL AND NEW.accepted_at IS NOT NULL) EXECUTE FUNCTION _user_invites_level();

-- Tulis data operasional tertentu: Supervisor ke atas (matriks 27.2: manning, subcontractor; + questionnaire pre-mob)
CREATE OR REPLACE FUNCTION _contractor_level_guard() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
BEGIN
  IF auth.uid() IS NOT NULL AND auth_contractor_id() IS NOT NULL THEN
    PERFORM _assert_level(TG_ARGV[0]::contractor_user_level, TG_ARGV[1]);
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_level_guard ON manning;
CREATE TRIGGER trg_level_guard BEFORE INSERT OR UPDATE ON manning FOR EACH ROW
  EXECUTE FUNCTION _contractor_level_guard('supervisor', 'Data manning hanya bisa diubah PIC / Supervisor');
DROP TRIGGER IF EXISTS trg_level_guard ON subcontractors;
CREATE TRIGGER trg_level_guard BEFORE INSERT OR UPDATE ON subcontractors FOR EACH ROW
  EXECUTE FUNCTION _contractor_level_guard('supervisor', 'Subcontractor hanya bisa diajukan PIC / Supervisor');
DROP TRIGGER IF EXISTS trg_level_guard ON contracts;
CREATE TRIGGER trg_level_guard BEFORE UPDATE OF premob_questionnaire ON contracts FOR EACH ROW
  WHEN (OLD.premob_questionnaire IS DISTINCT FROM NEW.premob_questionnaire)
  EXECUTE FUNCTION _contractor_level_guard('supervisor', 'Questionnaire pre-mobilization hanya bisa diisi PIC / Supervisor');

-- assert_access: + level minimum per permission untuk user contractor
CREATE OR REPLACE FUNCTION assert_access(
  p_perm       TEXT,
  p_contract   UUID    DEFAULT NULL,
  p_write      BOOLEAN DEFAULT TRUE,
  p_contractor UUID    DEFAULT NULL,
  p_geozone    TEXT    DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_uid UUID := auth.uid(); v_status account_status; v_cid UUID; v_ds TEXT; v_risk TEXT; v_ok BOOLEAN; v_owner UUID;
  v_min contractor_user_level; v_lvl contractor_user_level;
BEGIN
  IF v_uid IS NULL THEN PERFORM _deny('unauthenticated', 'Tidak terautentikasi'); END IF;

  SELECT status, contractor_id INTO v_status, v_cid FROM profiles WHERE id = v_uid;
  IF v_status IS DISTINCT FROM 'active' THEN PERFORM _deny('account_inactive', 'Akun tidak aktif'); END IF;

  v_ds := device_state();
  IF v_ds <> 'ok' THEN PERFORM _deny(_device_hint(v_ds), 'Perangkat atau sesi tidak valid'); END IF;

  IF user_requires_mfa(v_uid) AND auth_aal() <> 'aal2' THEN PERFORM _deny('mfa_required', 'Verifikasi MFA diperlukan'); END IF;

  SELECT risk_level INTO v_risk FROM permissions WHERE key = p_perm;
  IF v_risk IS NULL THEN RAISE EXCEPTION 'Permission tidak dikenal: %', p_perm USING ERRCODE = 'XX000'; END IF;
  IF (v_risk = 'critical' OR p_perm LIKE 'admin.%') AND auth_aal() <> 'aal2' THEN
    PERFORM _deny('mfa_required', 'Aksi ini membutuhkan MFA');
  END IF;

  v_ok := CASE
    WHEN p_contract   IS NOT NULL THEN has_contract_permission(p_perm, p_contract)
    WHEN p_contractor IS NOT NULL THEN has_contractor_permission(p_perm, p_contractor)
    WHEN p_geozone    IS NOT NULL THEN _has_geozone_permission(p_perm, p_geozone)
    ELSE has_permission(p_perm) END;
  IF NOT v_ok THEN PERFORM _deny('forbidden'); END IF;

  IF v_cid IS NOT NULL THEN                                   -- user contractor: objek wajib milik perusahaannya
    IF p_contract IS NOT NULL THEN
      SELECT contractor_id INTO v_owner FROM contracts WHERE id = p_contract;
      IF v_owner IS DISTINCT FROM v_cid THEN PERFORM _deny('forbidden'); END IF;
    END IF;
    IF p_contractor IS NOT NULL AND p_contractor IS DISTINCT FROM v_cid THEN PERFORM _deny('forbidden'); END IF;
    v_min := _perm_min_level(p_perm);
    IF v_min IS NOT NULL THEN
      v_lvl := _contractor_level_of(v_uid);
      IF _level_rank(v_lvl) < _level_rank(v_min) THEN
        PERFORM _deny('insufficient_level', 'Aksi ini khusus level ' || upper(v_min::TEXT) || ' perusahaan (level Anda: ' || upper(v_lvl::TEXT) || ')');
      END IF;
    END IF;
  END IF;

  IF p_write AND _setting_bool('read_only_mode', FALSE) AND NOT has_permission('admin.system.danger') THEN
    PERFORM _deny('read_only', 'Sistem dalam mode read-only');
  END IF;
  RETURN v_uid;
END $$;

-- Konfirmasi task: dokumen/evidence = Supervisor+; kontrak visitor hanya checklist/action + task ad-hoc (R33)
CREATE OR REPLACE FUNCTION _task_confirm_block(v_t tasks, p_uid UUID) RETURNS TEXT
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_lvl contractor_user_level := _contractor_level_of(p_uid);
BEGIN
  IF v_lvl IS NULL THEN RETURN NULL; END IF;
  IF v_t.kind IN ('document','evidence') AND _level_rank(v_lvl) < _level_rank('supervisor') THEN
    RETURN 'Hanya PIC dan Supervisor yang bisa konfirmasi upload dokumen/evidence';
  END IF;
  IF v_t.contract_id IS NOT NULL AND v_t.kind IN ('document','evidence','form')
     AND (SELECT access_tier FROM contracts WHERE id = v_t.contract_id) = 'visitor'
     AND (SELECT requirement FROM doc_type_catalog WHERE code = v_t.doc_type_code) IS DISTINCT FROM 'adhoc' THEN
    RETURN 'Kontrak kategori visitor tidak menerima submission dokumen/form';
  END IF;
  RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION _assert_task_perm(p_perm TEXT, v_t tasks, p_write BOOLEAN DEFAULT TRUE) RETURNS UUID
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID; v_block TEXT;
BEGIN
  IF v_t.contract_id IS NOT NULL THEN v_uid := assert_access(p_perm, v_t.contract_id, p_write);
  ELSE v_uid := assert_access(p_perm, NULL, p_write, v_t.contractor_id); END IF;
  IF p_perm = 'task.confirm_upload' AND p_write THEN
    v_block := _task_confirm_block(v_t, v_uid);
    IF v_block IS NOT NULL THEN PERFORM _deny('insufficient_level', v_block); END IF;
  END IF;
  RETURN v_uid;
END $$;

CREATE OR REPLACE FUNCTION get_task_detail(p_task UUID) RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_session(FALSE); v_t tasks; v_l upload_links; v_d doc_type_catalog; v_block TEXT; v_own BOOLEAN;
BEGIN
  IF NOT can_view_task(p_task) THEN PERFORM _deny('forbidden'); END IF;
  SELECT * INTO v_t FROM tasks WHERE id = p_task;
  SELECT * INTO v_d FROM doc_type_catalog WHERE code = v_t.doc_type_code;
  SELECT * INTO v_l FROM upload_links WHERE id = resolve_upload_link(p_task);
  v_own := COALESCE(v_t.contractor_id = auth_contractor_id(), FALSE) AND has_permission('task.confirm_upload');
  v_block := CASE WHEN v_own THEN _task_confirm_block(v_t, v_uid) END;
  RETURN jsonb_build_object(
    'task', to_jsonb(v_t) - 'confirm_code' || jsonb_build_object('confirm_code',
             CASE WHEN v_t.status = 'awaiting_email' OR auth_is_wfrd() THEN v_t.confirm_code END),
    'doc', jsonb_build_object('label', v_d.label, 'kind', v_d.kind, 'requires_email', v_d.requires_email,
                              'requires_expiry', v_d.requires_expiry, 'requires_fingerprint', v_d.requires_fingerprint,
                              'sensitive', v_d.sensitive, 'review_sla_days', v_d.review_sla_days),
    'link', CASE WHEN v_l.id IS NULL THEN NULL ELSE jsonb_build_object('id', v_l.id, 'url', v_l.url, 'label', v_l.label,
              'link_type', v_l.link_type, 'scope_type', v_l.scope_type,
              'personal', v_l.url ~* '^https://(1drv\.ms|onedrive\.live\.com)/') END,
    'contract', (SELECT jsonb_build_object('id', id, 'contract_no', contract_no, 'title', title, 'status', status,
                        'contract_mode', contract_mode, 'duration_category', duration_category, 'duration_days', duration_days,
                        'access_tier', access_tier) FROM contracts WHERE id = v_t.contract_id),
    'contractor', (SELECT jsonb_build_object('id', id, 'legal_name', legal_name, 'vendor_ref', 'CMN-V' || lpad(vendor_seq::TEXT, 5, '0'))
                   FROM contractors WHERE id = v_t.contractor_id),
    'checklist', (SELECT COALESCE(jsonb_agg(to_jsonb(ci) ORDER BY ci.item_no), '[]'::jsonb) FROM checklist_items ci WHERE ci.task_id = p_task),
    'events', (SELECT COALESCE(jsonb_agg(jsonb_build_object('event', e.event, 'at', e.created_at, 'actor', e.actor_id, 'payload', e.payload)
                       ORDER BY e.created_at), '[]'::jsonb) FROM task_events e WHERE e.task_id = p_task),
    'revisions', (SELECT COALESCE(jsonb_agg(jsonb_build_object('id', id, 'task_id', task_id, 'status', status) ORDER BY revision), '[]'::jsonb)
                  FROM tasks WHERE base_task_id = v_t.base_task_id),
    'can_review', auth_is_wfrd() AND has_any_permission('task.review') AND _can_review_task(v_uid, v_t),
    'can_confirm', v_own AND v_block IS NULL,
    'confirm_block_reason', v_block,
    'my_level', _contractor_level_of(v_uid));
END $$;

-- ═════════════ SESI ═════════════
CREATE OR REPLACE FUNCTION my_session_state() RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := auth.uid(); v_p profiles; v_c contractors; v_active BOOLEAN; v_lvl contractor_user_level; v_contracts JSONB;
BEGIN
  IF v_uid IS NULL THEN PERFORM _deny('unauthenticated', 'Tidak terautentikasi'); END IF;
  SELECT * INTO v_p FROM profiles WHERE id = v_uid;
  IF NOT FOUND THEN PERFORM _deny('account_inactive', 'Profil belum tersedia'); END IF;
  SELECT * INTO v_c FROM contractors WHERE id = v_p.contractor_id;
  v_active := v_p.status = 'active';
  v_lvl := _contractor_level_of(v_uid);
  v_contracts := CASE WHEN v_active AND v_p.contractor_id IS NOT NULL THEN COALESCE((
      SELECT jsonb_agg(jsonb_build_object('id', k.id, 'contract_no', k.contract_no, 'title', k.title, 'status', k.status,
                                          'contract_mode', k.contract_mode, 'duration_category', k.duration_category,
                                          'access_tier', k.access_tier) ORDER BY k.contract_no DESC)
      FROM contracts k WHERE k.contractor_id = v_p.contractor_id AND k.status NOT IN ('closed','terminated')), '[]'::jsonb)
    ELSE '[]'::jsonb END;
  RETURN jsonb_build_object(
    'user_id', v_p.id, 'email', v_p.email, 'full_name', v_p.full_name, 'avatar_url', v_p.avatar_url,
    'status', v_p.status, 'status_reason', v_p.status_reason, 'is_root_admin', v_p.is_root_admin,
    'is_wfrd', v_active AND v_p.contractor_id IS NULL,
    'contractor_id', v_p.contractor_id, 'contractor_name', v_c.legal_name, 'vendor_status', v_c.status,
    'registration_submitted', v_c.submitted_at IS NOT NULL, 'locale', v_p.locale,
    'contractor_level', v_lvl,
    'active_contracts', v_contracts,
    'roles', CASE WHEN v_active THEN COALESCE((
        SELECT jsonb_agg(jsonb_build_object('id', ur.id, 'key', r.key, 'name', r.name, 'scope_type', ur.scope_type,
                                            'scope_id', ur.scope_id, 'expires_at', ur.expires_at) ORDER BY r.key)
        FROM user_roles ur JOIN roles r ON r.id = ur.role_id
        WHERE ur.user_id = v_uid AND (ur.expires_at IS NULL OR ur.expires_at > NOW())), '[]'::jsonb) ELSE '[]'::jsonb END,
    'permissions', CASE WHEN v_active THEN COALESCE((
        SELECT jsonb_agg(DISTINCT pm.key ORDER BY pm.key) FROM permissions pm
        WHERE pm.key <> '*' AND EXISTS (SELECT 1 FROM _perm_grants(v_uid, pm.key))
          AND (v_lvl IS NULL OR _perm_min_level(pm.key) IS NULL OR _level_rank(v_lvl) >= _level_rank(_perm_min_level(pm.key)))), '[]'::jsonb)
        ELSE '[]'::jsonb END,
    'global_permissions', CASE WHEN v_active THEN COALESCE((
        SELECT jsonb_agg(DISTINCT pm.key ORDER BY pm.key) FROM permissions pm
        WHERE pm.key <> '*' AND EXISTS (SELECT 1 FROM _perm_grants(v_uid, pm.key) g WHERE g.scope_type = 'global')
          AND (v_lvl IS NULL OR _perm_min_level(pm.key) IS NULL OR _level_rank(v_lvl) >= _level_rank(_perm_min_level(pm.key)))), '[]'::jsonb)
        ELSE '[]'::jsonb END,
    'mfa_required', user_requires_mfa(v_uid),
    'mfa_enrolled', EXISTS (SELECT 1 FROM auth.mfa_factors f WHERE f.user_id = v_uid AND f.status = 'verified' AND f.factor_type = 'totp'),
    'aal', auth_aal(),
    'step_up_fresh', mfa_fresh(_setting_int('step_up_hours', 12)),
    'device_state', device_state(),
    'read_only_mode', _setting_bool('read_only_mode', FALSE),
    'email_otp_enabled', _setting_bool('email_otp_enabled', TRUE),
    'unread_notifications', (SELECT count(*) FROM notifications WHERE user_id = v_uid AND read_at IS NULL)
  );
END $$;

-- ═════════════ PERMISSION BARU ═════════════
INSERT INTO permissions (key, module, description, risk_level, audience) VALUES
  ('level.pic.set', 'admin', 'Menetapkan / mencabut level PIC user contractor', 'high', 'wfrd')
ON CONFLICT (key) DO NOTHING;
INSERT INTO role_permissions (role_id, permission_key)
SELECT id, 'level.pic.set' FROM roles WHERE key = 'hse_admin'
ON CONFLICT DO NOTHING;

-- ═════════════ RPC: KONTRAK ═════════════
DROP FUNCTION IF EXISTS create_contract(UUID, TEXT, TEXT, TEXT, TEXT, TEXT, DATE, DATE, DATE, DATE, UUID, UUID, TEXT);
CREATE OR REPLACE FUNCTION create_contract(p_contractor UUID, p_title TEXT, p_scope_of_work TEXT, p_geozone TEXT, p_site TEXT,
  p_risk_class TEXT, p_start DATE, p_end DATE, p_target_mob DATE, p_awarded_at DATE, p_process_owner UUID, p_hse_reviewer UUID,
  p_review_mailbox TEXT, p_contract_mode contract_mode DEFAULT 'mode_1', p_hse_oversight_notes TEXT DEFAULT NULL) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_access('contract.create', NULL, TRUE, NULL, p_geozone); v_c contractors; v_gz geozones; v_id UUID; v_no TEXT;
        v_mode contract_mode := COALESCE(p_contract_mode, 'mode_1'); v_notes TEXT := _clean_text(p_hse_oversight_notes, 2000);
        v_tier access_tier;
BEGIN
  SELECT * INTO v_c FROM contractors WHERE id = p_contractor;
  IF NOT FOUND OR v_c.status NOT IN ('asl_approved','asl_conditional') OR v_c.asl_expires_on < CURRENT_DATE THEN
    RAISE EXCEPTION 'Kontrak hanya untuk vendor dengan ASL aktif' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO v_gz FROM geozones WHERE code = p_geozone AND active;
  IF NOT FOUND THEN RAISE EXCEPTION 'Geozone tidak valid' USING ERRCODE = '22023'; END IF;
  IF p_risk_class NOT IN ('low','medium','high') THEN RAISE EXCEPTION 'Kelas risiko tidak valid' USING ERRCODE = '22023'; END IF;
  IF p_start IS NULL OR p_end IS NULL OR p_end < p_start THEN
    RAISE EXCEPTION 'Tanggal selesai harus sama atau setelah tanggal mulai' USING ERRCODE = '22023'; END IF;
  IF v_mode = 'mode_3' AND length(COALESCE(v_notes, '')) < 20 THEN
    RAISE EXCEPTION 'Mode 3 wajib catatan HSE oversight (minimal 20 karakter)' USING ERRCODE = '22023'; END IF;
  PERFORM _assert_contract_people(p_process_owner, p_hse_reviewer);

  INSERT INTO contracts (contractor_id, title, scope_of_work, geozone, site, risk_class, start_date, end_date, target_mob_date,
                         awarded_at, process_owner_id, hse_reviewer_id, review_mailbox, created_by, contract_mode, hse_oversight_notes)
  VALUES (p_contractor, _clean_text(p_title, 200, TRUE), _clean_text(p_scope_of_work, 8000), p_geozone, _clean_text(p_site, 200),
          p_risk_class, p_start, p_end, p_target_mob, COALESCE(p_awarded_at, CURRENT_DATE), p_process_owner, p_hse_reviewer,
          COALESCE(_clean_email(p_review_mailbox, FALSE), v_gz.review_mailbox), v_uid, v_mode, v_notes)
  RETURNING id, contract_no, access_tier INTO v_id, v_no, v_tier;

  PERFORM build_contract_requirements(v_id);
  PERFORM generate_contract_tasks(v_id, 'post_award');
  PERFORM _sync_contract_channel(v_id);
  PERFORM _notify_permission_holders('upload_link.manage', v_id, 'onedrive_setup', 'Siapkan folder OneDrive ' || v_no,
            'Buat folder kontrak & masukkan link', '/contracts/' || v_id || '/onedrive', 'warning', NULL, '{}'::jsonb, 'odsetup:' || v_id);
  PERFORM _notify_contractor(p_contractor, 'contract_awarded', 'Kontrak baru: ' || v_no, p_title, '/contracts/' || v_id, 'info', 4001,
                             jsonb_build_object('contract_no', v_no, 'title', p_title, 'access_tier', v_tier), 'awarded:' || v_id);
  PERFORM _bot_contract(v_id, 'system', 'Kontrak dibuat · ' || upper(replace(v_mode::TEXT, '_', ' ')) || ' · kategori ' || upper(v_tier::TEXT), 'normal');
  RETURN v_id;
END $$;

-- R34: mode hanya diubah sebelum pre-mobilization, oleh PO kontrak / HSE Director / Super Admin, dengan alasan
CREATE OR REPLACE FUNCTION change_contract_mode(p_contract UUID, p_mode contract_mode, p_notes TEXT, p_reason TEXT) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_access('contract.edit', p_contract); v_reason TEXT := _require_reason(p_reason);
        v_k contracts; v_new contracts; v_notes TEXT := _clean_text(p_notes, 2000);
BEGIN
  SELECT * INTO v_k FROM contracts WHERE id = p_contract FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Kontrak tidak ditemukan' USING ERRCODE = '22023'; END IF;
  IF v_uid <> v_k.process_owner_id AND NOT _user_has_role(v_uid, 'hse_director') AND NOT _user_has_role(v_uid, 'super_admin') THEN
    PERFORM _deny('forbidden', 'Mode kontrak hanya bisa diubah oleh PO kontrak ini atau HSE Director');
  END IF;
  IF v_k.status NOT IN ('awarded','post_award') THEN
    PERFORM _deny('use_moc', 'Mode kontrak hanya bisa diubah sebelum pre-mobilization; setelahnya wajib Management of Change');
  END IF;
  IF p_mode IS NULL THEN RAISE EXCEPTION 'Mode wajib dipilih' USING ERRCODE = '22023'; END IF;
  IF p_mode = v_k.contract_mode AND v_notes IS NOT DISTINCT FROM v_k.hse_oversight_notes THEN
    RAISE EXCEPTION 'Tidak ada perubahan' USING ERRCODE = '22023'; END IF;
  UPDATE contracts SET contract_mode = p_mode, hse_oversight_notes = v_notes, updated_at = NOW()
  WHERE id = p_contract RETURNING * INTO v_new;
  PERFORM _security_event(v_uid, 'contract_mode_changed', 'warning', jsonb_build_object('contract', p_contract,
          'from', v_k.contract_mode, 'to', p_mode, 'tier_from', v_k.access_tier, 'tier_to', v_new.access_tier, 'reason', v_reason));
  IF v_new.access_tier = v_k.access_tier THEN
    PERFORM _bot_contract(p_contract, 'system', 'Mode kontrak: ' || v_k.contract_mode || ' → ' || p_mode || ' · ' || v_reason, 'normal');
  END IF;
  RETURN jsonb_build_object('contract_mode', v_new.contract_mode, 'duration_category', v_new.duration_category,
                            'access_tier', v_new.access_tier);
END $$;

-- Ringkasan kontrak di detail contractor menyertakan klasifikasi v3.3
CREATE OR REPLACE FUNCTION get_contractor_detail(p_contractor UUID) RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_session(FALSE); v_c contractors; v_wfrd BOOLEAN := auth_is_wfrd(); v_vendor BOOLEAN; v_full BOOLEAN;
BEGIN
  IF NOT can_view_contractor(p_contractor) THEN PERFORM _deny('forbidden'); END IF;
  SELECT * INTO v_c FROM contractors WHERE id = p_contractor;
  v_vendor := v_wfrd AND has_contractor_permission('vendor.view', p_contractor);
  v_full := (NOT v_wfrd) OR v_vendor;
  RETURN (to_jsonb(v_c) - 'primary_contact_phone_enc' - 'enc_key_ver' - 'internal_notes') || jsonb_build_object(
    'vendor_ref', _vendor_ref(p_contractor),
    'primary_contact_phone', CASE WHEN v_full THEN _decrypt(v_c.primary_contact_phone_enc, 'data', v_c.enc_key_ver) END,
    'internal_notes', CASE WHEN v_vendor THEN v_c.internal_notes END,
    'self_assessments', CASE WHEN v_full THEN (
        SELECT COALESCE(jsonb_agg(jsonb_build_object('id', s.id, 'year', s.period_year, 'status', s.status, 'computed', s.computed,
                                                     'submitted_at', s.submitted_at) ORDER BY s.period_year DESC), '[]'::jsonb)
        FROM self_assessments s WHERE s.contractor_id = p_contractor) END,
    'evaluations', CASE WHEN v_vendor THEN (
        SELECT COALESCE(jsonb_agg(to_jsonb(e) ORDER BY e.screened_at DESC), '[]'::jsonb)
        FROM vendor_evaluations e WHERE e.contractor_id = p_contractor) END,
    'contracts', (SELECT COALESCE(jsonb_agg(jsonb_build_object('id', k.id, 'contract_no', k.contract_no, 'title', k.title,
                                  'status', k.status, 'health_flag', k.health_flag,
                                  'contract_mode', k.contract_mode, 'duration_category', k.duration_category, 'access_tier', k.access_tier) ORDER BY k.contract_seq DESC), '[]'::jsonb)
                  FROM contracts k WHERE k.contractor_id = p_contractor AND can_view_contract(k.id)),
    'can_manage', v_wfrd AND auth_aal() = 'aal2' AND has_permission('admin.contractors.manage'),
    'can_screen', v_wfrd AND has_contractor_permission('vendor.screen', p_contractor),
    'can_decide_asl', v_wfrd AND has_contractor_permission('vendor.asl.decide', p_contractor));
END $$;

-- Penugasan massal mengikuti tier kontrak (R29)
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
        IF NOT (v_k.access_tier = ANY(v_d.applicable_tiers))
           OR EXISTS (SELECT 1 FROM tasks WHERE contract_id = v_k.id AND scope = 'contract' AND doc_type_code = v_d.code AND status = ANY(v_open)) THEN
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

-- Katalog: applicable_tiers bisa diatur admin (key tidak dikirim = nilai lama dipertahankan)
CREATE OR REPLACE FUNCTION admin_upsert_doc_type(p_code TEXT, p_data JSONB, p_reason TEXT) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_access('admin.catalog.manage'); v_reason TEXT := _require_reason(p_reason); v_tiers access_tier[];
BEGIN
  IF p_code !~ '^[A-Z0-9]{6}$' THEN RAISE EXCEPTION 'Kode dokumen 6 karakter A-Z0-9' USING ERRCODE = '22023'; END IF;
  IF NOT EXISTS (SELECT 1 FROM roles WHERE key = p_data ->> 'reviewer_role' AND is_wfrd) THEN
    RAISE EXCEPTION 'reviewer_role harus role WFRD yang ada' USING ERRCODE = '22023';
  END IF;
  IF p_data ? 'applicable_tiers' THEN
    IF jsonb_typeof(p_data -> 'applicable_tiers') <> 'array' THEN RAISE EXCEPTION 'applicable_tiers harus array' USING ERRCODE = '22023'; END IF;
    v_tiers := ARRAY(SELECT DISTINCT jsonb_array_elements_text(p_data -> 'applicable_tiers'))::access_tier[];
    IF cardinality(v_tiers) = 0 THEN RAISE EXCEPTION 'Pilih minimal satu kategori kontrak' USING ERRCODE = '22023'; END IF;
  END IF;
  INSERT INTO doc_type_catalog (code, label, allowed_scopes, kind, phase, requirement, condition_key, min_risk_class,
    vendor_requirement, vendor_condition_key, subcon_required, reviewer_role, requires_email, requires_expiry,
    requires_fingerprint, sensitive, due_anchor, due_offset_days, review_sla_days, is_mob_gate, checklist_template, active, applicable_tiers)
  VALUES (p_code, _clean_text(p_data ->> 'label', 120, TRUE),
    ARRAY(SELECT jsonb_array_elements_text(p_data -> 'allowed_scopes'))::task_scope[],
    (p_data ->> 'kind')::task_kind, (p_data ->> 'phase')::lifecycle_phase, p_data ->> 'requirement', p_data ->> 'condition_key',
    p_data ->> 'min_risk_class', p_data ->> 'vendor_requirement', p_data ->> 'vendor_condition_key',
    COALESCE((p_data ->> 'subcon_required')::BOOLEAN, FALSE), p_data ->> 'reviewer_role',
    COALESCE((p_data ->> 'requires_email')::BOOLEAN, (p_data ->> 'kind') = 'document'),
    COALESCE((p_data ->> 'requires_expiry')::BOOLEAN, FALSE), COALESCE((p_data ->> 'requires_fingerprint')::BOOLEAN, FALSE),
    COALESCE((p_data ->> 'sensitive')::BOOLEAN, FALSE), p_data ->> 'due_anchor', (p_data ->> 'due_offset_days')::INT,
    COALESCE((p_data ->> 'review_sla_days')::INT, 3), COALESCE((p_data ->> 'is_mob_gate')::BOOLEAN, FALSE),
    p_data -> 'checklist_template', COALESCE((p_data ->> 'active')::BOOLEAN, TRUE), COALESCE(v_tiers, '{full}'))
  ON CONFLICT (code) DO UPDATE SET
    label = EXCLUDED.label, allowed_scopes = EXCLUDED.allowed_scopes, kind = EXCLUDED.kind, phase = EXCLUDED.phase,
    requirement = EXCLUDED.requirement, condition_key = EXCLUDED.condition_key, min_risk_class = EXCLUDED.min_risk_class,
    vendor_requirement = EXCLUDED.vendor_requirement, vendor_condition_key = EXCLUDED.vendor_condition_key,
    subcon_required = EXCLUDED.subcon_required, reviewer_role = EXCLUDED.reviewer_role, requires_email = EXCLUDED.requires_email,
    requires_expiry = EXCLUDED.requires_expiry, requires_fingerprint = EXCLUDED.requires_fingerprint, sensitive = EXCLUDED.sensitive,
    due_anchor = EXCLUDED.due_anchor, due_offset_days = EXCLUDED.due_offset_days, review_sla_days = EXCLUDED.review_sla_days,
    is_mob_gate = EXCLUDED.is_mob_gate, checklist_template = EXCLUDED.checklist_template, active = EXCLUDED.active,
    applicable_tiers = COALESCE(v_tiers, doc_type_catalog.applicable_tiers);
  PERFORM _security_event(v_uid, 'settings_changed', 'info', jsonb_build_object('key', 'doc_type', 'code', p_code, 'reason', v_reason));
END $$;

-- ═════════════ KPI: TARGET BBS PER TIER ═════════════
CREATE OR REPLACE FUNCTION _compute_kpi(p_contract UUID, p_month DATE, OUT metrics JSONB, OUT score NUMERIC, OUT color TEXT)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE
  v_end DATE := (date_trunc('month', p_month) + INTERVAL '1 month')::DATE;      -- eksklusif
  v_start DATE := (v_end - INTERVAL '12 months')::DATE;
  v_n NUMERIC := _setting_int('kpi_normalizer', 200000);
  v_tg JSONB := COALESCE(setting('kpi_targets'), '{}'::jsonb); v_w JSONB := COALESCE(setting('kpi_weights'), '{}'::jsonb);
  v_mh NUMERIC; v_km NUMERIC; v_rec INT; v_lti INT; v_pvi INT; v_hipo INT; v_fat INT;
  v_trir NUMERIC; v_ltir NUMERIC; v_pvir NUMERIC; s JSONB; v_bbs INT;
  v_bbs_target INT := _bbs_target_for_tier((SELECT access_tier FROM contracts WHERE id = p_contract));
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
    'bbs',            CASE WHEN COALESCE(v_bbs_target, 0) <= 0 THEN 100
                           ELSE LEAST(100, round(v_bbs * 100.0 / (4 * v_bbs_target), 2)) END,
    'finding_ontime', CASE WHEN v_f_tot = 0 THEN 100 ELSE round(v_f_ok * 100.0 / v_f_tot, 2) END,
    'training',       CASE WHEN v_m_tot = 0 THEN 100 ELSE round(v_m_ok * 100.0 / v_m_tot, 2) END,
    'stopwork',       LEAST(100, v_sw * 50),
    'task_ontime',    CASE WHEN v_t_tot = 0 THEN 100 ELSE round(v_t_ok * 100.0 / v_t_tot, 2) END,
    'monrpt_ontime',  CASE WHEN v_mr_tot = 0 THEN 100 ELSE round(v_mr_ok * 100.0 / v_mr_tot, 2) END,
    'audit',          COALESCE(round(v_audit, 2), 100));
  SELECT round(sum((s ->> k)::NUMERIC * COALESCE((v_w ->> k)::NUMERIC, 0)) / 100, 2) INTO score FROM jsonb_object_keys(s) k;
  color := CASE WHEN v_fat > 0 OR score < 70 THEN 'red' WHEN score < 85 THEN 'yellow' ELSE 'green' END;
  metrics := jsonb_build_object('man_hours', v_mh, 'km', v_km, 'recordables', v_rec, 'lti', v_lti, 'pvi', v_pvi, 'hipo', v_hipo,
               'fatality', v_fat, 'trir', v_trir, 'ltir', v_ltir, 'pvir', v_pvir, 'bbs_4w', v_bbs, 'bbs_weekly_target', v_bbs_target,
               'stopwork_90d', v_sw, 'components', s, 'window', jsonb_build_object('from', v_start, 'to', v_end));
END $$;

-- ═════════════ RPC: USER & LEVEL ═════════════
DROP FUNCTION IF EXISTS admin_approve_user(UUID, TEXT, TEXT, TEXT, UUID, TIMESTAMPTZ, TEXT);
CREATE OR REPLACE FUNCTION admin_approve_user(p_user UUID, p_role_key TEXT, p_scope_type TEXT, p_scope_id TEXT,
  p_contractor UUID, p_expires_at TIMESTAMPTZ, p_reason TEXT, p_contractor_level contractor_user_level DEFAULT NULL) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_access('admin.users.approve'); v_reason TEXT := _require_reason(p_reason);
        v_p profiles; v_role roles; v_cid UUID; v_st TEXT; v_sid TEXT;
BEGIN
  IF p_user = v_uid THEN PERFORM _deny('forbidden', 'Tidak bisa menyetujui akun sendiri'); END IF;
  SELECT * INTO v_p FROM profiles WHERE id = p_user FOR UPDATE;
  IF NOT FOUND OR v_p.status <> 'pending' THEN RAISE EXCEPTION 'User tidak dalam status pending' USING ERRCODE = '22023'; END IF;
  SELECT * INTO v_role FROM roles WHERE key = p_role_key;
  IF NOT FOUND THEN RAISE EXCEPTION 'Role tidak dikenal' USING ERRCODE = '22023'; END IF;
  PERFORM _assert_can_grant(v_role.id);
  IF _role_is_critical(v_role.id) THEN PERFORM assert_step_up(); END IF;

  IF v_role.is_wfrd THEN
    IF p_contractor IS NOT NULL THEN RAISE EXCEPTION 'Role WFRD tidak boleh terhubung ke contractor' USING ERRCODE = '22023'; END IF;
    IF p_contractor_level IS NOT NULL THEN RAISE EXCEPTION 'Level contractor hanya untuk role contractor' USING ERRCODE = '22023'; END IF;
    v_cid := NULL; v_st := COALESCE(p_scope_type, 'global'); v_sid := CASE WHEN v_st = 'global' THEN NULL ELSE p_scope_id END;
    PERFORM _validate_scope(v_st, v_sid);
  ELSE
    v_cid := COALESCE(p_contractor, v_p.contractor_id);
    IF v_cid IS NULL OR NOT EXISTS (SELECT 1 FROM contractors WHERE id = v_cid) THEN
      RAISE EXCEPTION 'Role contractor wajib memilih contractor' USING ERRCODE = '22023';
    END IF;
    IF p_contractor_level IS NULL THEN
      RAISE EXCEPTION 'Level user contractor (PIC / Supervisor / Employee) wajib dipilih' USING ERRCODE = '22023'; END IF;
    IF p_contractor_level = 'pic' AND NOT has_permission('level.pic.set') THEN
      PERFORM _deny('forbidden', 'Menetapkan level PIC membutuhkan permission level.pic.set'); END IF;
    v_st := 'global'; v_sid := NULL;
  END IF;

  UPDATE profiles SET status = 'active', status_reason = NULL, contractor_id = v_cid, approved_by = v_uid, approved_at = NOW()
  WHERE id = p_user;
  PERFORM _grant_role_internal(p_user, v_role.id, v_st, v_sid, p_expires_at, v_reason, v_uid);
  UPDATE user_invites SET accepted_at = NOW(), accepted_by = p_user
  WHERE email = v_p.email AND accepted_at IS NULL AND revoked_at IS NULL;
  IF v_cid IS NOT NULL THEN PERFORM _upsert_contractor_level(p_user, v_cid, p_contractor_level, v_uid); END IF;
  PERFORM _security_event(p_user, 'user_status', 'info', jsonb_build_object('status', 'active', 'by', v_uid, 'role', p_role_key,
                          'contractor_level', p_contractor_level));
  PERFORM _notify(p_user, 'account_approved', 'Akun Anda aktif',
                  'Selamat datang di COMEN.' || CASE WHEN p_contractor_level IS NOT NULL THEN ' Level: ' || upper(p_contractor_level::TEXT) || '.' ELSE '' END,
                  '/', 'info', 7003, jsonb_build_object('name', v_p.full_name), 'approved:' || p_user);
  PERFORM _after_activation(p_user);
END $$;

DROP FUNCTION IF EXISTS admin_create_invite(TEXT, TEXT, TEXT, TEXT, UUID, TIMESTAMPTZ, TEXT, TEXT);
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
  IF EXISTS (SELECT 1 FROM profiles WHERE email = v_email AND status <> 'pending') THEN
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

CREATE OR REPLACE FUNCTION admin_set_contractor_user_level(p_user UUID, p_contractor UUID, p_level contractor_user_level, p_reason TEXT)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_access('admin.users.edit'); v_reason TEXT := _require_reason(p_reason);
        v_p profiles; v_old contractor_user_level; v_id UUID;
BEGIN
  IF p_level IS NULL THEN RAISE EXCEPTION 'Level wajib dipilih' USING ERRCODE = '22023'; END IF;
  SELECT * INTO v_p FROM profiles WHERE id = p_user FOR UPDATE;
  IF NOT FOUND OR v_p.anonymized_at IS NOT NULL THEN RAISE EXCEPTION 'User tidak ditemukan' USING ERRCODE = '22023'; END IF;
  IF v_p.contractor_id IS NULL OR v_p.contractor_id IS DISTINCT FROM p_contractor THEN
    RAISE EXCEPTION 'User bukan bagian dari contractor ini' USING ERRCODE = '22023'; END IF;
  v_old := _contractor_level_of(p_user);
  IF (p_level = 'pic' OR v_old = 'pic') AND p_level IS DISTINCT FROM v_old AND NOT has_permission('level.pic.set') THEN
    PERFORM _deny('forbidden', 'Menetapkan / mencabut level PIC membutuhkan permission level.pic.set'); END IF;
  v_id := _upsert_contractor_level(p_user, p_contractor, p_level, v_uid);
  PERFORM _security_event(p_user, 'contractor_level_set', 'info',
          jsonb_build_object('from', v_old, 'to', p_level, 'contractor', p_contractor, 'reason', v_reason, 'by', v_uid));
  IF p_level IS DISTINCT FROM v_old THEN
    PERFORM _notify(p_user, 'level_set', 'Level akses Anda: ' || upper(p_level::TEXT), v_reason, '/my-company', 'info', NULL, '{}'::jsonb,
                    'level:' || p_user || ':' || extract(epoch FROM NOW())::BIGINT);
    PERFORM _rt_send('user:' || p_user, 'session_check', '{}'::jsonb);
  END IF;
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION list_contractor_users(p_contractor UUID DEFAULT NULL) RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_uid UUID := assert_session(FALSE); v_own UUID := auth_contractor_id(); v_cid UUID := COALESCE(p_contractor, auth_contractor_id());
BEGIN
  IF v_cid IS NULL THEN RAISE EXCEPTION 'Contractor wajib diisi' USING ERRCODE = '22023'; END IF;
  IF NOT (v_cid = v_own OR (auth_is_wfrd() AND can_view_contractor(v_cid))) THEN PERFORM _deny('forbidden'); END IF;
  RETURN COALESCE((
    SELECT jsonb_agg(jsonb_build_object('id', p.id, 'full_name', p.full_name, 'email', p.email, 'avatar_url', p.avatar_url,
             'job_title', p.job_title, 'status', p.status, 'last_login_at', p.last_login_at,
             'level', _contractor_level_of(p.id),
             'roles', (SELECT COALESCE(jsonb_agg(jsonb_build_object('role', r.key) ORDER BY r.key), '[]'::jsonb)
                       FROM user_roles ur JOIN roles r ON r.id = ur.role_id
                       WHERE ur.user_id = p.id AND (ur.expires_at IS NULL OR ur.expires_at > NOW())))
           ORDER BY p.status = 'active' DESC, p.full_name)
    FROM profiles p
    WHERE p.contractor_id = v_cid AND p.anonymized_at IS NULL AND p.status IN ('active','pending','suspended')), '[]'::jsonb);
END $$;

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
              FROM user_roles ur JOIN roles r ON r.id = ur.role_id WHERE ur.user_id = p.id) AS roles
    FROM profiles p LEFT JOIN contractors c ON c.id = p.contractor_id
    WHERE (p_status IS NULL OR p.status = p_status)
      AND (p_contractor IS NULL OR p.contractor_id = p_contractor)
      AND (v_q IS NULL OR p.email ILIKE '%' || v_q || '%' OR p.full_name ILIKE '%' || v_q || '%')
    ORDER BY p.created_at DESC
    LIMIT LEAST(GREATEST(p_limit, 1), 200) OFFSET GREATEST(p_offset, 0)) x);
END $$;

-- Kontrak berjalan: requirement dihitung ulang dengan filter tier
DO $$ DECLARE v UUID; BEGIN
  FOR v IN SELECT id FROM contracts WHERE status NOT IN ('closed','terminated') LOOP PERFORM build_contract_requirements(v); END LOOP;
END $$;

-- ═════════════ PRIVILEGE ═════════════
REVOKE ALL ON FUNCTION resolve_access_tier(contract_mode, INT) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION create_contract(UUID, TEXT, TEXT, TEXT, TEXT, TEXT, DATE, DATE, DATE, DATE, UUID, UUID, TEXT, contract_mode, TEXT) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION create_contract(UUID, TEXT, TEXT, TEXT, TEXT, TEXT, DATE, DATE, DATE, DATE, UUID, UUID, TEXT, contract_mode, TEXT) TO authenticated;
REVOKE ALL ON FUNCTION change_contract_mode(UUID, contract_mode, TEXT, TEXT) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION change_contract_mode(UUID, contract_mode, TEXT, TEXT) TO authenticated;
REVOKE ALL ON FUNCTION admin_approve_user(UUID, TEXT, TEXT, TEXT, UUID, TIMESTAMPTZ, TEXT, contractor_user_level) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION admin_approve_user(UUID, TEXT, TEXT, TEXT, UUID, TIMESTAMPTZ, TEXT, contractor_user_level) TO authenticated;
REVOKE ALL ON FUNCTION admin_create_invite(TEXT, TEXT, TEXT, TEXT, UUID, TIMESTAMPTZ, TEXT, TEXT, contractor_user_level) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION admin_create_invite(TEXT, TEXT, TEXT, TEXT, UUID, TIMESTAMPTZ, TEXT, TEXT, contractor_user_level) TO authenticated;
REVOKE ALL ON FUNCTION admin_set_contractor_user_level(UUID, UUID, contractor_user_level, TEXT) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION admin_set_contractor_user_level(UUID, UUID, contractor_user_level, TEXT) TO authenticated;
