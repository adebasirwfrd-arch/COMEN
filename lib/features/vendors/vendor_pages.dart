import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/session/failure_handler.dart';
import '../../core/session/session_controller.dart';
import '../../core/session/session_state.dart';
import '../../data/api.dart';
import '../../data/columns.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../contracts/contract_common.dart';
import 'vendor_common.dart';

const _taskCols = 'id,task_id,status,phase,title,doc_type_code,doc_label,contractor_id,due_date,is_mandatory,is_blocker,expiry_date,is_overdue,created_at,updated_at';

// ═══════════════════════════ LIST ═══════════════════════════
class _VendorRow {
  _VendorRow(this.c, this.docDone, this.docTotal, this.openContracts);
  final J c;
  final int docDone, docTotal, openContracts;
  String get status => c['status'] as String? ?? 'draft';
  int? get days => aslDaysLeft(c);
  String get ref => vendorRef(c['vendor_seq']);
}

/// Daftar vendor / kontraktor (WFRD, vendor.view).
class VendorListPage extends ConsumerStatefulWidget {
  const VendorListPage({super.key});
  @override
  ConsumerState<VendorListPage> createState() => _VendorListPageState();
}

class _VendorListPageState extends ConsumerState<VendorListPage> {
  late Future<List<_VendorRow>> _future = _load();
  StreamSubscription<String>? _sub;
  final _q = TextEditingController();
  String _group = 'all';
  String _sort = 'name';

