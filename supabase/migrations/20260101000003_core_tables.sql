CREATE SEQUENCE vendor_seq_global;
CREATE SEQUENCE contract_seq_global;

CREATE TABLE contractors (
  id                        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor_seq                INT UNIQUE NOT NULL DEFAULT nextval('vendor_seq_global'),
  legal_name                TEXT NOT NULL CHECK (length(legal_name) BETWEEN 2 AND 200),
  trading_name              TEXT,
  registration_no           TEXT,
  tax_id                    TEXT,
  country                   TEXT,
  address                   TEXT,
  website                   TEXT CHECK (website IS NULL OR website ~* '^https?://'),
  email_domain              TEXT,
  primary_contact_name      TEXT,
  primary_contact_email     TEXT CHECK (primary_contact_email IS NULL OR primary_contact_email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  primary_contact_phone_enc BYTEA,                              -- AES-256
  enc_key_ver               SMALLINT NOT NULL DEFAULT 1,
  hse_manager_name          TEXT,
  hse_manager_email         TEXT CHECK (hse_manager_email IS NULL OR hse_manager_email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  status                    vendor_status NOT NULL DEFAULT 'draft',
  submitted_at              TIMESTAMPTZ,
  asl_expires_on            DATE,
  asl_conditions            TEXT,
  asl_decided_by            UUID REFERENCES profiles(id),
  asl_decided_at            TIMESTAMPTZ,
  status_reason             TEXT,
  internal_notes            TEXT,
  registered_by             UUID REFERENCES profiles(id),
  created_at                TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at                TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CHECK (status = 'draft' OR (registration_no IS NOT NULL AND tax_id IS NOT NULL AND country IS NOT NULL
         AND address IS NOT NULL AND primary_contact_name IS NOT NULL AND primary_contact_email IS NOT NULL
         AND hse_manager_name IS NOT NULL AND hse_manager_email IS NOT NULL))
);
CREATE UNIQUE INDEX uq_contractor_tax ON contractors(lower(country), upper(regexp_replace(tax_id, '[^A-Za-z0-9]', '', 'g')))
  WHERE tax_id IS NOT NULL;

ALTER TABLE profiles     ADD CONSTRAINT fk_profiles_contractor FOREIGN KEY (contractor_id) REFERENCES contractors(id);
ALTER TABLE user_invites ADD CONSTRAINT fk_invites_contractor  FOREIGN KEY (contractor_id) REFERENCES contractors(id);

CREATE TABLE contracts (
  id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  contract_seq         INT UNIQUE NOT NULL DEFAULT nextval('contract_seq_global'),
  contract_no          TEXT UNIQUE,                             -- trigger trg_contract_no
  contractor_id        UUID NOT NULL REFERENCES contractors(id),
  title                TEXT NOT NULL CHECK (length(title) BETWEEN 3 AND 200),
  scope_of_work        TEXT,
  geozone              TEXT NOT NULL REFERENCES geozones(code),
  site                 TEXT,
  risk_class           TEXT NOT NULL CHECK (risk_class IN ('low','medium','high')),
  start_date           DATE NOT NULL,
  end_date             DATE NOT NULL,
  target_mob_date      DATE NOT NULL,
  awarded_at           DATE NOT NULL DEFAULT CURRENT_DATE,
  process_owner_id     UUID NOT NULL REFERENCES profiles(id),
  hse_reviewer_id      UUID NOT NULL REFERENCES profiles(id),
  review_mailbox       TEXT NOT NULL CHECK (review_mailbox ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  premob_questionnaire JSONB NOT NULL DEFAULT '{}'::jsonb,
  status               contract_status NOT NULL DEFAULT 'awarded',
  status_before_hold   contract_status,
  health_flag          TEXT NOT NULL DEFAULT 'normal' CHECK (health_flag IN ('normal','warning','red')),
  compressed_timeline  BOOLEAN NOT NULL DEFAULT FALSE,
  golive_requested_at  TIMESTAMPTZ,
  golive_requested_by  UUID REFERENCES profiles(id),
  golive_approved_at   TIMESTAMPTZ,
  golive_approved_by   UUID REFERENCES profiles(id),
  closed_at            TIMESTAMPTZ,
  created_by           UUID REFERENCES profiles(id),
  created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CHECK (end_date >= start_date),
  CHECK (target_mob_date BETWEEN awarded_at AND end_date),
  CHECK ((status = 'suspended') = (status_before_hold IS NOT NULL))
);
CREATE INDEX idx_contracts_contractor ON contracts(contractor_id);
CREATE INDEX idx_contracts_status ON contracts(status);

CREATE TABLE subcontractors (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  contract_id   UUID NOT NULL REFERENCES contracts(id),        -- tanpa parent_id → maks 1 tier
  sub_seq       INT NOT NULL CHECK (sub_seq BETWEEN 1 AND 99),
  legal_name    TEXT NOT NULL,
  scope_of_work TEXT NOT NULL,
  pic_name      TEXT,
  pic_email     TEXT,
  hse_manager   TEXT,
  est_manpower  INT CHECK (est_manpower >= 0),
  on_site_from  DATE,
  on_site_to    DATE,
  status        TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','approved','rejected','removed')),
  decided_by    UUID REFERENCES profiles(id),
  decided_at    TIMESTAMPTZ,
  decision_reason TEXT,
  created_by    UUID REFERENCES profiles(id),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (contract_id, sub_seq)
);

CREATE TABLE doc_type_catalog (
  code                 TEXT PRIMARY KEY CHECK (code ~ '^[A-Z0-9]{6}$'),
  label                TEXT NOT NULL,
  allowed_scopes       task_scope[] NOT NULL,
  kind                 task_kind NOT NULL,
  phase                lifecycle_phase NOT NULL,           -- fase default untuk scope kontrak
  requirement          TEXT CHECK (requirement IN ('mandatory','conditional','optional','recurring','adhoc')),
  condition_key        TEXT,
  min_risk_class       TEXT CHECK (min_risk_class IN ('low','medium','high')),
  vendor_requirement   TEXT CHECK (vendor_requirement IN ('mandatory','conditional','optional')),
  vendor_condition_key TEXT,
  subcon_required      BOOLEAN NOT NULL DEFAULT FALSE,
  reviewer_role        TEXT NOT NULL,                       -- roles.key
  requires_email       BOOLEAN NOT NULL DEFAULT FALSE,      -- TRUE untuk kind document
  requires_expiry      BOOLEAN NOT NULL DEFAULT FALSE,
  requires_fingerprint BOOLEAN NOT NULL DEFAULT FALSE,
  sensitive            BOOLEAN NOT NULL DEFAULT FALSE,
  due_anchor           TEXT CHECK (due_anchor IN ('created','award_date','target_mob_date','period_end','event')),
  due_offset_days      INT,
  review_sla_days      INT NOT NULL DEFAULT 3 CHECK (review_sla_days BETWEEN 1 AND 30),
  is_mob_gate          BOOLEAN NOT NULL DEFAULT FALSE,
  checklist_template   JSONB,                               -- item default untuk kind checklist
  active               BOOLEAN NOT NULL DEFAULT TRUE,
  CHECK (kind <> 'document' OR requires_email),
  CHECK (requirement <> 'conditional' OR condition_key IS NOT NULL OR min_risk_class IS NOT NULL),
  CHECK (vendor_requirement IS NULL OR 'vendor' = ANY(allowed_scopes)),
  CHECK (NOT subcon_required OR 'subcontractor' = ANY(allowed_scopes))
);

CREATE TABLE contract_requirements (
  contract_id   UUID NOT NULL REFERENCES contracts(id),
  doc_type_code TEXT NOT NULL REFERENCES doc_type_catalog(code),
  applicable    BOOLEAN NOT NULL,
  is_mandatory  BOOLEAN NOT NULL,
  is_mob_gate   BOOLEAN NOT NULL,
  reason        TEXT,
  computed_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (contract_id, doc_type_code)
);

CREATE TABLE upload_links (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  scope_type       TEXT NOT NULL CHECK (scope_type IN ('global','vendor','contract','subcontractor','task')),
  contractor_id    UUID REFERENCES contractors(id),
  contract_id      UUID REFERENCES contracts(id),
  subcontractor_id UUID REFERENCES subcontractors(id),
  task_id          UUID,                                        -- FK di 14.4
  doc_type_code    TEXT REFERENCES doc_type_catalog(code),      -- NULL = default scope
  url              TEXT NOT NULL CHECK (length(url) <= 2000
                     AND url ~* '^https://(1drv\.ms|onedrive\.live\.com|[a-z0-9-]+(-my)?\.sharepoint\.com)/'),
  link_type        TEXT NOT NULL DEFAULT 'file_request' CHECK (link_type IN ('file_request','folder_edit')),
  label            TEXT NOT NULL CHECK (length(label) <= 200),
  expires_at       DATE,
  active           BOOLEAN NOT NULL DEFAULT TRUE,
  created_by       UUID NOT NULL REFERENCES profiles(id),
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CHECK (
    (scope_type = 'global'        AND contractor_id IS NULL     AND contract_id IS NULL     AND subcontractor_id IS NULL AND task_id IS NULL) OR
    (scope_type = 'vendor'        AND contractor_id IS NOT NULL AND contract_id IS NULL     AND subcontractor_id IS NULL AND task_id IS NULL) OR
    (scope_type = 'contract'      AND contract_id IS NOT NULL   AND subcontractor_id IS NULL AND task_id IS NULL) OR
    (scope_type = 'subcontractor' AND contract_id IS NOT NULL   AND subcontractor_id IS NOT NULL AND task_id IS NULL) OR
    (scope_type = 'task'          AND task_id IS NOT NULL       AND doc_type_code IS NULL)
  )
);
CREATE UNIQUE INDEX uq_upload_link_active ON upload_links (
  scope_type, COALESCE(contractor_id::TEXT,''), COALESCE(contract_id::TEXT,''),
  COALESCE(subcontractor_id::TEXT,''), COALESCE(task_id::TEXT,''), COALESCE(doc_type_code,'')
) WHERE active;
