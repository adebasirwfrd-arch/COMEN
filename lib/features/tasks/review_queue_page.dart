import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/session/session_controller.dart';
import '../../data/api.dart';
import '../../ui/labels.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

typedef J = Map<String, dynamic>;

/// Status SLA review: lewat (merah), < 24 jam (oranye), aman (hijau), tanpa SLA (abu).
enum _Sla { late, soon, ok, none }

_Sla _slaOf(dynamic due) {
  final d = parseDate(due);
  if (d == null) return _Sla.none;
  final diff = d.difference(DateTime.now());
  if (diff.isNegative) return _Sla.late;
  if (diff.inHours < 24) return _Sla.soon;
  return _Sla.ok;
}

(Color, String) _slaStyle(dynamic due) {
  final d = parseDate(due);
  if (d == null) return (Brand.grey, 'Tanpa SLA');
  final diff = d.difference(DateTime.now());
  final h = diff.inHours.abs();
  final span = h >= 48 ? '${(h / 24).floor()} hr' : (h >= 1 ? '$h jam' : '${diff.inMinutes.abs()} mnt');
  return switch (_slaOf(due)) {
    _Sla.late => (Brand.red, 'SLA −$span'),
    _Sla.soon => (const Color(0xFFDC6803), 'SLA $span'),
    _ => (Brand.green, 'SLA $span'),
  };
}

class ReviewQueuePage extends ConsumerStatefulWidget {
  const ReviewQueuePage({super.key});
  @override
  ConsumerState<ReviewQueuePage> createState() => _ReviewQueuePageState();
}

class _ReviewQueuePageState extends ConsumerState<ReviewQueuePage> {
  late Future<List<J>> _future;
  StreamSubscription<String>? _sub;
  Timer? _tick;
  String _contract = '', _kind = '', _sla = '', _email = '', _q = '';

  @override
  void initState() {
    super.initState();
    _future = _load();
    _sub = ref.read(notificationBus).stream.listen((_) => _reload());
    _tick = Timer.periodic(const Duration(minutes: 1), (_) => mounted ? setState(() {}) : null);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _tick?.cancel();
    super.dispose();
  }

  Future<List<J>> _load() => ref.read(apiProvider).rpcList('get_review_queue', {'p_limit': 500});

  void _reload() {
    if (mounted) setState(() => _future = _load());
  }

  bool get _filtered => _contract.isNotEmpty || _kind.isNotEmpty || _sla.isNotEmpty || _email.isNotEmpty || _q.isNotEmpty;

  void _reset() => setState(() {
        _contract = '';
        _kind = '';
        _sla = '';
        _email = '';
        _q = '';
      });

  List<J> _apply(List<J> rows) => rows.where((r) {
        if (_contract == '-' && r['contract_no'] != null) return false;
        if (_contract.isNotEmpty && _contract != '-' && r['contract_no'] != _contract) return false;
        if (_kind.isNotEmpty && r['kind'] != _kind) return false;
        if (_sla.isNotEmpty && _slaOf(r['review_due_at']).name != _sla) return false;
        if (_email == 'yes' && r['email_verified'] != true) return false;
        if (_email == 'no' && r['email_verified'] == true) return false;
        if (_q.isNotEmpty) {
          final q = _q.toLowerCase();
          if (!'${r['task_id']} ${r['title']} ${r['contractor_name']}'.toLowerCase().contains(q)) return false;
        }
        return true;
      }).toList()
        ..sort((a, b) {
          final da = parseDate(a['review_due_at']), db = parseDate(b['review_due_at']);
          if (da == null && db == null) return 0;
          if (da == null) return 1;
          if (db == null) return -1;
          return da.compareTo(db);
        });