  @override
  void initState() {
    super.initState();
    _sub = ref.read(notificationBus).stream.listen((_) {
      if (mounted) _reload();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _q.dispose();
    super.dispose();
  }

  Future<List<_VendorRow>> _load() async {
    final api = ref.read(apiProvider);
    final r = await Future.wait([
      api.select('contractors', Cols.contractors, build: (q) => q.order('legal_name').limit(2000)),
      api.select('v_task_tracking', 'contractor_id,status,is_mandatory', build: (q) => q.eq('scope', 'vendor').limit(20000)),
      api.select('contracts', 'contractor_id,status', build: (q) => q.not('status', 'in', '(closed,terminated)').limit(5000)),
    ]);
    final done = <String, int>{}, total = <String, int>{}, open = <String, int>{};
    for (final t in r[1]) {
      if (t['is_mandatory'] != true || const {'superseded', 'cancelled'}.contains(t['status'])) continue;
      final id = t['contractor_id'] as String;
      total[id] = (total[id] ?? 0) + 1;
      if (const {'approved', 'waived'}.contains(t['status'])) done[id] = (done[id] ?? 0) + 1;
    }
    for (final k in r[2]) {
      final id = k['contractor_id'] as String;
      open[id] = (open[id] ?? 0) + 1;
    }
    return [for (final c in r[0]) _VendorRow(c, done[c['id']] ?? 0, total[c['id']] ?? 0, open[c['id']] ?? 0)];
  }

  void _reload() => setState(() => _future = _load());

  bool _inGroup(_VendorRow v, String g) => switch (g) {
        'queue' => v.status == 'under_review',
        'active' => aslActive(v.c),
        'attention' => v.status == 'asl_expired' || (aslActiveStatuses.contains(v.status) && (v.days ?? 999) <= 60),
        'blocked' => const {'suspended', 'blacklisted', 'rejected'}.contains(v.status),
        'draft' => v.status == 'draft',
        _ => true,
      };

  @override
  Widget build(BuildContext context) {
    return PageScaffold(
      title: 'Vendor',
      subtitle: 'Registrasi, screening, dan Approved Supplier List (ASL)',
      actions: [IconButton(tooltip: 'Muat ulang', onPressed: _reload, icon: const Icon(Icons.refresh_rounded))],
      child: AsyncView<List<_VendorRow>>(
        future: _future,
        onRetry: _reload,
        builder: (context, all) {
          final q = _q.text.trim().toLowerCase();
          final rows = all.where((v) {
            if (!_inGroup(v, _group)) return false;
            if (q.isEmpty) return true;
            return [v.c['legal_name'], v.c['trading_name'], v.c['tax_id'], v.c['registration_no'], v.c['email_domain'], v.ref]
                .any((x) => (x ?? '').toString().toLowerCase().contains(q));
          }).toList();
          rows.sort((a, b) => switch (_sort) {
                'expiry' => (a.days ?? 99999).compareTo(b.days ?? 99999),
                'recent' => (b.c['submitted_at'] ?? b.c['created_at'] ?? '').toString().compareTo((a.c['submitted_at'] ?? a.c['created_at'] ?? '').toString()),
                _ => str(a.c['legal_name']).toLowerCase().compareTo(str(b.c['legal_name']).toLowerCase()),
              });
          int n(String g) => all.where((v) => _inGroup(v, g)).length;
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            ResponsiveGrid(minItemWidth: 220, children: [
              StatCard(label: 'Antrian review', value: '${n('queue')}', icon: Icons.inbox_rounded, color: Brand.blue, onTap: () => setState(() => _group = 'queue')),
              StatCard(label: 'ASL aktif', value: '${n('active')}', icon: Icons.verified_rounded, color: Brand.green, onTap: () => setState(() => _group = 'active')),
              StatCard(
                label: 'Perlu perhatian',
                value: '${n('attention')}',
                icon: Icons.event_busy_rounded,
                color: Brand.amber,
                caption: 'Kedaluwarsa / ≤ 60 hari',
                onTap: () => setState(() => _group = 'attention'),
              ),
              StatCard(label: 'Diblokir', value: '${n('blocked')}', icon: Icons.block_rounded, color: Brand.red, onTap: () => setState(() => _group = 'blocked')),
            ]),
            const SizedBox(height: 20),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
                    SizedBox(
                      width: 340,
                      child: TextField(
                        controller: _q,
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(
                          isDense: true,
                          prefixIcon: const Icon(Icons.search_rounded),
                          hintText: 'Cari nama, NPWP, domain, CMN-V…',
                          suffixIcon: _q.text.isEmpty
                              ? null
                              : IconButton(icon: const Icon(Icons.close_rounded, size: 18), onPressed: () => setState(_q.clear)),
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 200,
                      child: DropdownButtonFormField<String>(
                        initialValue: _sort,
                        isDense: true,
                        decoration: const InputDecoration(isDense: true, labelText: 'Urutkan', prefixIcon: Icon(Icons.sort_rounded)),
                        items: const [
                          DropdownMenuItem(value: 'name', child: Text('Nama')),
                          DropdownMenuItem(value: 'expiry', child: Text('ASL kedaluwarsa')),
                          DropdownMenuItem(value: 'recent', child: Text('Terbaru')),
                        ],
                        onChanged: (v) => setState(() => _sort = v ?? 'name'),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 12),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    for (final (g, l) in const [
                      ('all', 'Semua'),
                      ('queue', 'Under review'),
                      ('active', 'ASL aktif'),
                      ('attention', 'Perlu perhatian'),
                      ('blocked', 'Diblokir'),
                      ('draft', 'Draft'),
                    ])
                      ChoiceChip(label: Text('$l (${n(g)})'), selected: _group == g, onSelected: (_) => setState(() => _group = g)),
                  ]),
                ]),
              ),
            ),
            const SizedBox(height: 16),
            if (rows.isEmpty)
              EmptyState(
                icon: Icons.store_mall_directory_outlined,
                title: all.isEmpty ? 'Belum ada vendor' : 'Tidak ada vendor yang cocok',
                message: all.isEmpty ? 'Vendor muncul setelah kontraktor mendaftar atau diundang Admin.' : 'Ubah kata kunci atau filter.',
              )
            else
              LayoutBuilder(builder: (context, c) {
                if (c.maxWidth >= 900) {
                  return Card(
                    clipBehavior: Clip.antiAlias,
                    child: DataList(
                      columns: const ['Vendor', 'Status', 'ASL s.d.', 'Dokumen wajib', 'Kontrak aktif', 'Terdaftar'],
                      onTap: (i) => context.go('/vendors/${rows[i].c['id']}'),
                      rows: [for (final v in rows) _tableRow(v)],
                    ),
                  );
                }
                return Column(children: [for (final v in rows) _VendorCard(v: v)]);
              }),
          ]);
        },
      ),
    );
  }

  List<Widget> _tableRow(_VendorRow v) => [
        Row(mainAxisSize: MainAxisSize.min, children: [
          Avatar(name: v.c['legal_name'] as String?, radius: 16),
          const SizedBox(width: 10),
          Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(str(v.c['legal_name']), style: const TextStyle(fontWeight: FontWeight.w700)),
            Text('${v.ref} · ${str(v.c['country'])}', style: const TextStyle(fontSize: 12, color: Brand.grey)),
          ]),
        ]),
        StatusBadge.vendor(v.status),
        _ExpiryText(v.c),
        _DocProgress(done: v.docDone, total: v.docTotal),
        Text('${v.openContracts}', style: const TextStyle(fontWeight: FontWeight.w700)),
        Text(fmtDate(v.c['submitted_at'] ?? v.c['created_at'])),
      ];
}

class _ExpiryText extends StatelessWidget {
  const _ExpiryText(this.c);
  final J c;
  @override
  Widget build(BuildContext context) {
    final days = aslDaysLeft(c);
    if (days == null || c['status'] == 'rejected') return const Text('-', style: TextStyle(color: Brand.grey));
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(fmtDate(c['asl_expires_on']), style: const TextStyle(fontWeight: FontWeight.w600)),
      Text(days < 0 ? 'lewat ${-days} hari' : '$days hari lagi', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: aslExpiryColor(days))),
    ]);
  }
}

