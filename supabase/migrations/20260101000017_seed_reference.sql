-- ═════════════ GEOZONE (placeholder mailbox — WAJIB diganti di Admin → Settings sebelum go-live) ═════════════
INSERT INTO geozones (code, name, review_mailbox, timezone) VALUES
  ('APAC', 'Asia Pacific', 'hse-review-apac@example.com', 'Asia/Jakarta')
ON CONFLICT (code) DO NOTHING;

-- ═════════════ PERMISSION (Part 4.3) ═════════════
INSERT INTO permissions (key, module, description, risk_level, audience) VALUES
  ('*',                        'system',   'Semua permission (hanya super_admin)',                 'critical', 'wfrd'),
  ('vendor.view',              'vendor',   'Lihat vendor',                                          'low',      'wfrd'),
  ('vendor.create',            'vendor',   'Buat vendor',                                           'medium',   'wfrd'),
  ('vendor.edit',              'vendor',   'Edit vendor & minta info',                              'medium',   'wfrd'),
  ('vendor.screen',            'vendor',   'Screening self-assessment',                             'medium',   'wfrd'),
  ('vendor.asl.decide',        'vendor',   'Keputusan ASL',                                         'high',     'wfrd'),
  ('vendor.suspend',           'vendor',   'Suspend/blacklist/reinstate vendor',                    'high',     'wfrd'),
  ('contract.view',            'contract', 'Lihat kontrak (sesuai scope)',                          'low',      'wfrd'),
  ('contract.create',          'contract', 'Buat kontrak',                                          'medium',   'wfrd'),
  ('contract.edit',            'contract', 'Edit kontrak',                                          'medium',   'wfrd'),
  ('contract.transition',      'contract', 'Pindah fase, hold, resume, terminate',                  'high',     'wfrd'),
  ('contract.golive.approve',  'contract', 'Approve Go-Live',                                       'high',     'wfrd'),
  ('contract.golive.request',  'contract', 'Ajukan Go-Live',                                        'low',      'contractor'),
  ('task.view',                'task',     'Lihat task (sesuai scope)',                             'low',      'wfrd'),
  ('task.confirm_upload',      'task',     'Konfirmasi upload, isi form/checklist',                 'low',      'contractor'),
  ('task.review',              'task',     'Review task (sesuai reviewer_role)',                    'medium',   'wfrd'),
  ('task.generate',            'task',     'Task ad-hoc, MOC, batalkan',                            'medium',   'wfrd'),
  ('task.edit_due',            'task',     'Ubah due date',                                         'medium',   'wfrd'),
  ('task.waive',               'task',     'Waive (N/A) & buka ulang task rejected',                'high',     'wfrd'),
  ('task.nudge',               'task',     'Tombol Ingatkan',                                       'low',      'wfrd'),
  ('upload_link.view',         'onedrive', 'Lihat link OneDrive',                                   'medium',   'wfrd'),
  ('upload_link.manage',       'onedrive', 'Kelola link OneDrive',                                  'high',     'wfrd'),
  ('audit.conduct',            'audit',    'Melakukan audit',                                       'medium',   'wfrd'),
  ('finding.verify',           'audit',    'Verifikasi penutupan finding',                          'medium',   'wfrd'),
  ('inspection.conduct',       'audit',    'Inspeksi lapangan',                                     'medium',   'wfrd'),
  ('risk.approve.high',        'risk',     'Approve residual risk High',                            'high',     'wfrd'),
  ('risk.approve.critical',    'risk',     'Approve residual risk Critical',                        'critical', 'wfrd'),
  ('incident.report',          'incident', 'Lapor insiden',                                         'low',      'any'),
  ('incident.view',            'incident', 'Lihat insiden',                                         'low',      'wfrd'),
  ('incident.manage',          'incident', 'Klasifikasi & tutup insiden',                           'medium',   'wfrd'),
  ('incident.escalate',        'incident', 'Eskalasi insiden',                                      'medium',   'wfrd'),
  ('record.submit',            'record',   'Briefing, BBS, stop-work, manning, questionnaire, subcon', 'low',   'contractor'),
  ('record.view',              'record',   'Lihat record operasional',                              'low',      'wfrd'),
  ('company.edit',             'company',  'Edit profil perusahaan & self-assessment',              'low',      'contractor'),
  ('subcon.approve',           'subcon',   'Approve subcontractor',                                 'high',     'wfrd'),
  ('meeting.manage',           'meeting',  'Buat & finalisasi MoM',                                 'medium',   'wfrd'),
  ('meeting.sign',             'meeting',  'Tanda tangan MoM/OPR/JRA',                              'low',      'any'),
  ('opr.conduct',              'opr',      'Penilaian OPR',                                         'medium',   'wfrd'),
  ('kpi.view',                 'report',   'Lihat KPI',                                             'low',      'wfrd'),
  ('report.export',            'report',   'Export laporan',                                        'medium',   'wfrd'),
  ('chat.use',                 'chat',     'Memakai chat',                                          'low',      'any'),
  ('chat.dm.contractor',       'chat',     'DM contractor mana pun',                                'low',      'wfrd'),
  ('chat.group.create',        'chat',     'Membuat grup',                                          'low',      'wfrd'),
  ('chat.announce',            'chat',     'Pengumuman',                                            'high',     'wfrd'),
  ('chat.moderate',            'chat',     'Moderasi chat',                                         'high',     'wfrd'),
  ('chat.export',              'chat',     'Export transcript',                                     'high',     'wfrd'),
  ('admin.users.view',         'admin',    'Direktori user & role',                                 'medium',   'wfrd'),
  ('admin.users.approve',      'admin',    'Approve/reject user',                                   'high',     'wfrd'),
  ('admin.users.edit',         'admin',    'Grant/revoke role, ubah perusahaan user',               'high',     'wfrd'),
  ('admin.invites.manage',     'admin',    'Kelola undangan',                                       'high',     'wfrd'),
  ('admin.users.suspend',      'admin',    'Suspend/ban/reset MFA',                                 'critical', 'wfrd'),
  ('admin.sessions.revoke',    'admin',    'Cabut perangkat / force logout',                        'critical', 'wfrd'),
  ('admin.roles.manage',       'admin',    'Buat/ubah role & permission',                           'critical', 'wfrd'),
  ('admin.contractors.manage', 'admin',    'Contractor Setup',                                      'high',     'wfrd'),
  ('admin.catalog.manage',     'admin',    'Katalog dokumen',                                       'high',     'wfrd'),
  ('admin.settings.manage',    'admin',    'Rules & settings, hari libur, geozone',                 'high',     'wfrd'),
  ('admin.templates.manage',   'admin',    'Template & log email',                                  'high',     'wfrd'),
  ('admin.chat.manage',        'admin',    'Chat admin',                                            'high',     'wfrd'),
  ('admin.security.manage',    'admin',    'Security Center & kebijakan',                           'critical', 'wfrd'),
  ('admin.audit.view',         'admin',    'Audit Explorer',                                        'high',     'wfrd'),
  ('admin.audit.verify',       'admin',    'Verifikasi hash chain',                                 'high',     'wfrd'),
  ('admin.privacy.manage',     'admin',    'DSAR & anonimisasi',                                    'critical', 'wfrd'),
  ('admin.system.danger',      'admin',    'Danger Zone',                                           'critical', 'wfrd')