  @override
  Widget build(BuildContext context) {
    return PageScaffold(
      title: 'Antrean review',
      subtitle: 'Dokumen yang menunggu keputusan Anda — diurutkan berdasarkan SLA review',
      actions: [
        OutlinedButton.icon(onPressed: () => context.go('/tasks?status=submitted'), icon: const Icon(Icons.list_alt_rounded), label: const Text('Daftar task')),
        IconButton(tooltip: 'Muat ulang', onPressed: _reload, icon: const Icon(Icons.refresh_rounded)),
      ],
      child: AsyncView<List<J>>(
        future: _future,
        onRetry: _reload,
        builder: (context, rows) {
          final contracts = <String>{for (final r in rows) if (r['contract_no'] != null) r['contract_no'] as String}.toList()..sort();
          final hasVendor = rows.any((r) => r['contract_no'] == null);
          final kinds = <String>{for (final r in rows) if (r['kind'] != null) r['kind'] as String};
          final late = rows.where((r) => _slaOf(r['review_due_at']) == _Sla.late).length;
          final soon = rows.where((r) => _slaOf(r['review_due_at']) == _Sla.soon).length;
          final noEmail = rows.where((r) => r['email_verified'] != true).length;
          final list = _apply(rows);
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            ResponsiveGrid(minItemWidth: 200, spacing: 12, children: [
              StatCard(label: 'Menunggu review', value: '${rows.length}', icon: Icons.pending_actions_rounded, color: Brand.purple, onTap: _reset),
              StatCard(
                label: 'Lewat SLA',
                value: '$late',
                icon: Icons.timer_off_rounded,
                color: Brand.red,
                caption: _sla == 'late' ? 'Filter aktif' : null,
                onTap: () => setState(() => _sla = _sla == 'late' ? '' : 'late'),
              ),
              StatCard(
                label: 'SLA < 24 jam',
                value: '$soon',
                icon: Icons.hourglass_bottom_rounded,
                color: const Color(0xFFDC6803),
                caption: _sla == 'soon' ? 'Filter aktif' : null,
                onTap: () => setState(() => _sla = _sla == 'soon' ? '' : 'soon'),
              ),
              StatCard(
                label: 'Email belum terverifikasi',
                value: '$noEmail',
                icon: Icons.mark_email_unread_rounded,
                color: Brand.amber,
                caption: _email == 'no' ? 'Filter aktif' : null,
                onTap: () => setState(() => _email = _email == 'no' ? '' : 'no'),
              ),
            ]),
            const SizedBox(height: 16),
            _filterBar(contracts, hasVendor, kinds),
            const SizedBox(height: 16),
            if (rows.isEmpty)
              const SectionCard(
                child: EmptyState(icon: Icons.task_alt_rounded, title: 'Antrean review kosong', message: 'Semua dokumen sudah diproses. Kerja bagus!'),
              )
            else if (list.isEmpty)
              SectionCard(
                child: EmptyState(
                  icon: Icons.filter_alt_off_rounded,
                  title: 'Tidak ada task yang cocok dengan filter',
                  action: OutlinedButton.icon(onPressed: _reset, icon: const Icon(Icons.filter_alt_off_rounded), label: const Text('Reset filter')),
                ),
              )
            else ...[
              Padding(
                padding: const EdgeInsets.only(bottom: 8, left: 4),
                child: Text('${list.length} dari ${rows.length} task', style: Theme.of(context).textTheme.bodySmall),
              ),
              if (MediaQuery.sizeOf(context).width >= 900) _QueueTable(rows: list) else for (final r in list) _QueueCard(r: r),
            ],
          ]);
        },
      ),
    );
  }

  Widget _filterBar(List<String> contracts, bool hasVendor, Set<String> kinds) {
    Widget drop(String label, String value, List<(String, String)> items, ValueChanged<String> on, double w, IconData icon) => SizedBox(
          width: w,
          child: DropdownButtonFormField<String>(
            key: ValueKey('$label|$value'),
            initialValue: items.any((e) => e.$1 == value) ? value : '',
            isExpanded: true,
            menuMaxHeight: 420,
            decoration: InputDecoration(labelText: label, prefixIcon: Icon(icon, size: 18)),
            items: [for (final (v, l) in items) DropdownMenuItem(value: v, child: Text(l, overflow: TextOverflow.ellipsis))],
            onChanged: (v) => on(v ?? ''),
          ),
        );
    return SectionCard(
      padding: const EdgeInsets.all(16),
      child: LayoutBuilder(builder: (context, c) {
        final wide = c.maxWidth >= 860;
        final w = wide ? 190.0 : c.maxWidth;
        return Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
          SizedBox(
            width: wide ? 260 : c.maxWidth,
            child: TextField(
              onChanged: (v) => setState(() => _q = v.trim()),
              decoration: const InputDecoration(hintText: 'Cari Task ID / judul / vendor', prefixIcon: Icon(Icons.search_rounded)),
            ),
          ),
          drop('Kontrak', _contract, [('', 'Semua kontrak'), if (hasVendor) ('-', 'Vendor (tanpa kontrak)'), for (final k in contracts) (k, k)],
              (v) => setState(() => _contract = v), w, Icons.handshake_outlined),
          drop('Jenis', _kind, [('', 'Semua jenis'), for (final k in Labels.kind.keys) if (kinds.contains(k)) (k, Labels.kindOf(k))],
              (v) => setState(() => _kind = v), w, Icons.category_outlined),
          drop('SLA', _sla, const [('', 'Semua SLA'), ('late', 'Lewat SLA'), ('soon', '< 24 jam'), ('ok', 'Aman'), ('none', 'Tanpa SLA')],
              (v) => setState(() => _sla = v), w, Icons.timer_outlined),
          drop('Email', _email, const [('', 'Semua'), ('yes', 'Email ✓ terverifikasi'), ('no', 'Email ✗ belum')],
              (v) => setState(() => _email = v), w, Icons.alternate_email_rounded),
          if (_filtered)
            TextButton.icon(onPressed: _reset, icon: const Icon(Icons.filter_alt_off_rounded, size: 18), label: const Text('Reset')),
        ]);
      }),
    );
  }
}