class _DocProgress extends StatelessWidget {
  const _DocProgress({required this.done, required this.total});
  final int done, total;
  @override
  Widget build(BuildContext context) {
    if (total == 0) return const Text('belum ada task', style: TextStyle(fontSize: 12, color: Brand.grey));
    final f = done / total;
    return SizedBox(
      width: 130,
      child: Row(children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: LinearProgressIndicator(value: f, minHeight: 6, color: f >= 1 ? Brand.green : Brand.blue, backgroundColor: Brand.blue.withValues(alpha: 0.1)),
          ),
        ),
        const SizedBox(width: 8),
        Text('$done/$total', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
      ]),
    );
  }
}

class _VendorCard extends StatelessWidget {
  const _VendorCard({required this.v});
  final _VendorRow v;
  @override
  Widget build(BuildContext context) => Card(
        margin: const EdgeInsets.only(bottom: 10),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => context.go('/vendors/${v.c['id']}'),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Avatar(name: v.c['legal_name'] as String?),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(str(v.c['legal_name']), style: const TextStyle(fontWeight: FontWeight.w800)),
                    Text(v.ref, style: const TextStyle(fontSize: 12, color: Brand.grey)),
                  ]),
                ),
                StatusBadge.vendor(v.status),
              ]),
              const SizedBox(height: 12),
              Wrap(spacing: 20, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
                _ExpiryText(v.c),
                _DocProgress(done: v.docDone, total: v.docTotal),
                Text('${v.openContracts} kontrak aktif', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
              ]),
            ]),
          ),
        ),
      );
}

// ═══════════════════════════ DETAIL ═══════════════════════════
class _Detail {
  _Detail(this.c, this.tasks, this.users, this.cards);
  final J c;
  final List<J> tasks;
  final List<J>? users;
  final Map<String, J> cards;
  String get status => c['status'] as String? ?? 'draft';
  List<J> get selfAssessments => jl(c['self_assessments']);
  List<J> get evaluations => jl(c['evaluations']);
  List<J> get contracts => jl(c['contracts']);
  J? get latestSa {
    for (final s in selfAssessments) {
      if (s['status'] == 'submitted') return s;
    }
    return null;
  }
}

/// Detail vendor: profil, screening, keputusan ASL, status, dokumen, kontrak, user.
class VendorDetailPage extends ConsumerStatefulWidget {
  const VendorDetailPage({super.key, required this.id});
  final String id;
  @override
  ConsumerState<VendorDetailPage> createState() => _VendorDetailPageState();
}