ON CONFLICT (key) DO UPDATE SET module = EXCLUDED.module, description = EXCLUDED.description,
                                risk_level = EXCLUDED.risk_level, audience = EXCLUDED.audience;

-- ═════════════ ROLE SISTEM (Part 4.2) ═════════════
INSERT INTO roles (key, name, description, is_system, is_wfrd) VALUES
  ('super_admin',       'Super Admin',       'Root admin (allowlist) — semua permission',            TRUE, TRUE),
  ('hse_admin',         'HSE Admin',         'Admin HSE operasional',                                 TRUE, TRUE),
  ('hse_reviewer',      'HSE Reviewer',      'Review dokumen, screening, audit, monitoring',         TRUE, TRUE),
  ('process_owner',     'Process Owner',     'Kelola kontrak di area, approve Go-Live',              TRUE, TRUE),
  ('procurement',       'Procurement',       'Vendor, ASL, legal, insurance',                        TRUE, TRUE),
  ('auditor',           'Auditor',           'Audit & verifikasi finding',                           TRUE, TRUE),
  ('hse_director',      'HSE Director',      'Approve risiko critical, eskalasi',                    TRUE, TRUE),
  ('viewer',            'Viewer',            'Read-only dashboard',                                  TRUE, TRUE),
  ('contractor_rep',    'Contractor Rep',    'Input data & konfirmasi upload perusahaannya',         TRUE, FALSE),
  ('contractor_viewer', 'Contractor Viewer', 'Lihat data perusahaannya',                             TRUE, FALSE)
