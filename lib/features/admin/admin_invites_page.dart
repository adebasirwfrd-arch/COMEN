import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/session/contract_classification.dart';
import '../../ui/classification_badges.dart';
import '../../data/api.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'admin_common.dart';
import 'admin_widgets.dart';

String _inviteState(J i) {
  if (i['accepted_at'] != null) return 'accepted';
  if (i['revoked_at'] != null) return 'revoked';
  final exp = parseDate(i['expires_at']);
  if (exp != null && exp.isBefore(DateTime.now())) return 'expired';
  return 'active';
}

StatusBadge _inviteBadge(String s) => switch (s) {
      'accepted' => const StatusBadge(Brand.green, 'Diterima', icon: Icons.how_to_reg_rounded),
      'revoked' => const StatusBadge(Brand.grey, 'Dicabut', icon: Icons.block_rounded),
      'expired' => const StatusBadge(Brand.amber, 'Kedaluwarsa', icon: Icons.timer_off_outlined),
      _ => const StatusBadge(Brand.blue, 'Aktif', icon: Icons.mark_email_unread_rounded),
    };

class AdminInvitesPage extends ConsumerStatefulWidget {
  const AdminInvitesPage({super.key});
  @override
  ConsumerState<AdminInvitesPage> createState() => _AdminInvitesPageState();
}

class _AdminInvitesPageState extends ConsumerState<AdminInvitesPage> {
  late Future<List<J>> _future = _load();
  String _state = 'active';
  String _q = '';

  Future<List<J>> _load() => ref.read(apiProvider).select('user_invites',
      'id,email,role_id,scope_type,scope_id,contractor_id,contractor_level,role_expires_at,note,invited_by,expires_at,accepted_at,accepted_by,revoked_at,created_at',
      build: (q) => q.order('created_at', ascending: false).limit(500));

  void _reload() => setState(() => _future = _load());

  Future<void> _create() async {
    final lookups = await ref.read(adminLookupsProvider.future);
    if (!mounted) return;
    final g = await showRoleGrantDialog(context, title: 'Undang user', mode: RoleGrantMode.invite, lookups: lookups, session: sessionOf(ref));
    if (g == null || !mounted) return;
    final ok = await adminRun(
        context,
        ref,
        () => ref.read(apiProvider).rpc('admin_create_invite', {
              'p_email': g.email,
              'p_role_key': g.roleKey,
              'p_scope_type': g.scopeType,
              'p_scope_id': g.scopeId,
              'p_contractor': g.contractorId,
              'p_role_expires_at': g.expiresIso,
              'p_note': g.note,
              'p_reason': g.reason,
              'p_contractor_level': g.contractorLevel?.code,
            }),
        success: 'Undangan terkirim ke ${g.email}');
    if (ok) _reload();
  }