class _VendorDetailPageState extends ConsumerState<VendorDetailPage> {
  late Future<_Detail> _future = _load();
  StreamSubscription<String>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = ref.read(notificationBus).stream.listen((_) {
      if (mounted) _reload();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<_Detail> _load() async {
    final api = ref.read(apiProvider);
    final s = readSession(ref);
    final adminUsers = s != null && s.adminMode && s.can('admin.users.view');
    final r = await Future.wait<dynamic>([
      api.rpcMap('get_contractor_detail', {'p_contractor': widget.id}),
      api.select('v_task_tracking', _taskCols, build: (q) => q.eq('contractor_id', widget.id).eq('scope', 'vendor').order('due_date')),
      adminUsers
          ? api.rpc('admin_list_users', {'p_contractor': widget.id, 'p_limit': 200})
          : api.rpc('list_contractor_users', {'p_contractor': widget.id}).catchError((_) => null),
    ]);
    final c = r[0] as J;
    final evals = jl(c['evaluations']);
    final cards = await loadUserCards(api, [
      c['asl_decided_by'] as String?,
      c['registered_by'] as String?,
      ...evals.map((e) => e['screened_by'] as String?),
    ]);
    return _Detail(c, r[1] as List<J>, r[2] == null ? null : jl(r[2]), cards);
  }

  void _reload() => setState(() => _future = _load());

  Future<void> _screen(_Detail d) async {
    final r = await showDialog<J>(context: context, builder: (_) => _ScreenDialog(contractorId: widget.id, latestSa: d.latestSa));
    if (r == null || !mounted) return;
    showSnack(context, 'Screening tersimpan — total ${r['total']} · rekomendasi ${_recLabel[r['recommendation']] ?? r['recommendation']}');
    _reload();
  }

  Future<void> _decide(_Detail d) async {
    final ok = await showDialog<bool>(context: context, builder: (_) => _DecideDialog(d: d, contractorId: widget.id));
    if (ok == true) _reload();
  }

  Future<void> _requestInfo() async {
    final msg = await showReasonDialog(
      context,
      title: 'Minta informasi tambahan',
      message: 'Status vendor kembali ke Draft dan kontraktor diminta melengkapi registrasi. Pesan dikirim ke kontraktor.',
      fieldLabel: 'Pesan ke kontraktor',
      confirmLabel: 'Kirim permintaan',
      minLength: 10,
    );
    if (msg == null || !mounted) return;
    final ok = await runOk(context, ref, () => ref.read(apiProvider).rpc('vendor_request_info', {'p_contractor': widget.id, 'p_message': msg}),
        success: 'Permintaan informasi dikirim');
    if (ok) _reload();
  }

  Future<void> _setStatus(_Detail d, String target) async {
    String? reason;
    if (target == 'blacklisted') {
      reason = await showConfirmPhraseDialog(
        context,
        title: 'Blacklist ${str(d.c['legal_name'])}?',
        message: 'Vendor tidak bisa diberi kontrak baru. Process Owner kontrak berjalan diberi notifikasi untuk mempertimbangkan hold.',
        phrase: 'BLACKLIST',
      );
    } else {
      reason = await showReasonDialog(
        context,
        title: target == 'suspended' ? 'Suspend vendor?' : 'Pulihkan vendor (reinstate)?',
        message: target == 'suspended'
            ? 'Vendor tidak bisa diberi kontrak baru selama suspended. Process Owner kontrak berjalan diberi notifikasi.'
            : 'Status kembali ke ${StatusStyle.vendor(target).$2}. Hanya bisa bila ASL belum kedaluwarsa.',
        confirmLabel: target == 'suspended' ? 'Suspend' : 'Reinstate',
        destructive: target == 'suspended',
      );
    }
    if (reason == null || !mounted) return;
    final ok = await runOk(
      context,
      ref,
      () => ref.read(apiProvider).rpc('set_vendor_status', {'p_contractor': widget.id, 'p_status': target, 'p_reason': reason}),
      success: 'Status vendor: ${StatusStyle.vendor(target).$2}',
    );
    if (ok) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final s = watchSession(ref);
    return AsyncView<_Detail>(
      future: _future,
      onRetry: _reload,
      builder: (context, d) {
        final c = d.c;
        final st = d.status;
        final canScreen = c['can_screen'] == true && const {'under_review', 'asl_expired', 'asl_approved', 'asl_conditional'}.contains(st);
        final canDecide = c['can_decide_asl'] == true && const {'under_review', 'asl_expired', 'asl_approved', 'asl_conditional'}.contains(st);
        final canInfo = (s?.can('vendor.edit') ?? false) && st == 'under_review';
        final canSuspend = s?.can('vendor.suspend') ?? false;
        final days = aslDaysLeft(c);
        final reinstateTo = (c['asl_conditions'] as String?)?.isNotEmpty ?? false ? 'asl_conditional' : 'asl_approved';
        return PageScaffold(
          title: str(c['legal_name']),
          subtitle: [str(c['vendor_ref'], vendorRef(c['vendor_seq'])), if (c['trading_name'] != null) c['trading_name'] as String].join(' · '),
          leading: IconButton(tooltip: 'Daftar vendor', onPressed: () => context.go('/vendors'), icon: const Icon(Icons.arrow_back_rounded)),
          actions: [
            if (canScreen)
              OutlinedButton.icon(
                onPressed: d.latestSa == null ? null : () => _screen(d),
                icon: const Icon(Icons.fact_check_rounded),
                label: const Text('Screening'),
              ),
            if (canDecide) FilledButton.icon(onPressed: () => _decide(d), icon: const Icon(Icons.gavel_rounded), label: const Text('Keputusan ASL')),
            if (canInfo || canSuspend)
              MenuAnchor(
                builder: (context, ctl, _) => IconButton(
                  tooltip: 'Aksi lain',
                  onPressed: () => ctl.isOpen ? ctl.close() : ctl.open(),
                  icon: const Icon(Icons.more_vert_rounded),
                ),
                menuChildren: [
                  if (canInfo) MenuItemButton(leadingIcon: const Icon(Icons.forum_rounded), onPressed: _requestInfo, child: const Text('Minta informasi tambahan')),
                  if (canSuspend && !const {'suspended', 'blacklisted'}.contains(st))
                    MenuItemButton(leadingIcon: const Icon(Icons.pause_circle_rounded, color: Brand.red), onPressed: () => _setStatus(d, 'suspended'), child: const Text('Suspend')),
                  if (canSuspend && st == 'suspended')
                    MenuItemButton(
                      leadingIcon: const Icon(Icons.play_circle_rounded, color: Brand.green),
                      onPressed: (days ?? -1) >= 0 ? () => _setStatus(d, reinstateTo) : null,
                      child: Text((days ?? -1) >= 0 ? 'Reinstate (${StatusStyle.vendor(reinstateTo).$2})' : 'Reinstate (ASL kedaluwarsa)'),
                    ),
                  if (canSuspend && st != 'blacklisted')
                    MenuItemButton(leadingIcon: const Icon(Icons.block_rounded, color: Brand.red), onPressed: () => _setStatus(d, 'blacklisted'), child: const Text('Blacklist')),
                ],
              ),
            IconButton(tooltip: 'Muat ulang', onPressed: _reload, icon: const Icon(Icons.refresh_rounded)),
          ],
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _hero(d),
            const SizedBox(height: 16),
            ..._banners(d, canScreen, canDecide),
            LayoutBuilder(builder: (context, box) {
              final wide = box.maxWidth >= 1100;
              final left = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                CompanyProfileCard(c: c),
                const SizedBox(height: 16),
                VendorTasksCard(
                  tasks: d.tasks,
                  footer: const InfoBanner(
                    message: 'Task dokumen vendor dibuat otomatis oleh sistem (akun aktif + registrasi terkirim). Pembuatan ulang manual tidak tersedia dari aplikasi.',
                    icon: Icons.auto_mode_rounded,
                  ),
                ),
                const SizedBox(height: 16),
                SelfAssessmentCard(items: d.selfAssessments, emptyMessage: 'Kontraktor belum mengirim self-assessment — screening belum bisa dilakukan.'),
                const SizedBox(height: 16),
                _evaluationsCard(d, canScreen),
              ]);
              final right = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                AslStatusCard(c: c, decidedBy: d.cards[c['asl_decided_by']]),
                const SizedBox(height: 16),
                ContractMiniList(contracts: d.contracts),
                const SizedBox(height: 16),
                _usersCard(d, s),
                if (c['internal_notes'] != null) ...[
                  const SizedBox(height: 16),
                  SectionCard(
                    title: 'Catatan internal WFRD',
                    subtitle: 'Tidak terlihat oleh kontraktor',
                    icon: Icons.lock_rounded,
                    child: SelectableText(str(c['internal_notes'])),
                  ),
                ],
              ]);
              if (!wide) return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [right, const SizedBox(height: 16), left]);
              return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(flex: 3, child: left),
                const SizedBox(width: 16),
                Expanded(flex: 2, child: right),
              ]);
            }),
          ]),
        );
      },
    );
  }

  Widget _hero(_Detail d) {
    final c = d.c;
    final (color, label) = StatusStyle.vendor(d.status);
    final days = aslDaysLeft(c);
    final open = d.tasks.where((t) => const {'open', 'awaiting_email', 'file_issue', 'revise'}.contains(t['status'])).length;
    return HeroHeader(
      title: str(c['legal_name']),
      icon: Icons.storefront_rounded,
      lines: [
        '${countryLabel(c['country'])} · NPWP ${str(c['tax_id'])}',
        if (c['submitted_at'] != null) 'Registrasi dikirim ${fmtDate(c['submitted_at'])}',
      ],
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(999)),
        child: Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w900)),
      ),
      chips: [
        HeroChip(str(c['vendor_ref'], vendorRef(c['vendor_seq'])), icon: Icons.tag_rounded),
        if (days != null && d.status != 'rejected') HeroChip(days < 0 ? 'ASL lewat ${-days} hari' : 'ASL $days hari lagi', icon: Icons.event_available_rounded),
        HeroChip('$open task perlu aksi', icon: Icons.pending_actions_rounded),
        HeroChip('${d.contracts.length} kontrak', icon: Icons.handshake_rounded),
        if (c['email_domain'] != null) HeroChip('@${c['email_domain']}', icon: Icons.alternate_email_rounded),
      ],
    );
  }

  List<Widget> _banners(_Detail d, bool canScreen, bool canDecide) {
    final out = <Widget>[];
    void add(Widget w) => out.addAll([w, const SizedBox(height: 12)]);
    final mandatoryOpen = d.tasks.where((t) => t['is_mandatory'] == true && !const {'approved', 'waived', 'superseded', 'cancelled'}.contains(t['status'])).length;
    if (d.status == 'under_review') {
      if (d.latestSa == null) {
        add(const InfoBanner(message: 'Menunggu self-assessment dari kontraktor sebelum screening.', icon: Icons.hourglass_top_rounded));
      } else if (d.evaluations.isEmpty && canScreen) {
        add(const InfoBanner(message: 'Self-assessment sudah dikirim — siap di-screening.', color: Brand.green, icon: Icons.fact_check_rounded));
      }
      if (mandatoryOpen > 0 && canDecide) {
        add(InfoBanner(message: '$mandatoryOpen dokumen vendor wajib belum approved/waived — ASL approve/conditional akan ditolak server.', color: Brand.amber, icon: Icons.folder_off_rounded));
      }
    }
    if (d.status == 'draft' && (d.c['status_reason'] as String?) != null) {
      add(InfoBanner(message: 'Menunggu kontraktor melengkapi: ${d.c['status_reason']}', color: Brand.amber, icon: Icons.forum_rounded));
    }
    if (d.status == 'asl_expired') add(const InfoBanner(message: 'ASL kedaluwarsa — vendor tidak bisa diberi kontrak baru sampai re-evaluasi.', color: Brand.red, icon: Icons.event_busy_rounded));
    return out;
  }

  Widget _evaluationsCard(_Detail d, bool canScreen) {
    if (d.c['evaluations'] == null) return const SizedBox.shrink();
    final evals = d.evaluations;
    return SectionCard(
      title: 'Screening WFRD',
      subtitle: '40% program HSE · 30% performa (TRIR) · 20% training · 10% equipment',
      icon: Icons.fact_check_rounded,
      trailing: canScreen && d.latestSa != null ? TextButton.icon(onPressed: () => _screen(d), icon: const Icon(Icons.add_rounded), label: const Text('Screening baru')) : null,
      child: evals.isEmpty
          ? const EmptyState(icon: Icons.fact_check_outlined, title: 'Belum ada screening')
          : Column(children: [
              for (var i = 0; i < evals.length; i++) ...[
                if (i > 0) const Divider(height: 24),
                _EvalTile(e: evals[i], screener: d.cards[evals[i]['screened_by']], latest: i == 0),
              ],
            ]),
    );
  }

  Widget _usersCard(_Detail d, SessionState? s) {
    final users = d.users;
    return SectionCard(
      title: 'User kontraktor',
      icon: Icons.people_alt_rounded,
      trailing: users == null ? null : StatusBadge(Brand.blue, '${users.length}'),
      child: users == null
          ? Text(
              'Daftar user kontraktor tidak dapat dimuat.',
              style: const TextStyle(color: Brand.grey),
            )
          : users.isEmpty
              ? const Text('Belum ada user tertaut.', style: TextStyle(color: Brand.grey))
              : Column(children: [
                  for (final u in users)
                    UserCardTile(
                      dense: true,
                      card: {'id': u['id'], 'full_name': u['full_name'] ?? u['email'], 'avatar_url': u['avatar_url'], 'job_title': u['email']},
                      caption: jl(u['roles']).map((r) => r['role']).whereType<String>().join(', '),
                      trailing: StatusBadge.account(u['status'] as String?),
                    ),
                ]),
    );
  }
}

