// lib/core/session/session_state.dart
import 'contract_classification.dart';

class SessionState {
  SessionState.fromJson(Map<String, dynamic> j)
      : userId = j['user_id'] as String, email = j['email'] as String, fullName = j['full_name'] as String?,
        avatarUrl = j['avatar_url'] as String?, status = j['status'] as String, statusReason = j['status_reason'] as String?,
        isRootAdmin = j['is_root_admin'] == true, isWfrd = j['is_wfrd'] == true, contractorId = j['contractor_id'] as String?,
        contractorName = j['contractor_name'] as String?, vendorStatus = j['vendor_status'] as String?,
        registrationSubmitted = j['registration_submitted'] == true, locale = (j['locale'] as String?) ?? 'id',
        roles = List<Map<String, dynamic>>.from(j['roles'] as List? ?? const []),
        permissions = Set<String>.from(j['permissions'] as List? ?? const []),
        globalPermissions = Set<String>.from(j['global_permissions'] as List? ?? const []),
        mfaRequired = j['mfa_required'] == true, mfaEnrolled = j['mfa_enrolled'] == true,
        aal = (j['aal'] as String?) ?? 'aal1', stepUpFresh = j['step_up_fresh'] == true,
        deviceState = j['device_state'] as String, readOnly = j['read_only_mode'] == true,
        emailOtpEnabled = j['email_otp_enabled'] != false, unread = (j['unread_notifications'] as num?)?.toInt() ?? 0,
        contractorLevel = ContractorUserLevel.tryCode(j['contractor_level'] as String?),
        activeContracts = List<Map<String, dynamic>>.from(j['active_contracts'] as List? ?? const []);

  final String userId, email, status, deviceState, aal, locale;
  final String? fullName, avatarUrl, statusReason, contractorId, contractorName, vendorStatus;
  final bool isRootAdmin, isWfrd, registrationSubmitted, mfaRequired, mfaEnrolled, stepUpFresh, readOnly, emailOtpEnabled;
  final List<Map<String, dynamic>> roles;
  final Set<String> permissions, globalPermissions;
  final int unread;

  /// Level user contractor (null untuk WFRD).
  final ContractorUserLevel? contractorLevel;

  /// Kontrak perusahaan yang belum closed/terminated (hanya untuk user contractor).
  final List<Map<String, dynamic>> activeContracts;

  bool get isContractor => contractorId != null && status == 'active';
  bool can(String p) => permissions.contains(p);
  bool canAny(Iterable<String> ps) => ps.any(permissions.contains);
  bool get hasAdminPerm => permissions.any((p) => p.startsWith('admin.'));
  bool get adminMode => hasAdminPerm && aal == 'aal2';

  Iterable<AccessTier> get activeTiers => activeContracts.map((c) => AccessTier.tryCode(c['access_tier'] as String?)).whereType<AccessTier>();

  /// Tier tertinggi di antara kontrak berjalan (null = belum ada kontrak).
  AccessTier? get maxTier {
    AccessTier? best;
    for (final t in activeTiers) {
      if (best == null || t.rank > best.rank) best = t;
    }
    return best;
  }

  /// Semua kontrak berjalan berkategori visitor → menu KPI/record operasional tidak relevan.
  bool get onlyVisitorContracts => activeContracts.isNotEmpty && activeTiers.every((t) => t == AccessTier.visitor);
}
