CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pg_net   WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS supabase_vault;            -- aktif default di Supabase

CREATE TYPE account_status    AS ENUM ('pending','active','suspended','rejected','deactivated');
CREATE TYPE vendor_status     AS ENUM ('draft','under_review','asl_approved','asl_conditional',
                                       'rejected','asl_expired','suspended','blacklisted');
CREATE TYPE contract_status   AS ENUM ('awarded','post_award','pre_mobilization','mobilization','active',
                                       'demobilization','final_evaluation','closed','suspended','terminated');
CREATE TYPE lifecycle_phase   AS ENUM ('vendor_onboarding','evaluation','post_award','pre_mobilization',
                                       'mobilization','execution','monitoring','demobilization','final_evaluation');
CREATE TYPE task_scope        AS ENUM ('vendor','contract','subcontractor');
CREATE TYPE task_kind         AS ENUM ('document','evidence','form','checklist','action');
CREATE TYPE task_status       AS ENUM ('open','awaiting_email','submitted','under_review','file_issue',
                                       'approved','revise','rejected','expired','superseded','waived','cancelled');
CREATE TYPE chat_channel_type AS ENUM ('direct','group','contract','task','announcement');