const _recLabel = {'approve': 'Approve', 'conditional': 'Conditional', 'reject': 'Reject'};
Color _recColor(dynamic r) => switch (r) { 'approve' => Brand.green, 'conditional' => Brand.amber, _ => Brand.red };

class _EvalTile extends StatelessWidget {
  const _EvalTile({required this.e, required this.screener, required this.latest});
  final J e;
  final J? screener;
  final bool latest;
  @override
  Widget build(BuildContext context) {
    final sc = jm(e['scores']);
    Widget bar(String label, dynamic v, double w) {
      final n = (v as num?)?.toDouble() ?? 0;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          SizedBox(width: 150, child: Text('$label (${(w * 100).round()}%)', style: const TextStyle(fontSize: 12))),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(99),
              child: LinearProgressIndicator(value: n / 100, minHeight: 7, color: n >= 75 ? Brand.green : n >= 60 ? Brand.amber : Brand.red, backgroundColor: Brand.grey.withValues(alpha: 0.12)),
            ),
          ),
          SizedBox(width: 40, child: Text(n.toStringAsFixed(0), textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12))),
        ]),
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Container(
          width: 64,
          height: 64,
          alignment: Alignment.center,
          decoration: BoxDecoration(shape: BoxShape.circle, color: _recColor(e['recommendation']).withValues(alpha: 0.12)),
          child: Text((e['total'] as num?)?.toStringAsFixed(0) ?? '-', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: _recColor(e['recommendation']))),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(spacing: 6, children: [
              StatusBadge(_recColor(e['recommendation']), 'Rekomendasi: ${_recLabel[e['recommendation']] ?? str(e['recommendation'])}'),
              if (latest) const StatusBadge(Brand.blue, 'Terbaru'),
              if (sc['legal_gate'] == false) const StatusBadge(Brand.red, 'Legal gate gagal', icon: Icons.gavel_rounded),
            ]),
            const SizedBox(height: 4),
            Text('${fmtDateTime(e['screened_at'])} · ${str(screener?['full_name'])}', style: Theme.of(context).textTheme.bodySmall),
          ]),
        ),
      ]),
      const SizedBox(height: 10),
      bar('Program HSE', sc['hse_program'], 0.4),
      bar('Performa${sc['trir_avg'] == null ? '' : ' · TRIR ${sc['trir_avg']}'}', sc['performance'], 0.3),
      bar('Training', sc['training'], 0.2),
      bar('Equipment', sc['equipment'], 0.1),
      if ((e['conditions'] as String?)?.isNotEmpty ?? false) ...[
        const SizedBox(height: 8),
        Text('Syarat / catatan: ${e['conditions']}', style: const TextStyle(fontStyle: FontStyle.italic)),
      ],
    ]);
  }
}