ON CONFLICT (key) DO NOTHING;

-- ═════════════ MATRIKS ROLE ↔ PERMISSION (Part 4.4) ═════════════
INSERT INTO role_permissions (role_id, permission_key)
SELECT r.id, p.perm
FROM (VALUES
  ('super_admin', ARRAY['*']),
  ('hse_admin', ARRAY['vendor.view','vendor.create','vendor.edit','vendor.screen',
     'contract.view','contract.create','contract.edit','contract.transition',
     'task.view','task.review','task.generate','task.edit_due','task.waive','task.nudge',
     'upload_link.view','upload_link.manage','audit.conduct','finding.verify','inspection.conduct','risk.approve.high',
     'incident.report','incident.view','incident.manage','incident.escalate','record.view','subcon.approve',
     'meeting.manage','meeting.sign','opr.conduct','kpi.view','report.export',
     'chat.use','chat.dm.contractor','chat.group.create','chat.announce','chat.moderate','chat.export',
     'admin.users.view','admin.users.approve','admin.users.edit','admin.invites.manage','admin.contractors.manage',
     'admin.catalog.manage','admin.settings.manage','admin.templates.manage','admin.chat.manage','admin.audit.view']),
  ('hse_reviewer', ARRAY['vendor.view','vendor.screen','contract.view','task.view','task.review','task.waive','task.nudge',
     'upload_link.view','audit.conduct','finding.verify','inspection.conduct','incident.report','incident.view','incident.manage',
     'record.view','meeting.manage','meeting.sign','opr.conduct','kpi.view','chat.use','chat.dm.contractor','chat.group.create']),
  ('process_owner', ARRAY['vendor.view','contract.view','contract.create','contract.edit','contract.transition',
     'contract.golive.approve','task.view','task.review','task.generate','task.edit_due','task.waive','task.nudge',
     'upload_link.view','upload_link.manage','risk.approve.high','incident.report','incident.view','incident.escalate',
     'record.view','subcon.approve','meeting.manage','meeting.sign','opr.conduct','kpi.view','report.export',
     'chat.use','chat.dm.contractor','chat.group.create','chat.announce']),
  ('procurement', ARRAY['vendor.view','vendor.create','vendor.edit','vendor.asl.decide','vendor.suspend',
     'contract.view','contract.create','contract.edit','task.view','task.review','task.nudge','upload_link.view',
     'opr.conduct','kpi.view','report.export','chat.use','chat.dm.contractor','chat.group.create']),
  ('auditor', ARRAY['vendor.view','contract.view','task.view','task.review','audit.conduct','finding.verify',
     'inspection.conduct','incident.view','record.view','meeting.sign','kpi.view','chat.use','chat.dm.contractor']),
  ('hse_director', ARRAY['vendor.view','vendor.asl.decide','contract.view','contract.transition','contract.golive.approve',
     'task.view','task.review','task.waive','task.nudge','upload_link.view','risk.approve.high','risk.approve.critical',
     'incident.view','incident.manage','incident.escalate','record.view','subcon.approve','meeting.sign','opr.conduct',
     'kpi.view','report.export','chat.use','chat.dm.contractor','chat.group.create','chat.announce','admin.audit.view']),
  ('viewer', ARRAY['vendor.view','contract.view','task.view','incident.view','record.view','kpi.view','chat.use']),
  ('contractor_rep', ARRAY['contract.golive.request','task.confirm_upload','incident.report','record.submit',
     'company.edit','meeting.sign','chat.use']),
  ('contractor_viewer', ARRAY['chat.use'])
) AS x(role_key, perms)
JOIN roles r ON r.key = x.role_key
CROSS JOIN LATERAL unnest(x.perms) AS p(perm)
ON CONFLICT DO NOTHING;

-- ═════════════ KATALOG DOKUMEN (Part 7.3) ═════════════
INSERT INTO doc_type_catalog (code, label, allowed_scopes, kind, phase, requirement, condition_key, min_risk_class,
  vendor_requirement, vendor_condition_key, subcon_required, reviewer_role, requires_email, requires_expiry,
  requires_fingerprint, sensitive, due_anchor, due_offset_days, review_sla_days, is_mob_gate) VALUES
