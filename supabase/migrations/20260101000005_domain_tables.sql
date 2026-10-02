CREATE TABLE self_assessments (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  contractor_id UUID NOT NULL REFERENCES contractors(id),
  period_year   INT NOT NULL CHECK (period_year BETWEEN 2020 AND 2100),
  answers       JSONB NOT NULL DEFAULT '{}'::jsonb,
  computed      JSONB NOT NULL DEFAULT '{}'::jsonb,           -- TRIR/LTIR/PVIR per tahun, fatality_3y
  status        TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','submitted')),
  submitted_by  UUID REFERENCES profiles(id),
  submitted_at  TIMESTAMPTZ,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (contractor_id, period_year)
);

CREATE TABLE vendor_evaluations (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  contractor_id      UUID NOT NULL REFERENCES contractors(id),
  self_assessment_id UUID REFERENCES self_assessments(id),
  scores             JSONB NOT NULL,                          -- {hse_program, performance, training, equipment, legal_gate}
  total              NUMERIC(5,2) NOT NULL,
  recommendation     TEXT NOT NULL CHECK (recommendation IN ('approve','conditional','reject')),
  conditions         TEXT,
  screened_by        UUID NOT NULL REFERENCES profiles(id),
  screened_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE meetings (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  contract_id  UUID NOT NULL REFERENCES contracts(id),
  meeting_type TEXT NOT NULL CHECK (meeting_type IN ('post_award','progress','audit_closing','other')),
  mom_no       TEXT UNIQUE,                                   -- MOM-00042-001
  scheduled_at TIMESTAMPTZ NOT NULL,
  location     TEXT,
  agenda       JSONB NOT NULL DEFAULT '[]'::jsonb,
  minutes      JSONB NOT NULL DEFAULT '{}'::jsonb,
  status       TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','final','signed')),
  created_by   UUID NOT NULL REFERENCES profiles(id),
  finalized_at TIMESTAMPTZ,
  signed_at    TIMESTAMPTZ,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE meeting_attendees (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  meeting_id UUID NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
  user_id    UUID REFERENCES profiles(id),
  name       TEXT NOT NULL,
  party      TEXT NOT NULL CHECK (party IN ('wfrd','contractor')),
  role_title TEXT
);

CREATE TABLE signatures (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  entity     TEXT NOT NULL CHECK (entity IN ('meeting','opr_review','jra')),
  entity_id  UUID NOT NULL,
  signer_id  UUID NOT NULL REFERENCES profiles(id),
  party      TEXT NOT NULL CHECK (party IN ('wfrd','contractor')),
  method     TEXT NOT NULL CHECK (method IN ('typed_name','drawn')),
  sig_hash   TEXT NOT NULL CHECK (sig_hash ~ '^[a-f0-9]{64}$'),  -- SHA-256(entity snapshot ‖ signer ‖ waktu)
  signed_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (entity, entity_id, signer_id)
);

CREATE TABLE risk_items (
  id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  contract_id          UUID NOT NULL REFERENCES contracts(id),
  task_id              UUID REFERENCES tasks(id),              -- JRAREG
  hazard               TEXT NOT NULL,
  category             TEXT,
  location_activity    TEXT,
  exposed              TEXT,
  existing_controls    JSONB NOT NULL DEFAULT '{}'::jsonb,
  likelihood           SMALLINT NOT NULL CHECK (likelihood BETWEEN 1 AND 5),
  severity             SMALLINT NOT NULL CHECK (severity BETWEEN 1 AND 5),
  risk_score           SMALLINT GENERATED ALWAYS AS (likelihood * severity) STORED,
  additional_controls  TEXT,
  residual_likelihood  SMALLINT NOT NULL CHECK (residual_likelihood BETWEEN 1 AND 5),
  residual_severity    SMALLINT NOT NULL CHECK (residual_severity BETWEEN 1 AND 5),
  residual_score       SMALLINT GENERATED ALWAYS AS (residual_likelihood * residual_severity) STORED,
  action_owner         TEXT,
  action_task_id       UUID REFERENCES tasks(id),
  due_date             DATE,
  evidence_ref         TEXT,
  residual_approved_by UUID REFERENCES profiles(id),
  residual_approved_at TIMESTAMPTZ,
  created_by           UUID REFERENCES profiles(id),
  created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at           TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE audits (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  contract_id  UUID NOT NULL REFERENCES contracts(id),
  audit_type   TEXT NOT NULL CHECK (audit_type IN ('pre_mob','periodic','closing')),
  results      JSONB NOT NULL DEFAULT '{}'::jsonb,           -- {area: 'pass'|'fail'|'na'}
  score        NUMERIC(5,2),
  status       TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','final')),
  conducted_by UUID NOT NULL REFERENCES profiles(id),
  conducted_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE inspections (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  contract_id     UUID NOT NULL REFERENCES contracts(id),
  inspected_at    TIMESTAMPTZ NOT NULL,
  inspector_id    UUID NOT NULL REFERENCES profiles(id),
  area            TEXT NOT NULL,
  result          JSONB NOT NULL DEFAULT '{}'::jsonb,
  notes           TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE audit_findings (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  finding_no     TEXT UNIQUE NOT NULL,                        -- FND-00042-007
  contract_id    UUID NOT NULL REFERENCES contracts(id),
  audit_id       UUID REFERENCES audits(id),
  inspection_id  UUID REFERENCES inspections(id),
  area           TEXT NOT NULL,
  description    TEXT NOT NULL,
  severity       TEXT NOT NULL CHECK (severity IN ('critical','major','minor')),
  due_date       DATE NOT NULL,
  status         TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open','closure_submitted','closed','cancelled')),
  fndcls_task_id UUID REFERENCES tasks(id),
  verified_by    UUID REFERENCES profiles(id),
  verified_at    TIMESTAMPTZ,
  created_by     UUID NOT NULL REFERENCES profiles(id),
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE manning (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  contract_id      UUID NOT NULL REFERENCES contracts(id),
  subcontractor_id UUID REFERENCES subcontractors(id),
  full_name        TEXT NOT NULL,                             -- TANPA NIK/KTP
  position         TEXT NOT NULL,
  competencies     TEXT[] NOT NULL DEFAULT '{}',
  cert_expiry      DATE,
  on_site          BOOLEAN NOT NULL DEFAULT TRUE,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE daily_briefings (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  contract_id     UUID NOT NULL REFERENCES contracts(id),
  briefing_at     TIMESTAMPTZ NOT NULL,
  location        TEXT NOT NULL,
  topics          TEXT NOT NULL,
  attendee_ids    UUID[] NOT NULL DEFAULT '{}',              -- manning.id
  attendees_count INT NOT NULL CHECK (attendees_count >= 0),
  hazards         TEXT,
  key_message     TEXT,
  evidence_ref    TEXT,
  submitted_by    UUID NOT NULL REFERENCES profiles(id),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE bbs_observations (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  contract_id       UUID NOT NULL REFERENCES contracts(id),
  observed_at       TIMESTAMPTZ NOT NULL,
  observer_name     TEXT NOT NULL,
  result            TEXT NOT NULL CHECK (result IN ('safe','at_risk')),
  category          TEXT NOT NULL,
  description       TEXT NOT NULL,
  corrective_action TEXT,
  evidence_ref      TEXT,
  submitted_by      UUID NOT NULL REFERENCES profiles(id),
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CHECK (result = 'safe' OR corrective_action IS NOT NULL)
);

CREATE TABLE stop_work_events (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  contract_id       UUID NOT NULL REFERENCES contracts(id),
  occurred_at       TIMESTAMPTZ NOT NULL,
  raised_by_name    TEXT NOT NULL,
  reason            TEXT NOT NULL,
  location          TEXT,
  corrective_action TEXT,
  resumed_at        TIMESTAMPTZ,
  verifier_name     TEXT,
  submitted_by      UUID NOT NULL REFERENCES profiles(id),
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE incidents (
  id                     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  incident_no            TEXT UNIQUE NOT NULL,                -- INC-00042-003
  contract_id            UUID NOT NULL REFERENCES contracts(id),
  occurred_at            TIMESTAMPTZ NOT NULL,
  reported_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  type                   TEXT NOT NULL CHECK (type IN ('near_miss','first_aid','mtc','rwc','lti','fatality',
                           'vehicle','property_damage','environmental','security','other')),
  severity               TEXT NOT NULL CHECK (severity IN ('low','medium','high','critical')),
  is_preventable_vehicle BOOLEAN NOT NULL DEFAULT FALSE,
  high_potential         BOOLEAN NOT NULL DEFAULT FALSE,
  title                  TEXT NOT NULL CHECK (length(title) <= 200),
  description            TEXT NOT NULL CHECK (length(description) <= 8000),
  lat                    NUMERIC(9,6) CHECK (lat BETWEEN -90 AND 90),
  lng                    NUMERIC(9,6) CHECK (lng BETWEEN -180 AND 180),
  location_text          TEXT,
  evidence_ref           TEXT,
  flash_due_at           TIMESTAMPTZ,
  flash_at               TIMESTAMPTZ,
  full_report_due_at     TIMESTAMPTZ NOT NULL,
  full_report_at         TIMESTAMPTZ,
  full_report            JSONB,
  rca_task_id            UUID REFERENCES tasks(id),
  status                 TEXT NOT NULL DEFAULT 'reported' CHECK (status IN ('reported','investigating','closed')),
  reported_by            UUID NOT NULL REFERENCES profiles(id),
  closed_by              UUID REFERENCES profiles(id),
  closed_at              TIMESTAMPTZ,
  created_at             TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at             TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CHECK (occurred_at <= reported_at + INTERVAL '5 minutes')
);

CREATE TABLE kpi_snapshots (
  contract_id  UUID NOT NULL REFERENCES contracts(id),
  period_month DATE NOT NULL CHECK (EXTRACT(DAY FROM period_month) = 1),
  metrics      JSONB NOT NULL,
  score        NUMERIC(5,2) NOT NULL,
  color        TEXT NOT NULL CHECK (color IN ('green','yellow','red')),
  computed_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (contract_id, period_month)
);

CREATE TABLE opr_reviews (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  contract_id     UUID UNIQUE NOT NULL REFERENCES contracts(id),
  final_hse_score NUMERIC(5,2),
  ratings         JSONB NOT NULL DEFAULT '{}'::jsonb,         -- compliance, responsiveness, reporting, subcon_mgmt, capability (0–100)
  wfrd_score      NUMERIC(5,2),
  final_score     NUMERIC(5,2),
  recommendation  TEXT CHECK (recommendation IN ('renew','renew_conditional','conditional','remove')),
  comments        TEXT,
  status          TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','final','signed')),
  created_by      UUID NOT NULL REFERENCES profiles(id),
  signed_at       TIMESTAMPTZ,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
