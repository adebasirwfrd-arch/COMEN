// lib/data/columns.dart
abstract final class Cols {
  static const profiles = 'id,email,full_name,avatar_url,status,status_reason,is_root_admin,contractor_id,geozone,'
      'job_title,locale,privacy_accepted_at,approved_by,approved_at,last_login_at,anonymized_at,created_at,updated_at';
  static const contractors = 'id,vendor_seq,legal_name,trading_name,registration_no,tax_id,country,address,website,'
      'email_domain,primary_contact_name,primary_contact_email,hse_manager_name,hse_manager_email,status,submitted_at,'
      'asl_expires_on,asl_conditions,asl_decided_by,asl_decided_at,status_reason,registered_by,created_at,updated_at';
  static const tasks = 'id,task_id,base_task_id,revision,scope,contractor_id,contract_id,subcontractor_id,doc_type_code,'
      'kind,phase,title,description,is_mandatory,is_blocker,source_ref,parent_task_id,renewal_of,superseded_by,assigned_to,'
      'reviewer_id,due_date,review_due_at,status,status_reason,upload_link_id,uploaded_file_name,file_sha256,evidence_ref,'
      'integrity_attested,upload_confirmed_at,upload_confirmed_by,email_claimed_at,email_verified,email_verified_via,'
      'email_from,doc_number,issuer,issue_date,expiry_date,review_started_at,reviewed_by,reviewed_at,review_notes,'
      'approved_snapshot,fingerprint_verified,form_data,created_by,created_at,updated_at';
  static const trustedDevices = 'id,user_id,label,first_seen,last_seen,revoked_at,revoked_by,revoke_reason';
  static const outbox = 'id,channel,template_id,to_user,to_email,dedupe_key,status,attempts,last_error,provider_msg_id,'
      'send_after,sent_at,created_at';
}