  Future<void> _revoke(J i) async {
    final ok = await withReason(context, ref,
        title: 'Cabut undangan',
        message: 'Undangan untuk ${i['email']} tidak berlaku lagi.',
        confirmLabel: 'Cabut',
        destructive: true,
        success: 'Undangan dicabut',
        action: (r) => ref.read(apiProvider).rpc('admin_revoke_invite', {'p_invite': i['id'], 'p_reason': r}));
    if (ok) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final lookups = ref.watch(adminLookupsProvider).valueOrNull;
    return AdminScaffold(
      title: 'Invitations',
      subtitle: 'Undang user dengan role & scope yang sudah ditentukan · berlaku 14 hari',
      actions: [
        FilledButton.icon(onPressed: _create, icon: const Icon(Icons.person_add_alt_1_rounded), label: const Text('Undang user')),
        OutlinedButton.icon(onPressed: _reload, icon: const Icon(Icons.refresh_rounded), label: const Text('Muat ulang')),
      ],
      child: AsyncView<List<J>>(
        future: _future,
        onRetry: _reload,
        builder: (context, all) {
          final counts = <String, int>{};
          for (final i in all) {
            counts.update(_inviteState(i), (v) => v + 1, ifAbsent: () => 1);
          }
          final q = _q.toLowerCase();
          final list = all.where((i) => (_state == 'all' || _inviteState(i) == _state) && (q.isEmpty || str(i['email'], '').contains(q))).toList();
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            ResponsiveGrid(minItemWidth: 200, children: [
              StatCard(label: 'Aktif', value: '${counts['active'] ?? 0}', icon: Icons.mark_email_unread_rounded, color: Brand.blue, onTap: () => setState(() => _state = 'active')),
              StatCard(label: 'Diterima', value: '${counts['accepted'] ?? 0}', icon: Icons.how_to_reg_rounded, color: Brand.green, onTap: () => setState(() => _state = 'accepted')),
              StatCard(label: 'Kedaluwarsa', value: '${counts['expired'] ?? 0}', icon: Icons.timer_off_outlined, color: Brand.amber, onTap: () => setState(() => _state = 'expired')),
              StatCard(label: 'Dicabut', value: '${counts['revoked'] ?? 0}', icon: Icons.block_rounded, color: Brand.grey, onTap: () => setState(() => _state = 'revoked')),
            ]),
            const SizedBox(height: 16),
            TableCard(
              count: list.length,
              toolbar: [
                AdminSearchField(hint: 'Cari email', onChanged: (v) => setState(() => _q = v)),
                SegmentedButton<String>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: 'active', label: Text('Aktif')),
                    ButtonSegment(value: 'accepted', label: Text('Diterima')),
                    ButtonSegment(value: 'expired', label: Text('Kedaluwarsa')),
                    ButtonSegment(value: 'revoked', label: Text('Dicabut')),
                    ButtonSegment(value: 'all', label: Text('Semua')),
                  ],
                  selected: {_state},
                  onSelectionChanged: (v) => setState(() => _state = v.first),
                ),
              ],
              child: list.isEmpty && all.isEmpty
                  ? EmptyState(
                      icon: Icons.outgoing_mail,
                      title: 'Belum ada undangan',
                      message: 'Undang user agar langsung aktif dengan role yang tepat setelah login pertama.',
                      action: FilledButton.icon(onPressed: _create, icon: const Icon(Icons.person_add_alt_1_rounded), label: const Text('Undang user')),
                    )
                  : DataList(
                      empty: 'Tidak ada undangan pada filter ini',
                      columns: const ['Email', 'Role', 'Scope / contractor', 'Status', 'Dikirim', 'Berlaku s/d', ''],
                      rows: [
                        for (final i in list)
                          [
                            CellText(str(i['email']), subtitle: i['note'] as String?),
                            Wrap(spacing: 6, children: [
                              Text(lookups?.roleName(i['role_id'] as String?) ?? shortId(i['role_id']), style: const TextStyle(fontWeight: FontWeight.w600)),
                              if (i['role_expires_at'] != null) StatusBadge(Brand.amber, 'role s/d ${fmtDate(i['role_expires_at'])}'),
                              if (ContractorUserLevel.tryCode(i['contractor_level'] as String?) case final lv?) LevelBadge(lv),
                            ]),
                            Text(i['contractor_id'] != null
                                ? (lookups?.contractorName(i['contractor_id'] as String?) ?? shortId(i['contractor_id']))
                                : (lookups?.scopeLabel(i['scope_type'] as String?, i['scope_id'] as String?) ?? str(i['scope_type']))),
                            _inviteBadge(_inviteState(i)),
                            Text(fmtRelative(i['created_at'])),
                            Text(i['accepted_at'] != null ? 'Diterima ${fmtDate(i['accepted_at'])}' : fmtDate(i['expires_at'])),
                            _inviteState(i) == 'active'
                                ? TextButton.icon(
                                    style: TextButton.styleFrom(foregroundColor: Brand.red),
                                    onPressed: () => _revoke(i),
                                    icon: const Icon(Icons.cancel_schedule_send_rounded, size: 18),
                                    label: const Text('Cabut'),
                                  )
                                : const SizedBox.shrink(),
                          ],
                      ],
                    ),
            ),
          ]);
        },
      ),
    );
  }
}
