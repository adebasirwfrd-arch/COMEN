import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../features/admin/admin_audit_page.dart';
import '../../features/admin/admin_catalog_page.dart';
import '../../features/admin/admin_chat_page.dart';
import '../../features/admin/admin_contractors_page.dart';
import '../../features/admin/admin_contracts_page.dart';
import '../../features/admin/admin_email_page.dart';
import '../../features/admin/admin_invites_page.dart';
import '../../features/admin/admin_onedrive_page.dart';
import '../../features/admin/admin_overview_page.dart';
import '../../features/admin/admin_privacy_page.dart';
import '../../features/admin/admin_roles_page.dart';
import '../../features/admin/admin_security_page.dart';
import '../../features/admin/admin_settings_page.dart';
import '../../features/admin/admin_system_page.dart';
import '../../features/admin/admin_users_page.dart';
import '../../features/auth/auth_callback_page.dart';
import '../../features/auth/invite_page.dart';
import '../../features/auth/login_page.dart';
import '../../features/auth/mfa_pages.dart';
import '../../features/auth/privacy_page.dart';
import '../../features/chat/chat_pages.dart';
import '../../features/contracts/contract_detail_page.dart';
import '../../features/contracts/contract_list_page.dart';
import '../../features/contracts/contract_new_page.dart';
import '../../features/contracts/contract_onedrive_page.dart';
import '../../features/contracts/meeting_page.dart';
import '../../features/dashboard/dashboard_page.dart';
import '../../features/incidents/incident_pages.dart';
import '../../features/kpi/kpi_page.dart';
import '../../features/my_company/my_company_page.dart';
import '../../features/notifications/notifications_page.dart';
import '../../features/register/pending_page.dart';
import '../../features/register/register_page.dart';
import '../../features/register/wfrd_register_page.dart';
import '../../features/settings/settings_pages.dart';
import '../../features/shell/app_shell.dart';
import '../../features/status/status_pages.dart';
import '../../features/tasks/review_queue_page.dart';
import '../../features/tasks/task_detail_page.dart';
import '../../features/tasks/task_list_page.dart';
import '../../features/tasks/task_tracking_page.dart';
import '../../features/vendors/vendor_pages.dart';
import '../../ui/widgets.dart';
import '../session/session_controller.dart';
import 'gate.dart';

final routerProvider = Provider<GoRouter>((ref) {
  final listenable = ValueNotifier<SessionStatus>(ref.read(sessionProvider));
  ref.listen(sessionProvider, (_, next) => listenable.value = next);
  ref.onDispose(listenable.dispose);
  return GoRouter(
    initialLocation: '/splash',
    refreshListenable: listenable,
    redirect: (context, st) => gate(listenable.value, st),
    errorBuilder: (_, __) => const NotFoundPage(),
    routes: buildRoutes(),
  );
});

/// Halaman :id hanya dirender bila UUID valid (Part 18.1) — selain itu 404 tanpa memanggil RPC.
Widget _uuid(GoRouterState st, Widget Function(String id) build, [String key = 'id']) {
  final id = st.pathParameters[key] ?? '';
  return uuidRe.hasMatch(id) ? build(id) : const NotFoundPage();
}

NoTransitionPage<void> _p(Widget child, GoRouterState st) => NoTransitionPage<void>(key: st.pageKey, child: child);

GoRoute _r(String path, Widget Function(GoRouterState st) build) =>
    GoRoute(path: path, pageBuilder: (context, st) => _p(build(st), st));

