import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/router/route_rules.dart';
import '../../core/session/session_controller.dart';
import '../../core/session/session_state.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

const adminModules = <(String, String, IconData)>[
  ('/admin', 'Overview', Icons.dashboard_customize_rounded),
  ('/admin/approvals', 'Approval', Icons.how_to_reg_rounded),
  ('/admin/users', 'Users', Icons.people_alt_rounded),
  ('/admin/roles', 'Roles', Icons.key_rounded),
  ('/admin/invites', 'Invites', Icons.mark_email_unread_rounded),
  ('/admin/contractors', 'Contractors', Icons.apartment_rounded),
  ('/admin/contracts', 'Contracts', Icons.handshake_rounded),
  ('/admin/onedrive-links', 'OneDrive Links', Icons.cloud_upload_rounded),
  ('/admin/doc-catalog', 'Catalog', Icons.library_books_rounded),
  ('/admin/settings', 'Settings', Icons.tune_rounded),
  ('/admin/email', 'Email', Icons.outgoing_mail),
  ('/admin/chat', 'Chat', Icons.forum_rounded),
  ('/admin/security', 'Security', Icons.security_rounded),
  ('/admin/audit', 'Audit', Icons.receipt_long_rounded),
  ('/admin/privacy', 'Privacy', Icons.privacy_tip_rounded),
  ('/admin/system', 'System', Icons.warning_amber_rounded),
];

SessionState? sessionOf(WidgetRef ref) {
  final s = ref.watch(sessionProvider);
  return s is SessionReady ? s.s : null;
}

/// Kerangka halaman Admin Console: tab modul (hanya yang diizinkan) + konten.
class AdminScaffold extends ConsumerWidget {
  const AdminScaffold({super.key, required this.title, this.subtitle, this.actions = const [], required this.child});
  final String title;
  final String? subtitle;
  final List<Widget> actions;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = sessionOf(ref);
    final path = GoRouterState.of(context).uri.path;
    final mods = adminModules.where((m) {
      if (s == null) return false;
      final r = RouteRules.match(m.$1);
      return r != null && r.allows(s);
    }).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        color: Theme.of(context).colorScheme.surface,
        height: 52,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          children: [
            for (final m in mods)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: _ModuleChip(
                  label: m.$2,
                  icon: m.$3,
                  selected: m.$1 == '/admin' ? path == '/admin' : path.startsWith(m.$1),
                  danger: m.$1 == '/admin/system',
                  onTap: () => context.go(m.$1),
                ),
              ),
          ],
        ),
      ),
      const Divider(height: 1),
      Expanded(child: PageScaffold(title: title, subtitle: subtitle, actions: actions, child: child)),
    ]);
  }
}

class _ModuleChip extends StatelessWidget {
  const _ModuleChip({required this.label, required this.icon, required this.selected, required this.onTap, this.danger = false});
  final String label;
  final IconData icon;
  final bool selected;
  final bool danger;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = danger ? Brand.red : Brand.blue;
    return Material(
      color: selected ? c.withValues(alpha: 0.12) : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(children: [
            Icon(icon, size: 16, color: selected ? c : Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(fontWeight: selected ? FontWeight.w800 : FontWeight.w500, color: selected ? c : null)),
          ]),
        ),
      ),
    );
  }
}
