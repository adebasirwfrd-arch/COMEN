import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/router/route_rules.dart';
import '../../data/api.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'admin_common.dart';
import 'admin_widgets.dart';

class AdminOverviewPage extends ConsumerStatefulWidget {
  const AdminOverviewPage({super.key});
  @override
  ConsumerState<AdminOverviewPage> createState() => _AdminOverviewPageState();
}

class _AdminOverviewPageState extends ConsumerState<AdminOverviewPage> {
  late Future<J> _future = _load();

  Future<J> _load() => ref.read(apiProvider).rpcMap('admin_overview');
  void _reload() => setState(() => _future = _load());

  @override
  Widget build(BuildContext context) {
    final s = sessionOf(ref);
    return AdminScaffold(
      title: 'Admin Console',
      subtitle: 'Ringkasan kesehatan sistem, antrean tindakan, dan kesiapan go-live',
      actions: [OutlinedButton.icon(onPressed: _reload, icon: const Icon(Icons.refresh_rounded), label: const Text('Muat ulang'))],
      child: AsyncView<J>(
        future: _future,
        onRetry: _reload,
        builder: (context, d) {
          bool allowed(String path) => s != null && (RouteRules.match(path)?.allows(s) ?? false);
          VoidCallback? go(String path) => allowed(path) ? () => context.go(path) : null;
          int n(String k) => (d[k] as num?)?.toInt() ?? 0;
          final checks = jm(d['golive_checks']);
          final head = jm(d['audit_head']);
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (d['read_only_mode'] == true) ...[
              InfoBanner(
                message: 'READ-ONLY MODE aktif — semua mutasi ditolak kecuali pemegang admin.system.danger.',
                color: Brand.red,
                icon: Icons.lock_clock_rounded,
                action: allowed('/admin/system') ? TextButton(onPressed: () => context.go('/admin/system'), child: const Text('Kelola')) : null,
              ),
              const SizedBox(height: 16),
            ],
            ResponsiveGrid(minItemWidth: 240, children: [
              StatCard(label: 'User pending', value: '${n('pending_users')}', icon: Icons.how_to_reg_rounded, color: n('pending_users') > 0 ? Brand.amber : Brand.green, onTap: go('/admin/approvals'), caption: 'Menunggu approval'),
              StatCard(label: 'User aktif', value: '${n('active_users')}', icon: Icons.people_alt_rounded, color: Brand.blue, onTap: go('/admin/users')),
              StatCard(label: 'Alert keamanan', value: '${n('open_security')}', icon: Icons.gpp_maybe_rounded, color: n('open_security') > 0 ? Brand.red : Brand.green, onTap: go('/admin/security'), caption: 'Belum ditangani'),
              StatCard(label: 'Email gagal', value: '${n('outbox_failed')}', icon: Icons.mark_email_unread_rounded, color: n('outbox_failed') > 0 ? Brand.red : Brand.green, onTap: go('/admin/email'), caption: 'Outbox status failed'),
              StatCard(label: 'Task tanpa link', value: '${n('link_gaps')}', icon: Icons.link_off_rounded, color: n('link_gaps') > 0 ? Brand.amber : Brand.green, onTap: go('/admin/onedrive-links'), caption: 'Reminder ditahan'),
              StatCard(label: 'Task overdue', value: '${n('tasks_overdue')}', icon: Icons.event_busy_rounded, color: n('tasks_overdue') > 0 ? Brand.red : Brand.green),
              StatCard(label: 'Review lewat SLA', value: '${n('reviews_overdue')}', icon: Icons.timer_off_rounded, color: n('reviews_overdue') > 0 ? Brand.amber : Brand.green),
            ]),
            const SizedBox(height: 16),
            LayoutBuilder(builder: (context, c) {
              final golive = _GoLiveCard(checks: checks, allowed: allowed);
              final audit = _AuditHeadCard(head: head, canOpen: allowed('/admin/audit'));
              return c.maxWidth > 1000
                  ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(flex: 3, child: golive), const SizedBox(width: 16), Expanded(flex: 2, child: audit)])
                  : Column(children: [golive, const SizedBox(height: 16), audit]);
            }),
            const SizedBox(height: 16),
            LayoutBuilder(builder: (context, c) {
              final a = SectionCard(
                title: 'Kontrak per status',
                icon: Icons.handshake_rounded,
                trailing: allowed('/admin/contracts') ? TextButton(onPressed: () => context.go('/admin/contracts'), child: const Text('Kelola')) : null,
                child: StatusDistribution(data: jm(d['contracts_by_status']), style: StatusStyle.contract),
              );
              final b = SectionCard(
                title: 'Vendor per status',
                icon: Icons.apartment_rounded,
                trailing: allowed('/admin/contractors') ? TextButton(onPressed: () => context.go('/admin/contractors'), child: const Text('Kelola')) : null,
                child: StatusDistribution(data: jm(d['vendors_by_status']), style: StatusStyle.vendor),
              );
              return c.maxWidth > 900
                  ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: a), const SizedBox(width: 16), Expanded(child: b)])
                  : Column(children: [a, const SizedBox(height: 16), b]);
            }),
            const SizedBox(height: 16),
            SectionCard(
              title: 'Modul',
              subtitle: 'Hanya modul yang diizinkan untuk role Anda',
              icon: Icons.apps_rounded,
              child: ResponsiveGrid(minItemWidth: 200, spacing: 12, children: [
                for (final m in adminModules.skip(1).where((m) => allowed(m.$1))) _ModuleTile(path: m.$1, label: m.$2, icon: m.$3),
              ]),
            ),
          ]);
        },
      ),
    );
  }
}