/// Urutan = Part 18.1: rute statis SELALU sebelum rute ber-parameter pada prefix yang sama (C4).
List<RouteBase> buildRoutes() => [
      GoRoute(path: '/', redirect: (_, __) => '/dashboard'),
      _r('/splash', (_) => const SplashPage()),
      _r('/login', (st) => LoginPage(reason: st.uri.queryParameters['reason'], next: st.uri.queryParameters['next'])),
      _r('/auth/callback', (st) => AuthCallbackPage(error: st.uri.queryParameters['error_description'] ?? st.uri.queryParameters['error'])),
      _r('/invite', (st) => InvitePage(email: st.uri.queryParameters['email'])),
      _r('/privacy', (_) => const PrivacyPage()),
      _r('/pending', (_) => const PendingPage()),
      _r('/register', (_) => const RegisterPage()),
      _r('/register/wfrd', (_) => const WfrdRegisterPage()),
      _r('/suspended', (_) => const SuspendedPage()),
      _r('/account-closed', (_) => const AccountClosedPage()),
      _r('/device-revoked', (_) => const DeviceRevokedPage()),
      _r('/mfa/enroll', (_) => const MfaEnrollPage()),
      _r('/mfa/verify', (_) => const MfaVerifyPage()),
      _r('/forbidden', (_) => const ForbiddenPage()),
      ShellRoute(
        pageBuilder: (context, st, child) => NoTransitionPage<void>(child: AppShell(child: child)),
        routes: [
          _r('/dashboard', (_) => const DashboardPage()),
          _r('/notifications', (_) => const NotificationsPage()),
          _r('/tasks', (_) => const TaskListPage()),
          _r('/tasks/tracking', (_) => const TaskTrackingPage()),
          _r('/tasks/review', (_) => const ReviewQueuePage()),
          _r('/tasks/:id', (st) => _uuid(st, (id) => TaskDetailPage(id: id))),
          _r('/contracts', (_) => const ContractListPage()),
          _r('/contracts/new', (_) => const ContractNewPage()),
          _r('/contracts/:id', (st) => _uuid(st, (id) => ContractDetailPage(id: id, initialTab: st.uri.queryParameters['tab']))),
          _r('/contracts/:id/onedrive', (st) => _uuid(st, (id) => ContractOneDrivePage(contractId: id))),
          _r('/contracts/:id/meetings/:mid', (st) => _uuid(st, (id) => _uuid(st, (mid) => MeetingPage(contractId: id, meetingId: mid), 'mid'))),
          _r('/vendors', (_) => const VendorListPage()),
          _r('/vendors/:id', (st) => _uuid(st, (id) => VendorDetailPage(id: id))),
          _r('/my-company', (_) => const MyCompanyPage()),
          _r('/incidents', (_) => const IncidentListPage()),
          _r('/incidents/new', (st) => IncidentNewPage(contractId: st.uri.queryParameters['contract'])),
          _r('/incidents/:id', (st) => _uuid(st, (id) => IncidentDetailPage(id: id))),
          _r('/kpi', (_) => const KpiPage()),
          _r('/chat', (_) => const ChatListPage()),
          _r('/chat/saved', (_) => const ChatSavedPage()),
          _r('/chat/:id', (st) => _uuid(st, (id) => ChatRoomPage(channelId: id))),
          GoRoute(path: '/settings', redirect: (_, __) => '/settings/profile'),
          _r('/settings/profile', (_) => const ProfilePage()),
          _r('/settings/devices', (_) => const DevicesPage()),
          _r('/settings/security', (_) => const SecurityPage()),
          _r('/settings/notifications', (_) => const NotificationSettingsPage()),
          _r('/admin', (_) => const AdminOverviewPage()),
          _r('/admin/approvals', (_) => const AdminApprovalsPage()),
          _r('/admin/users', (_) => const AdminUsersPage()),
          _r('/admin/users/:id', (st) => _uuid(st, (id) => AdminUserDetailPage(userId: id))),
          _r('/admin/roles', (_) => const AdminRolesPage()),
          _r('/admin/invites', (_) => const AdminInvitesPage()),
          _r('/admin/contractors', (_) => const AdminContractorsPage()),
          _r('/admin/contracts', (_) => const AdminContractsPage()),
          _r('/admin/onedrive-links', (_) => const AdminOneDrivePage()),
          _r('/admin/doc-catalog', (_) => const AdminCatalogPage()),
          _r('/admin/settings', (_) => const AdminSettingsPage()),
          _r('/admin/email', (_) => const AdminEmailPage()),
          _r('/admin/chat', (_) => const AdminChatPage()),
          _r('/admin/security', (_) => const AdminSecurityPage()),
          _r('/admin/audit', (_) => const AdminAuditPage()),
          _r('/admin/privacy', (_) => const AdminPrivacyPage()),
          _r('/admin/system', (_) => const AdminSystemPage()),
        ],
      ),
    ];