// ─────────────────────────── Dialog screening ───────────────────────────
class _ScreenDialog extends ConsumerStatefulWidget {
  const _ScreenDialog({required this.contractorId, required this.latestSa});
  final String contractorId;
  final J? latestSa;
  @override
  ConsumerState<_ScreenDialog> createState() => _ScreenDialogState();
}

class _ScreenDialogState extends ConsumerState<_ScreenDialog> {
  double _hse = 70, _training = 70, _equipment = 70;
  bool _legal = true, _busy = false;
  final _cond = TextEditingController();

  num? get _trir => jm(widget.latestSa?['computed'])['trir_avg'] as num?;
  int get _perf {
    final t = _trir;
    return t == null ? 30 : t <= 0.5 ? 100 : t <= 1.0 ? 80 : t <= 2.0 ? 60 : 30;
  }

  double get _total => 0.4 * _hse + 0.3 * _perf + 0.2 * _training + 0.1 * _equipment;
  String get _rec => !_legal ? 'reject' : _total >= 75 ? 'approve' : _total >= 60 ? 'conditional' : 'reject';

  Future<void> _submit() async {
    setState(() => _busy = true);
    final r = await runAction<J>(
      context,
      ref,
      () => ref.read(apiProvider).rpcMap('screen_vendor', {
        'p_contractor': widget.contractorId,
        'p_scores': {'hse_program': _hse.round(), 'training': _training.round(), 'equipment': _equipment.round(), 'legal_gate': _legal},
        'p_conditions': trimOrNull(_cond),
      }),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (r != null) Navigator.pop(context, r);
  }

  Widget _slider(String label, String help, double v, ValueChanged<double> on) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(label, style: const TextStyle(fontWeight: FontWeight.w700))),
          Text(v.round().toString(), style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
        ]),
        Text(help, style: Theme.of(context).textTheme.bodySmall),
        Slider(value: v, min: 0, max: 100, divisions: 20, label: v.round().toString(), onChanged: on),
      ]);

  @override
  Widget build(BuildContext context) {
    final rec = _rec;
    return AlertDialog(
      icon: const Icon(Icons.fact_check_rounded, color: Brand.blue, size: 36),
      title: const Text('Screening vendor'),
      content: SizedBox(
        width: 540,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            InfoBanner(
              message: 'Self-assessment ${widget.latestSa?['year'] ?? '-'} · TRIR rata-rata ${_trir ?? '—'} → skor performa $_perf (dihitung server).',
              icon: Icons.analytics_rounded,
            ),
            const SizedBox(height: 16),
            _slider('Program HSE (40%)', 'Kebijakan, HSE Manager, BBS, pelaporan insiden, corrective action', _hse, (v) => setState(() => _hse = v)),
            _slider('Training (20%)', 'Sertifikasi, First Aid, H2S, training matrix', _training, (v) => setState(() => _training = v)),
            _slider('Equipment (10%)', 'Daftar equipment, sertifikasi, preventive maintenance', _equipment, (v) => setState(() => _equipment = v)),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _legal,
              onChanged: (v) => setState(() => _legal = v),
              title: const Text('Legal gate terpenuhi'),
              subtitle: const Text('ISO / K3 / SMK3 / clean reference / laporan keuangan valid. Gagal → rekomendasi reject.'),
            ),
            TextField(controller: _cond, maxLines: 3, maxLength: 2000, decoration: const InputDecoration(labelText: 'Syarat / catatan screening')),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: _recColor(rec).withValues(alpha: 0.08), borderRadius: BorderRadius.circular(14), border: Border.all(color: _recColor(rec).withValues(alpha: 0.3))),
              child: Row(children: [
                Text(_total.toStringAsFixed(1), style: TextStyle(fontSize: 30, fontWeight: FontWeight.w900, color: _recColor(rec))),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Perkiraan rekomendasi: ${_recLabel[rec]}', style: TextStyle(fontWeight: FontWeight.w800, color: _recColor(rec))),
                    const Text('≥ 75 approve · 60–74 conditional · < 60 reject', style: TextStyle(fontSize: 12)),
                  ]),
                ),
              ]),
            ),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
        FilledButton.icon(
          onPressed: _busy ? null : _submit,
          icon: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.save_rounded),
          label: const Text('Simpan screening'),
        ),
      ],
    );
  }
}