-- A. Vendor (due = hari ini + vendor_doc_due_days)
  ('AKTAPD','Akta Pendirian & Perubahan',          '{vendor}','document','vendor_onboarding',NULL,NULL,NULL,'mandatory',NULL,FALSE,'procurement', TRUE,FALSE,FALSE,TRUE, 'created',NULL,3,FALSE),
  ('NIBXXX','NIB / Izin Usaha',                    '{vendor}','document','vendor_onboarding',NULL,NULL,NULL,'mandatory',NULL,FALSE,'procurement', TRUE,FALSE,FALSE,FALSE,'created',NULL,3,FALSE),
  ('NPWPXX','NPWP',                                '{vendor}','document','vendor_onboarding',NULL,NULL,NULL,'mandatory',NULL,FALSE,'procurement', TRUE,FALSE,FALSE,TRUE, 'created',NULL,3,FALSE),
  ('COMPRF','Company Profile',                     '{vendor}','document','vendor_onboarding',NULL,NULL,NULL,'mandatory',NULL,FALSE,'procurement', TRUE,FALSE,FALSE,FALSE,'created',NULL,3,FALSE),
  ('ORGCHT','Struktur Organisasi',                 '{vendor}','document','vendor_onboarding',NULL,NULL,NULL,'optional', NULL,FALSE,'procurement', TRUE,FALSE,FALSE,FALSE,'created',NULL,3,FALSE),
  ('HSEPOL','HSE Policy',                          '{vendor}','document','vendor_onboarding',NULL,NULL,NULL,'mandatory',NULL,FALSE,'hse_reviewer',TRUE,FALSE,FALSE,FALSE,'created',NULL,3,FALSE),
  ('TRNSMP','Training Matrix + contoh sertifikat', '{vendor}','document','vendor_onboarding',NULL,NULL,NULL,'mandatory',NULL,FALSE,'hse_reviewer',TRUE,FALSE,FALSE,TRUE, 'created',NULL,3,FALSE),
  ('OSHLOG','OSHA 300 log / statistik 3 tahun',    '{vendor}','document','vendor_onboarding',NULL,NULL,NULL,'mandatory',NULL,FALSE,'hse_reviewer',TRUE,FALSE,FALSE,FALSE,'created',NULL,3,FALSE),
  ('EQPLST','Daftar & sertifikat equipment',       '{vendor}','document','vendor_onboarding',NULL,NULL,NULL,'mandatory',NULL,FALSE,'hse_reviewer',TRUE,FALSE,FALSE,FALSE,'created',NULL,3,FALSE),
  ('ISOCRT','ISO 9001/14001/45001',                '{vendor}','document','vendor_onboarding',NULL,NULL,NULL,'optional', NULL,FALSE,'hse_reviewer',TRUE,TRUE, FALSE,FALSE,'created',NULL,3,FALSE),
  ('K3DSNK','Sertifikat K3 Disnaker',              '{vendor}','document','vendor_onboarding',NULL,NULL,NULL,'conditional','country_is_id',FALSE,'hse_reviewer',TRUE,TRUE,FALSE,FALSE,'created',NULL,3,FALSE),
  ('SMK3XX','Sertifikat SMK3',                     '{vendor}','document','vendor_onboarding',NULL,NULL,NULL,'optional', NULL,FALSE,'hse_reviewer',TRUE,TRUE, FALSE,FALSE,'created',NULL,3,FALSE),
  ('CLNREF','Referensi 3 klien',                   '{vendor}','document','vendor_onboarding',NULL,NULL,NULL,'mandatory',NULL,FALSE,'procurement', TRUE,FALSE,FALSE,FALSE,'created',NULL,3,FALSE),
  ('FINSTM','Laporan keuangan terakhir',           '{vendor}','document','vendor_onboarding',NULL,NULL,NULL,'mandatory',NULL,FALSE,'procurement', TRUE,FALSE,FALSE,TRUE, 'created',NULL,3,FALSE),
-- Insurance: vendor + kontrak (gate) + subcontractor
  ('INSCRT','Insurance Certificate',  '{vendor,contract,subcontractor}','document','pre_mobilization','mandatory',NULL,NULL,'mandatory',NULL,TRUE,'procurement',TRUE,TRUE,TRUE,FALSE,'target_mob_date',-14,3,TRUE),