class _SlaBadge extends StatelessWidget {
  const _SlaBadge(this.due);
  final dynamic due;
  @override
  Widget build(BuildContext context) {
    final (c, l) = _slaStyle(due);
    return Tooltip(
      message: due == null ? 'Belum ada batas review' : 'Batas review ${fmtDateTime(due)}',
      child: StatusBadge(c, l, icon: _slaOf(due) == _Sla.late ? Icons.timer_off_rounded : Icons.timer_outlined),
    );
  }
}

class _EmailBadge extends StatelessWidget {
  const _EmailBadge(this.r);
  final J r;
  @override
  Widget build(BuildContext context) {
    if (r['kind'] != 'document' && r['email_verified'] != true) {
      return const Tooltip(message: 'Bukan dokumen — email konfirmasi biasanya tidak wajib', child: StatusBadge(Brand.grey, 'Email ✗', icon: Icons.mail_outline_rounded));
    }
    return r['email_verified'] == true
        ? const StatusBadge(Brand.green, 'Email ✓', icon: Icons.mark_email_read_rounded)
        : const StatusBadge(Brand.amber, 'Email ✗', icon: Icons.mark_email_unread_rounded);
  }
}

class _QueueTable extends StatelessWidget {
  const _QueueTable({required this.rows});
  final List<J> rows;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final head = t.labelMedium?.copyWith(fontWeight: FontWeight.w700, color: Theme.of(context).colorScheme.onSurfaceVariant, letterSpacing: 0.3);
    Widget h(String s, int flex) => Expanded(flex: flex, child: Text(s.toUpperCase(), style: head));
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(children: [
        Container(
          color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          child: Row(children: [h('SLA', 12), h('Task ID', 24), h('Judul', 26), h('Kontrak / Vendor', 20), h('Status', 12), h('Email', 10), h('Dikirim', 10)]),
        ),
        for (final (i, r) in rows.indexed) ...[
          if (i > 0) const Divider(height: 1),
          InkWell(
            onTap: () => context.go('/tasks/${r['id']}'),
            child: Container(
              decoration: BoxDecoration(border: Border(left: BorderSide(color: _slaStyle(r['review_due_at']).$1, width: 4))),
              padding: const EdgeInsets.fromLTRB(16, 12, 20, 12),
              child: Row(children: [
                Expanded(flex: 12, child: Align(alignment: Alignment.centerLeft, child: _SlaBadge(r['review_due_at']))),
                Expanded(
                  flex: 24,
                  child: Align(alignment: Alignment.centerLeft, child: FittedBox(fit: BoxFit.scaleDown, child: TaskIdChip(str(r['task_id'])))),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 26,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(str(r['title']), maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
                    Text(Labels.kindOf(r['kind']), style: t.bodySmall),
                  ]),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 20,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(str(r['contract_no'], 'Vendor'), style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.w700, fontSize: 12)),
                    Text(str(r['contractor_name']), maxLines: 1, overflow: TextOverflow.ellipsis, style: t.bodySmall),
                  ]),
                ),
                Expanded(flex: 12, child: Align(alignment: Alignment.centerLeft, child: StatusBadge.task(r['status'] as String?))),
                Expanded(flex: 10, child: Align(alignment: Alignment.centerLeft, child: _EmailBadge(r))),
                Expanded(flex: 10, child: Text(fmtRelative(r['upload_confirmed_at']), style: t.bodySmall)),
              ]),
            ),
          ),
        ],
      ]),
    );
  }
}

class _QueueCard extends StatelessWidget {
  const _QueueCard({required this.r});
  final J r;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Card(
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => context.go('/tasks/${r['id']}'),
            child: Container(
              decoration: BoxDecoration(border: Border(left: BorderSide(color: _slaStyle(r['review_due_at']).$1, width: 4))),
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Flexible(child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: TaskIdChip(str(r['task_id'])))),
                  const SizedBox(width: 8),
                  _SlaBadge(r['review_due_at']),
                ]),
                const SizedBox(height: 10),
                Text(str(r['title']), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                const SizedBox(height: 4),
                Text('${str(r['contract_no'], 'Vendor')} · ${str(r['contractor_name'])} · dikirim ${fmtRelative(r['upload_confirmed_at'])}',
                    style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 10),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  StatusBadge.task(r['status'] as String?),
                  StatusBadge(Brand.blue, Labels.kindOf(r['kind']), icon: Icons.category_outlined),
                  _EmailBadge(r),
                ]),
              ]),
            ),
          ),
        ),
      );
}