class _GoLiveCard extends StatelessWidget {
  const _GoLiveCard({required this.checks, required this.allowed});
  final J checks;
  final bool Function(String) allowed;

  static const _defs = <(String, String, String, String)>[
    ('vendor_mailbox_placeholder', 'Mailbox review vendor', 'vendor_review_mailbox masih @example.com', '/admin/settings'),
    ('geozone_mailbox_placeholder', 'Mailbox review geozone', 'Ada geozone aktif dengan mailbox @example.com', '/admin/settings'),
    ('inbound_placeholder', 'Alamat inbound email', 'inbound_auto_match aktif tetapi alamat masih placeholder', '/admin/settings'),
    ('templates_unmapped', 'Template Brevo', 'Template COMEN belum dipetakan ke ID Brevo', '/admin/email'),
    ('no_holidays_next_year', 'Hari libur tahun depan', 'Belum ada data hari libur untuk tahun depan', '/admin/settings'),
    ('password_login_enabled', 'Login password', 'Login password aktif (hanya untuk lokal/mock)', '/admin/system'),
    ('mock_or_dev_users', 'Akun mock/dev', 'Masih ada akun @dev.local', '/admin/users'),
  ];

  bool _bad(dynamic v) => v == true || (v is num && v > 0);

  @override
  Widget build(BuildContext context) {
    final problems = _defs.where((d) => _bad(checks[d.$1])).length;
    return SectionCard(
      title: 'Checklist go-live',
      subtitle: 'Kredensial Google OAuth & secret dicek manual (tidak terlihat dari DB)',
      icon: Icons.rocket_launch_rounded,
      trailing: problems == 0 ? const StatusBadge(Brand.green, 'Siap', icon: Icons.verified_rounded) : StatusBadge(Brand.amber, '$problems perlu dibereskan', icon: Icons.warning_amber_rounded),
      child: Column(children: [
        for (final d in _defs)
          Builder(builder: (context) {
            final v = checks[d.$1];
            final bad = _bad(v);
            return ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: Icon(bad ? Icons.error_outline_rounded : Icons.check_circle_rounded, color: bad ? Brand.amber : Brand.green),
              title: Text(d.$2, style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text(bad ? (v is num ? '${d.$3} ($v)' : d.$3) : 'OK'),
              trailing: bad && allowed(d.$4) ? TextButton(onPressed: () => context.go(d.$4), child: const Text('Perbaiki')) : null,
            );
          }),
      ]),
    );
  }
}

class _AuditHeadCard extends StatelessWidget {
  const _AuditHeadCard({required this.head, required this.canOpen});
  final J head;
  final bool canOpen;
  @override
  Widget build(BuildContext context) {
    final hash = head['hash'] as String?;
    return SectionCard(
      title: 'Rantai audit',
      subtitle: 'Kepala hash chain SHA-256 audit_logs',
      icon: Icons.link_rounded,
      trailing: canOpen ? TextButton(onPressed: () => context.go('/admin/audit'), child: const Text('Verifikasi')) : null,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        KeyValueGrid(minItemWidth: 160, [
          ('ID terakhir', MonoText(str(head['id']))),
          ('Status', hash == null ? const StatusBadge(Brand.grey, 'Kosong') : const StatusBadge(Brand.blue, 'Tercatat', icon: Icons.lock_rounded)),
        ]),
        if (hash != null) ...[
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: MonoText(hash, size: 11)),
            CopyButton(hash, tooltip: 'Copy hash'),
          ]),
        ],
        const SizedBox(height: 8),
        Text('Anchor harian dikirim ke email admin & repo privat. Jalankan verifikasi penuh di Audit Explorer.', style: Theme.of(context).textTheme.bodySmall),
      ]),
    );
  }
}

class _ModuleTile extends StatelessWidget {
  const _ModuleTile({required this.path, required this.label, required this.icon});
  final String path, label;
  final IconData icon;
  @override
  Widget build(BuildContext context) {
    final danger = path == '/admin/system';
    final c = danger ? Brand.red : Brand.blue;
    return Material(
      color: c.withValues(alpha: 0.05),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => context.go(path),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          child: Row(children: [
            Icon(icon, color: c, size: 22),
            const SizedBox(width: 12),
            Expanded(child: Text(label, style: const TextStyle(fontWeight: FontWeight.w700))),
            Icon(Icons.chevron_right_rounded, color: c.withValues(alpha: 0.6)),
          ]),
        ),
      ),
    );
  }
}