-- B. Post-award
  ('CNTRCT','Signed Contract',              '{contract}','document','post_award','mandatory',NULL,NULL,NULL,NULL,FALSE,'procurement',  TRUE,FALSE,TRUE, TRUE, 'award_date',7, 3,FALSE),
  ('SCOPWK','Scope of Work (acknowledged)', '{contract}','document','post_award','mandatory',NULL,NULL,NULL,NULL,FALSE,'process_owner',TRUE,FALSE,FALSE,FALSE,'award_date',7, 3,FALSE),
  ('CVKEYP','CV Key Personnel',             '{contract}','document','post_award','mandatory',NULL,NULL,NULL,NULL,FALSE,'process_owner',TRUE,FALSE,FALSE,TRUE, 'award_date',5, 3,FALSE),
  ('HSEDRF','Preliminary HSE Plan',         '{contract}','document','post_award','optional', NULL,NULL,NULL,NULL,FALSE,'hse_reviewer', TRUE,FALSE,FALSE,FALSE,'award_date',10,3,FALSE),
  ('ACTITM','Action Item',                  '{vendor,contract,subcontractor}','action','post_award','adhoc',NULL,NULL,NULL,NULL,FALSE,'process_owner',FALSE,FALSE,FALSE,FALSE,'event',NULL,3,FALSE),
-- C. Pre-mobilization (13 mandatory = gate)
  ('HSEPLN','HSE Plan (IOGP 423-02)',        '{contract,subcontractor}','document','pre_mobilization','mandatory',NULL,NULL,NULL,NULL,TRUE, 'hse_reviewer', TRUE,FALSE,TRUE, FALSE,'target_mob_date',-21,5,TRUE),
  ('BRDGDC','Bridging Document',             '{contract,subcontractor}','document','pre_mobilization','mandatory',NULL,NULL,NULL,NULL,TRUE, 'hse_reviewer', TRUE,FALSE,TRUE, FALSE,'target_mob_date',-21,3,TRUE),
  ('JRAREG','Joint Risk Assessment',         '{contract}','form',    'pre_mobilization','mandatory',NULL,NULL,NULL,NULL,FALSE,'hse_reviewer', FALSE,FALSE,FALSE,FALSE,'target_mob_date',-14,3,TRUE),
  ('VERPLN','Verification Plan',             '{contract}','document','pre_mobilization','mandatory',NULL,NULL,NULL,NULL,FALSE,'hse_reviewer', TRUE,FALSE,FALSE,FALSE,'target_mob_date',-14,3,TRUE),
  ('ERPPLN','Emergency Response Plan',       '{contract}','document','pre_mobilization','mandatory',NULL,NULL,NULL,NULL,FALSE,'hse_reviewer', TRUE,FALSE,TRUE, FALSE,'target_mob_date',-14,3,TRUE),
  ('AUDPLN','Audit Plan internal',           '{contract}','document','pre_mobilization','mandatory',NULL,NULL,NULL,NULL,FALSE,'hse_reviewer', TRUE,FALSE,FALSE,FALSE,'target_mob_date',-14,3,TRUE),
  ('MANLST','Manning List',                  '{contract}','document','pre_mobilization','mandatory',NULL,NULL,NULL,NULL,FALSE,'process_owner',TRUE,FALSE,FALSE,TRUE, 'target_mob_date',-10,3,TRUE),
  ('TRNMTX','Training Matrix',               '{contract}','document','pre_mobilization','mandatory',NULL,NULL,NULL,NULL,FALSE,'hse_reviewer', TRUE,FALSE,FALSE,FALSE,'target_mob_date',-10,3,TRUE),
  ('TRNCRT','Training Certificates',         '{contract,subcontractor}','document','pre_mobilization','mandatory',NULL,NULL,NULL,NULL,TRUE, 'hse_reviewer', TRUE,TRUE, FALSE,TRUE, 'target_mob_date',-10,3,TRUE),
  ('EQPREG','Equipment Register',            '{contract}','document','pre_mobilization','mandatory',NULL,NULL,NULL,NULL,FALSE,'hse_reviewer', TRUE,FALSE,FALSE,FALSE,'target_mob_date',-10,3,TRUE),
  ('EQPCRT','Equipment Certificates',        '{contract,subcontractor}','document','pre_mobilization','mandatory',NULL,NULL,NULL,NULL,TRUE, 'hse_reviewer', TRUE,TRUE, FALSE,FALSE,'target_mob_date',-10,3,TRUE),
  ('PRMLIC','Permits & Licenses',            '{contract}','document','pre_mobilization','mandatory',NULL,NULL,NULL,NULL,FALSE,'process_owner',TRUE,TRUE, FALSE,FALSE,'target_mob_date',-7, 3,TRUE),
  ('MSDSXX','MSDS / SDS',                    '{contract}','document','pre_mobilization','conditional','has_chemicals',     NULL,    NULL,NULL,FALSE,'hse_reviewer',TRUE,FALSE,FALSE,FALSE,'target_mob_date',-14,3,TRUE),
  ('SUBDOC','Daftar Subcontractor',          '{contract}','document','pre_mobilization','conditional','has_subcontractor', NULL,    NULL,NULL,FALSE,'hse_reviewer',TRUE,FALSE,FALSE,FALSE,'target_mob_date',-14,3,TRUE),
  ('WSTPLN','Waste Management Plan',         '{contract}','document','pre_mobilization','conditional','generates_waste',   'medium',NULL,NULL,FALSE,'hse_reviewer',TRUE,FALSE,FALSE,FALSE,'target_mob_date',-14,3,TRUE),
  ('CNFSPC','Confined Space & Rescue',       '{contract}','document','pre_mobilization','conditional','has_confined_space',NULL,    NULL,NULL,FALSE,'hse_reviewer',TRUE,FALSE,FALSE,FALSE,'target_mob_date',-14,3,TRUE),
  ('HOTWRK','Hot Work Procedure',            '{contract}','document','pre_mobilization','conditional','has_hot_work',      NULL,    NULL,NULL,FALSE,'hse_reviewer',TRUE,FALSE,FALSE,FALSE,'target_mob_date',-14,3,TRUE),
  ('WAHRSC','Working at Height & Rescue',    '{contract}','document','pre_mobilization','conditional','has_work_at_height',NULL,    NULL,NULL,FALSE,'hse_reviewer',TRUE,FALSE,FALSE,FALSE,'target_mob_date',-14,3,TRUE),
  ('WTRSAF','Water Safety Plan',             '{contract}','document','pre_mobilization','conditional','near_water',        NULL,    NULL,NULL,FALSE,'hse_reviewer',TRUE,FALSE,FALSE,FALSE,'target_mob_date',-14,3,TRUE),
  ('JRNMGT','Journey Management Plan',       '{contract}','document','pre_mobilization','conditional','has_driving',       NULL,    NULL,NULL,FALSE,'hse_reviewer',TRUE,FALSE,FALSE,FALSE,'target_mob_date',-14,3,TRUE),
