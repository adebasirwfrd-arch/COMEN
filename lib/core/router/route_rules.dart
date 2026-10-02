import '../session/session_state.dart';

typedef Allow = bool Function(SessionState s);

class RouteRule {
  const RouteRule(this.pattern, this.allows, {this.requiresAal2 = false});
  final RegExp pattern;
  final Allow allows;
  final bool requiresAal2;
}

const _uuid = r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';
bool _active(SessionState s) => s.status == 'active';
bool _wfrd(SessionState s, String p) => s.isWfrd && s.can(p);

abstract final class RouteRules {
  static final List<RouteRule> _rules = [
    RouteRule(RegExp(r'^/(dashboard|notifications|tasks)$'), _active),
    RouteRule(RegExp(r'^/tasks/tracking$'), (s) => (s.isContractor && _active(s)) || _wfrd(s, 'task.view')),
    RouteRule(RegExp(r'^/tasks/review$'), (s) => _wfrd(s, 'task.review')),
    RouteRule(RegExp('^/tasks/$_uuid\$'), _active),
    RouteRule(RegExp(r'^/contracts/new$'), (s) => _wfrd(s, 'contract.create')),
    RouteRule(RegExp('^/contracts/$_uuid/onedrive\$'), (s) => _wfrd(s, 'upload_link.view')),
    RouteRule(RegExp('^/contracts(/$_uuid(/meetings/$_uuid)?)?\$'), (s) => s.isContractor || _wfrd(s, 'contract.view')),
    RouteRule(RegExp('^/vendors(/$_uuid)?\$'), (s) => _wfrd(s, 'vendor.view')),
    RouteRule(RegExp(r'^/my-company$'), (s) => s.isContractor),
    RouteRule(RegExp(r'^/incidents/new$'), (s) => s.can('incident.report')),
    RouteRule(RegExp('^/incidents(/$_uuid)?\$'), (s) => s.isContractor || _wfrd(s, 'incident.view')),
    RouteRule(RegExp(r'^/kpi$'), (s) => (s.isContractor && !s.onlyVisitorContracts) || _wfrd(s, 'kpi.view')),
    RouteRule(RegExp('^/chat(/saved|/$_uuid)?\$'), (s) => s.can('chat.use')),
    RouteRule(RegExp(r'^/register$'), (s) => s.status == 'pending' || (s.isContractor && s.vendorStatus == 'draft')),
    RouteRule(RegExp(r'^/settings/devices$'), (s) => s.status == 'active' || s.status == 'pending'),
    RouteRule(RegExp(r'^/settings/(profile|security|notifications)$'), _active),
    RouteRule(RegExp(r'^/mfa/(enroll|verify)$'), _active),
    // Admin Console — selalu aal2
    RouteRule(RegExp(r'^/admin$'), (s) => s.hasAdminPerm, requiresAal2: true),
    RouteRule(RegExp(r'^/admin/approvals$'), (s) => s.can('admin.users.approve'), requiresAal2: true),
    RouteRule(RegExp('^/admin/users(/$_uuid)?\$'), (s) => s.can('admin.users.view'), requiresAal2: true),
    RouteRule(RegExp(r'^/admin/roles$'), (s) => s.canAny(['admin.users.view', 'admin.roles.manage']), requiresAal2: true),
    RouteRule(RegExp(r'^/admin/invites$'), (s) => s.can('admin.invites.manage'), requiresAal2: true),
    RouteRule(RegExp(r'^/admin/contractors$'), (s) => s.can('admin.contractors.manage'), requiresAal2: true),
    RouteRule(RegExp(r'^/admin/contracts$'), (s) => s.hasAdminPerm && s.can('contract.create'), requiresAal2: true),
    RouteRule(RegExp(r'^/admin/onedrive-links$'), (s) => s.hasAdminPerm && s.can('upload_link.view'), requiresAal2: true),
    RouteRule(RegExp(r'^/admin/doc-catalog$'), (s) => s.can('admin.catalog.manage'), requiresAal2: true),
    RouteRule(RegExp(r'^/admin/settings$'), (s) => s.can('admin.settings.manage'), requiresAal2: true),
    RouteRule(RegExp(r'^/admin/email$'), (s) => s.can('admin.templates.manage'), requiresAal2: true),
    RouteRule(RegExp(r'^/admin/chat$'), (s) => s.can('admin.chat.manage'), requiresAal2: true),
    RouteRule(RegExp(r'^/admin/security$'), (s) => s.can('admin.security.manage'), requiresAal2: true),
    RouteRule(RegExp(r'^/admin/audit$'), (s) => s.can('admin.audit.view'), requiresAal2: true),
    RouteRule(RegExp(r'^/admin/privacy$'), (s) => s.can('admin.privacy.manage'), requiresAal2: true),
    RouteRule(RegExp(r'^/admin/system$'), (s) => s.can('admin.system.danger'), requiresAal2: true),
  ];

  /// null = path tidak dikenal (404) atau publik/status (sudah ditangani gate)
  static RouteRule? match(String path) {
    for (final r in _rules) { if (r.pattern.hasMatch(path)) return r; }
    if (path.startsWith('/admin')) return RouteRule(RegExp('.*'), (_) => false, requiresAal2: true);   // deny-by-default
    return null;
  }
}