// ─────────────────────────── Dialog keputusan ASL ───────────────────────────
class _DecideDialog extends ConsumerStatefulWidget {
  const _DecideDialog({required this.d, required this.contractorId});
  final _Detail d;
  final String contractorId;
  @override
  ConsumerState<_DecideDialog> createState() => _DecideDialogState();
}

class _DecideDialogState extends ConsumerState<_DecideDialog> {
  late String _decision = switch (widget.d.evaluations.firstOrNull?['recommendation']) { 'conditional' => 'conditional', 'reject' => 'reject', _ => 'approve' };
  late final _cond = TextEditingController(text: widget.d.c['asl_conditions'] as String? ?? widget.d.evaluations.firstOrNull?['conditions'] as String?);
  final _reason = TextEditingController();
  bool _busy = false;

  Future<void> _submit() async {
    setState(() => _busy = true);
    final ok = await runOk(
      context,
      ref,
      () => ref.read(apiProvider).rpc('decide_asl', {
        'p_contractor': widget.contractorId,
        'p_decision': _decision,
        'p_conditions': _decision == 'reject' ? null : trimOrNull(_cond),
        'p_reason': _reason.text.trim(),
      }),
      success: 'Keputusan ASL tersimpan',
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.d;
    final eval = d.evaluations.firstOrNull;
    final fat = (jm(d.latestSa?['computed'])['fatality_3y'] as num?) ?? 0;
    final missing = d.tasks.where((t) => t['is_mandatory'] == true && !const {'approved', 'waived', 'superseded', 'cancelled'}.contains(t['status'])).toList();
    final ok = !_busy && _reason.text.trim().length >= 5 && (_decision != 'conditional' || _cond.text.trim().isNotEmpty);
    final positive = _decision != 'reject';
    return AlertDialog(
      icon: const Icon(Icons.gavel_rounded, color: Brand.blue, size: 36),
      title: const Text('Keputusan ASL'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (eval != null)
              InfoBanner(
                message: 'Screening terakhir: total ${eval['total']} → rekomendasi ${_recLabel[eval['recommendation']] ?? eval['recommendation']}',
                color: _recColor(eval['recommendation']),
                icon: Icons.fact_check_rounded,
              )
            else
              const InfoBanner(message: 'Belum ada screening — hanya keputusan reject yang diizinkan server.', color: Brand.amber, icon: Icons.warning_amber_rounded),
            const SizedBox(height: 16),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'approve', icon: Icon(Icons.verified_rounded), label: Text('Approve')),
                ButtonSegment(value: 'conditional', icon: Icon(Icons.rule_rounded), label: Text('Conditional')),
                ButtonSegment(value: 'reject', icon: Icon(Icons.cancel_rounded), label: Text('Reject')),
              ],
              selected: {_decision},
              onSelectionChanged: (v) => setState(() => _decision = v.first),
            ),
            const SizedBox(height: 12),
            if (positive) ...[
              Text('ASL berlaku 2 tahun sejak hari ini (s.d. ${fmtDate(DateTime.now().add(const Duration(days: 730)).toIso8601String())}).', style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 10),
              if (missing.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: InfoBanner(
                    message: 'Dokumen wajib belum approved: ${missing.map((t) => t['doc_type_code']).toSet().join(', ')}',
                    color: Brand.red,
                    icon: Icons.folder_off_rounded,
                  ),
                ),
              if (fat > 0)
                const Padding(
                  padding: EdgeInsets.only(bottom: 10),
                  child: InfoBanner(message: 'Fatality 3 tahun terakhir — hanya pemegang risk.approve.critical (HSE Director) yang bisa menyetujui.', color: Brand.red, icon: Icons.warning_rounded),
                ),
              TextField(
                controller: _cond,
                maxLines: 3,
                maxLength: 2000,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(labelText: _decision == 'conditional' ? 'Syarat ASL *' : 'Syarat ASL (opsional)'),
              ),
            ],
            TextField(
              controller: _reason,
              maxLines: 3,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(labelText: 'Alasan keputusan *', helperText: 'Minimal 5 karakter · dikirim ke kontraktor & tercatat di audit log'),
            ),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
        FilledButton.icon(
          style: _decision == 'reject' ? FilledButton.styleFrom(backgroundColor: Brand.red) : null,
          onPressed: ok ? _submit : null,
          icon: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.gavel_rounded),
          label: Text('Simpan: ${_recLabel[_decision]}'),
        ),
      ],
    );
  }
}