-- D. Subcontractor-only
  ('SUBRSK','Risk Assessment Subcontractor', '{subcontractor}','document','pre_mobilization',NULL,NULL,NULL,NULL,NULL,TRUE,'hse_reviewer',TRUE,FALSE,FALSE,FALSE,'created',10,3,FALSE),
-- E. Fase 4–8 & ad-hoc
  ('FNDCLS','Bukti Penutupan Finding',       '{contract}','evidence', 'execution',       'adhoc',      NULL,NULL,NULL,NULL,FALSE,'auditor',      FALSE,FALSE,FALSE,FALSE,'event',     NULL,3,FALSE),
  ('INVRPT','Laporan Investigasi (RCA)',     '{contract}','document', 'execution',       'adhoc',      NULL,NULL,NULL,NULL,FALSE,'hse_reviewer', TRUE, FALSE,FALSE,FALSE,'event',     NULL,5,FALSE),
  ('MONRPT','Monthly HSE Report',            '{contract}','form',     'execution',       'recurring',  NULL,NULL,NULL,NULL,FALSE,'hse_reviewer', FALSE,FALSE,FALSE,FALSE,'period_end',5,   5,FALSE),
  ('MOBCHK','Mobilization Checklist',        '{contract}','checklist','mobilization',    'mandatory',  NULL,NULL,NULL,NULL,FALSE,'hse_reviewer', FALSE,FALSE,FALSE,FALSE,'created',   14,  3,FALSE),
  ('DMBCHK','Demobilization Checklist',      '{contract}','checklist','demobilization',  'mandatory',  NULL,NULL,NULL,NULL,FALSE,'hse_reviewer', FALSE,FALSE,FALSE,FALSE,'created',   21,  3,FALSE),
  ('WSTMNF','Manifest Limbah',               '{contract}','document', 'demobilization',  'conditional','generates_waste','medium',NULL,NULL,FALSE,'hse_reviewer',TRUE,FALSE,FALSE,FALSE,'created',21,3,FALSE),
  ('FINRPT','Final HSE Report',              '{contract}','document', 'demobilization',  'mandatory',  NULL,NULL,NULL,NULL,FALSE,'process_owner',TRUE, FALSE,FALSE,FALSE,'created',   30,  3,FALSE),
  ('OPRSLF','OPR Self-Evaluation',           '{contract}','form',     'final_evaluation','mandatory',  NULL,NULL,NULL,NULL,FALSE,'process_owner',FALSE,FALSE,FALSE,FALSE,'created',   14,  3,FALSE)
ON CONFLICT (code) DO NOTHING;

UPDATE doc_type_catalog SET checklist_template = '[
  {"category":"Personnel","label":"Personel termobilisasi sesuai Manning List"},
  {"category":"Equipment","label":"Equipment tiba di lokasi & diinspeksi"},
  {"category":"HSE Plan","label":"HSE Plan disosialisasikan ke seluruh personel"},
  {"category":"Risk","label":"Risk briefing (JRA) disampaikan"},
  {"category":"Risk","label":"Seluruh action JRA closed"},
  {"category":"Organisasi","label":"Roles & responsibilities HSE ditetapkan"},
  {"category":"Induction","label":"Site induction selesai untuk seluruh personel"},
  {"category":"Equipment","label":"Sertifikat equipment diverifikasi di lokasi"},
  {"category":"Emergency","label":"Emergency drill dilaksanakan"},
  {"category":"Permit","label":"Permit & lisensi tersedia di lokasi"},
  {"category":"Monitoring","label":"Monitoring plan & target KPI disepakati"}]'::jsonb
WHERE code = 'MOBCHK' AND checklist_template IS NULL;

UPDATE doc_type_catalog SET checklist_template = '[
  {"category":"Site Restoration","label":"Area kerja dibersihkan & dikembalikan seperti semula"},
  {"category":"Site Restoration","label":"Equipment & material contractor dikeluarkan dari lokasi"},
  {"category":"Waste Management","label":"Limbah diangkut oleh pengangkut berizin"},
  {"category":"Waste Management","label":"Manifest limbah lengkap (WSTMNF bila berlaku)"},
  {"category":"Legal & Financial","label":"Klaim, invoice & kewajiban contractor diselesaikan"},
  {"category":"Legal & Financial","label":"Clearance finansial & aset WFRD","owner_party":"wfrd"},
  {"category":"Notifications","label":"Notifikasi demobilisasi ke pihak terkait & otoritas"},
  {"category":"Notifications","label":"Akses site, ID card & permit dikembalikan/dinonaktifkan","owner_party":"wfrd"}]'::jsonb
WHERE code = 'DMBCHK' AND checklist_template IS NULL;

-- ═════════════ APP SETTINGS ═════════════
INSERT INTO app_settings (key, value, is_public, required_permission, description) VALUES
  ('read_only_mode',              'false',                        TRUE,  'admin.system.danger',   'Semua mutasi ditolak kecuali pemegang admin.system.danger'),
  ('global_sessions_valid_after', '"1970-01-01T00:00:00Z"',       FALSE, 'admin.system.danger',   'Sesi diautentikasi sebelum waktu ini ditolak'),
  ('email_otp_enabled',           'true',                         TRUE,  'admin.system.danger',   'Login Email OTP aktif'),
  ('password_login_enabled',      'false',                        FALSE, 'admin.system.danger',   'Login password (HANYA lokal/mock — diubah oleh seed.sql, tidak lewat UI)'),
  ('mfa_required_roles',          '["super_admin","hse_admin","hse_director"]', FALSE, 'admin.security.manage', 'Role yang wajib aal2 untuk semua RPC'),
  ('step_up_hours',               '12',                           TRUE,  'admin.security.manage', 'Umur maksimum verifikasi TOTP untuk aksi critical'),
  ('rate_chat_per_min',           '30',                           TRUE,  'admin.security.manage', 'Batas pesan per menit per user'),
  ('chat_key_ver',                '1',                            FALSE, 'admin.security.manage', 'Versi kunci AES chat aktif'),
  ('data_key_ver',                '1',                            FALSE, 'admin.security.manage', 'Versi kunci AES data aktif'),
  ('business_timezone',           '"Asia/Jakarta"',               TRUE,  'admin.settings.manage', 'Zona waktu default (geozone tanpa timezone)'),
  ('kpi_normalizer',              '200000',                       TRUE,  'admin.settings.manage', 'Basis jam kerja TRIR/LTIR (200.000 / 1.000.000)'),
  ('kpi_weights',                 '{"trir":15,"ltir":15,"pvir":5,"hipo":5,"bbs":10,"finding_ontime":10,"training":10,"stopwork":5,"task_ontime":10,"monrpt_ontime":5,"audit":10}',
                                                                  TRUE,  'admin.settings.manage', 'Bobot komponen KPI (total 100)'),
  ('kpi_targets',                 '{"trir":1.0,"ltir":0.5,"pvir":1.0}', TRUE, 'admin.settings.manage', 'Target lagging KPI'),
  ('bbs_weekly_target',           '30',                           TRUE,  'admin.settings.manage', 'Target observasi BBS per minggu per kontrak'),
  ('vendor_doc_due_days',         '14',                           FALSE, 'admin.settings.manage', 'Due dokumen vendor (hari)'),
  ('revision_due_days',           '5',                            FALSE, 'admin.settings.manage', 'Due revisi default (hari kerja)'),
  ('vendor_review_mailbox',       '"vendor-review@example.com"',  FALSE, 'admin.settings.manage', 'Tujuan email konfirmasi task vendor — WAJIB diganti'),
  ('inbound_auto_match',          'false',                        FALSE, 'admin.settings.manage', 'Aktifkan CC ke alamat inbound (Fase 2)'),
  ('inbound_address',             '"confirm@inbound.example.com"',FALSE, 'admin.settings.manage', 'Alamat Brevo Inbound Parsing'),
  ('app_url',                     '"https://comen.vercel.app"',   TRUE,  'admin.settings.manage', 'URL aplikasi untuk tautan email'),
  ('brevo_template_map',          '{"1001":null,"1002":null,"1003":null,"1004":null,"1005":null,"1006":null,"1007":null,
     "2001":null,"2002":null,"2003":null,"2004":null,"2005":null,"2006":null,"2007":null,"2008":null,"2009":null,"2010":null,
     "2011":null,"2012":null,"2013":null,"2014":null,"3001":null,"3002":null,"3003":null,"3004":null,"3005":null,
     "4001":null,"4002":null,"4003":null,"4004":null,"4005":null,"4006":null,"4007":null,"4008":null,"5001":null,"5002":null,
     "6001":null,"6002":null,"6003":null,"7001":null,"7002":null,"7003":null,"7004":null,"7005":null,"7006":null,"7007":null,
     "7008":null}',                                             FALSE, 'admin.templates.manage','ID template COMEN → ID template Brevo (null = belum dipetakan)')
ON CONFLICT (key) DO NOTHING;

-- ═════════════ HARI LIBUR TANGGAL TETAP (APAC/ID) — libur bertanggal lunar diinput Admin tiap tahun ═════════════
INSERT INTO holidays (holiday_date, geozone, name)
SELECT make_date(y, m, d), 'APAC', n
FROM generate_series(2026, 2027) y
CROSS JOIN (VALUES (1, 1, 'Tahun Baru Masehi'), (5, 1, 'Hari Buruh'), (6, 1, 'Hari Lahir Pancasila'),
                   (8, 17, 'Hari Kemerdekaan RI'), (12, 25, 'Hari Natal')) AS h(m, d, n)
ON CONFLICT DO NOTHING;

-- ═════════════ ASERSI SEED ═════════════
DO $$ BEGIN
  IF (SELECT count(*) FROM roles WHERE is_system) <> 10 THEN RAISE EXCEPTION 'Seed role tidak lengkap'; END IF;
  IF EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id JOIN permissions p ON p.key = rp.permission_key
             WHERE (r.is_wfrd AND p.audience = 'contractor') OR (NOT r.is_wfrd AND p.audience = 'wfrd')) THEN
    RAISE EXCEPTION 'Audience matriks tidak konsisten'; END IF;
  IF EXISTS (SELECT 1 FROM doc_type_catalog d WHERE NOT EXISTS (SELECT 1 FROM roles r WHERE r.key = d.reviewer_role AND r.is_wfrd)) THEN
    RAISE EXCEPTION 'reviewer_role katalog tidak valid'; END IF;
  IF (SELECT count(*) FROM doc_type_catalog WHERE 'contract' = ANY(allowed_scopes) AND phase = 'pre_mobilization'
        AND requirement = 'mandatory' AND is_mob_gate) <> 13 THEN RAISE EXCEPTION 'Gate pre-mob harus 13 dokumen'; END IF;
  IF (SELECT sum(v::NUMERIC) FROM jsonb_each_text(setting('kpi_weights')) e(k, v)) <> 100 THEN
    RAISE EXCEPTION 'Total bobot KPI harus 100'; END IF;
END $$;
