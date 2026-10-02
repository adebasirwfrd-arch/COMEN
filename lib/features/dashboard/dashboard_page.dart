import 'dart:async';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/session/session_controller.dart';
import '../../core/session/session_state.dart';
import '../../data/api.dart';
import '../../ui/labels.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

class _DashData {
  _DashData(this.d, this.myTasks, this.contracts, this.channels);
  final Map<String, dynamic> d;
  final List<Map<String, dynamic>> myTasks, contracts, channels;
}

class DashboardPage extends ConsumerStatefulWidget {
  const DashboardPage({super.key});
  @override
  ConsumerState<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends ConsumerState<DashboardPage> {
  late Future<_DashData> _future;
  StreamSubscription<String>? _sub;

  @override
  void initState() {
    super.initState();
    _future = _load();
    _sub = ref.read(notificationBus).stream.listen((_) => _reload());
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _reload() {
    if (mounted) setState(() => _future = _load());
  }

  Future<_DashData> _load() async {
    final api = ref.read(apiProvider);
    final s = (ref.read(sessionProvider) as SessionReady).s;
    final results = await Future.wait([
      api.rpcMap('get_dashboard'),
      api.select('v_task_tracking',
          'id,task_id,title,doc_label,status,due_date,review_due_at,contract_no,contractor_name,is_overdue,review_overdue,kind,is_blocker',
          build: (q) => (s.isWfrd
                  ? q.inFilter('status', ['submitted', 'under_review'])
                  : q.inFilter('status', ['open', 'awaiting_email', 'file_issue']))
              .order(s.isWfrd ? 'review_due_at' : 'due_date', ascending: true, nullsFirst: false)
              .limit(8)),
      api.select('contracts', 'id,contract_no,title,status,health_flag,target_mob_date,end_date',
          build: (q) => q.not('status', 'in', '(closed,terminated)').order('updated_at', ascending: false).limit(6)),
      api.rpcList('list_my_channels').catchError((_) => <Map<String, dynamic>>[]),
    ]);
    return _DashData(results[0] as Map<String, dynamic>, results[1] as List<Map<String, dynamic>>,
        results[2] as List<Map<String, dynamic>>, results[3] as List<Map<String, dynamic>>);
  }

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(sessionProvider);
    if (st is! SessionReady) return const LoadingView();
    final s = st.s;
    final hour = DateTime.now().hour;
    final greet = hour < 11 ? 'Selamat pagi' : hour < 15 ? 'Selamat siang' : hour < 18 ? 'Selamat sore' : 'Selamat malam';
    return PageScaffold(
      title: '$greet, ${(s.fullName ?? s.email).split(' ').first} 👋',
      subtitle: s.isWfrd ? 'Ringkasan kepatuhan contractor & kontrak sesuai hak akses Anda' : 'Ringkasan kewajiban ${s.contractorName ?? 'perusahaan'} Anda',
      actions: [IconButton(tooltip: 'Muat ulang', onPressed: _reload, icon: const Icon(Icons.refresh_rounded))],
      child: AsyncView<_DashData>(
        future: _future,
        onRetry: _reload,
        builder: (context, data) => s.isWfrd ? _WfrdDashboard(data: data, s: s) : _ContractorDashboard(data: data, s: s),
      ),
    );
  }
}

int _n(dynamic v) => (v as num?)?.toInt() ?? 0;

class _WfrdDashboard extends StatelessWidget {
  const _WfrdDashboard({required this.data, required this.s});
  final _DashData data;
  final SessionState s;

  @override
  Widget build(BuildContext context) {
    final d = data.d;
    final byStatus = Map<String, dynamic>.from(d['contracts_by_status'] as Map? ?? const {});
    final kpi = List<Map<String, dynamic>>.from((d['kpi_latest'] as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map)));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _Hero(
        title: 'Command Center',
        lines: [
          '${_n(d['tasks_open'])} task terbuka · ${_n(d['tasks_in_review'])} menunggu review',
          '${_n(d['contracts_red'])} kontrak berstatus merah · ${_n(d['incidents_open'])} insiden terbuka',
        ],
        icon: Icons.radar_rounded,
      ),
      const SizedBox(height: 20),
      ResponsiveGrid(minItemWidth: 220, children: [
        StatCard(label: 'Task terbuka', value: '${_n(d['tasks_open'])}', icon: Icons.assignment_rounded, onTap: () => context.go('/tasks')),
        StatCard(label: 'Overdue', value: '${_n(d['tasks_overdue'])}', icon: Icons.alarm_rounded, color: Brand.red, onTap: () => context.go('/tasks?filter=overdue')),
        StatCard(label: 'Jatuh tempo 7 hari', value: '${_n(d['tasks_due_7d'])}', icon: Icons.event_rounded, color: Brand.amber, onTap: () => context.go('/tasks?filter=due7')),
        StatCard(
          label: 'Dalam review',
          value: '${_n(d['tasks_in_review'])}',
          icon: Icons.fact_check_rounded,
          color: Brand.purple,
          caption: _n(d['review_overdue']) > 0 ? '${_n(d['review_overdue'])} melewati SLA' : 'Semua dalam SLA',
          onTap: s.can('task.review') ? () => context.go('/tasks/review') : null,
        ),
      ]),
      const SizedBox(height: 20),
      LayoutBuilder(builder: (context, c) {
        final wide = c.maxWidth > 1000;
        final chart = SectionCard(
          title: 'Kontrak per status',
          icon: Icons.bar_chart_rounded,
          trailing: StatusBadge(Brand.red, '${_n(d['contracts_red'])} merah'),
          child: SizedBox(height: 240, child: _ContractBar(byStatus: byStatus)),
        );
        final kpiCard = SectionCard(
          title: 'KPI terakhir',
          icon: Icons.speed_rounded,
          trailing: TextButton(onPressed: () => context.go('/kpi'), child: const Text('Lihat KPI')),
          child: kpi.isEmpty
              ? const EmptyState(icon: Icons.insights_rounded, title: 'Belum ada snapshot KPI')
              : Column(children: [
                  for (final k in kpi.take(6))
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: HealthDot(k['color'] as String?),
                      title: Text('Periode ${fmtDate(k['period'])}'),
                      trailing: Text((k['score'] as num?)?.toStringAsFixed(1) ?? '-', style: const TextStyle(fontWeight: FontWeight.w800)),
                      onTap: () => context.go('/contracts/${k['contract_id']}?tab=kpi'),
                    ),
                ]),
        );
        return wide
            ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(flex: 3, child: chart), const SizedBox(width: 16), Expanded(flex: 2, child: kpiCard)])
            : Column(children: [chart, const SizedBox(height: 16), kpiCard]);
      }),
      const SizedBox(height: 16),
      LayoutBuilder(builder: (context, c) {
        final wide = c.maxWidth > 1000;
        final queue = SectionCard(
          title: 'Antrean review (urut SLA)',
          icon: Icons.pending_actions_rounded,
          trailing: s.can('task.review') ? TextButton(onPressed: () => context.go('/tasks/review'), child: const Text('Buka antrean')) : null,
          child: _TaskMiniList(rows: data.myTasks, reviewer: true),
        );
        final ops = SectionCard(
          title: 'Operasional',
          icon: Icons.health_and_safety_rounded,
          child: Column(children: [
            _OpsRow(icon: Icons.report_gmailerrorred_rounded, color: Brand.red, label: 'Insiden terbuka', value: _n(d['incidents_open']), onTap: () => context.go('/incidents')),
            _OpsRow(icon: Icons.find_in_page_rounded, color: Brand.amber, label: 'Finding audit terbuka', value: _n(d['findings_open'])),
            _OpsRow(icon: Icons.handshake_rounded, color: Brand.blue, label: 'Kontrak aktif ditampilkan', value: data.contracts.length, onTap: () => context.go('/contracts')),
            _OpsRow(icon: Icons.notifications_active_rounded, color: Brand.purple, label: 'Notifikasi belum dibaca', value: _n(d['unread_notifications']), onTap: () => context.go('/notifications')),
          ]),
        );
        return wide
            ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(flex: 3, child: queue), const SizedBox(width: 16), Expanded(flex: 2, child: ops)])
            : Column(children: [queue, const SizedBox(height: 16), ops]);
      }),
      const SizedBox(height: 16),
      _ContractsCard(rows: data.contracts),
    ]);
  }
}

class _ContractorDashboard extends StatelessWidget {
  const _ContractorDashboard({required this.data, required this.s});
  final _DashData data;
  final SessionState s;

  @override
  Widget build(BuildContext context) {
    final d = data.d;
    final awaitingEmail = data.myTasks.where((t) => t['status'] == 'awaiting_email').length;
    final fileIssue = data.myTasks.where((t) => t['status'] == 'file_issue').length;
    final acks = data.channels.where((c) => _n(c['pending_acks']) > 0).toList();
    final (vc, vl) = StatusStyle.vendor(s.vendorStatus);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _Hero(
        title: s.contractorName ?? 'Perusahaan saya',
        lines: ['Status vendor: $vl', '${_n(d['tasks_open'])} task harus dikerjakan · ${_n(d['tasks_overdue'])} overdue'],
        icon: Icons.apartment_rounded,
        trailing: StatusBadge(vc, vl),
      ),
      if (acks.isNotEmpty) ...[
        const SizedBox(height: 16),
        InfoBanner(
          message: '${acks.length} pengumuman wajib-baca belum Anda konfirmasi.',
          color: Brand.amber,
          icon: Icons.campaign_rounded,
          action: TextButton(onPressed: () => context.go('/chat/${acks.first['id']}'), child: const Text('Baca sekarang')),
        ),
      ],
      const SizedBox(height: 20),
      ResponsiveGrid(minItemWidth: 200, children: [
        StatCard(label: 'Harus dikerjakan', value: '${_n(d['tasks_open'])}', icon: Icons.assignment_late_rounded, onTap: () => context.go('/tasks')),
        StatCard(label: 'Overdue', value: '${_n(d['tasks_overdue'])}', icon: Icons.alarm_rounded, color: Brand.red, onTap: () => context.go('/tasks?filter=overdue')),
        StatCard(label: 'Menunggu email', value: '$awaitingEmail', icon: Icons.mark_email_unread_rounded, color: Brand.amber, onTap: () => context.go('/tasks?status=awaiting_email')),
        StatCard(label: 'File bermasalah', value: '$fileIssue', icon: Icons.report_problem_rounded, color: Brand.purple, onTap: () => context.go('/tasks?status=file_issue')),
        StatCard(label: 'Dalam review WFRD', value: '${_n(d['tasks_in_review'])}', icon: Icons.fact_check_rounded, color: Brand.green, onTap: () => context.go('/tasks/tracking')),
      ]),
      const SizedBox(height: 20),
      SectionCard(
        title: 'Task saya (urut jatuh tempo)',
        icon: Icons.checklist_rounded,
        trailing: TextButton(onPressed: () => context.go('/tasks'), child: const Text('Semua task')),
        child: _TaskMiniList(rows: data.myTasks, reviewer: false),
      ),
      const SizedBox(height: 16),
      _ContractsCard(rows: data.contracts),
    ]);
  }
}

class _Hero extends StatelessWidget {
  const _Hero({required this.title, required this.lines, required this.icon, this.trailing});
  final String title;
  final List<String> lines;
  final IconData icon;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          gradient: Brand.heroGradient,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [BoxShadow(color: Brand.blue.withValues(alpha: 0.25), blurRadius: 24, offset: const Offset(0, 10))],
        ),
        child: Row(children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(16)),
            child: Icon(icon, color: Colors.white, size: 32),
          ),
          const SizedBox(width: 18),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800)),
              const SizedBox(height: 6),
              for (final l in lines) Text(l, style: const TextStyle(color: Colors.white70)),
            ]),
          ),
          if (trailing != null) trailing!,
        ]),
      ).animate().fadeIn(duration: 300.ms).slideY(begin: -0.05, end: 0);
}

class _ContractBar extends StatelessWidget {
  const _ContractBar({required this.byStatus});
  final Map<String, dynamic> byStatus;

  static const _order = ['awarded', 'post_award', 'pre_mobilization', 'mobilization', 'active', 'demobilization', 'final_evaluation', 'suspended', 'closed', 'terminated'];

  @override
  Widget build(BuildContext context) {
    final keys = _order.where(byStatus.containsKey).toList();
    if (keys.isEmpty) return const EmptyState(icon: Icons.handshake_outlined, title: 'Belum ada kontrak');
    final maxY = keys.map((k) => _n(byStatus[k])).fold<int>(1, (a, b) => a > b ? a : b).toDouble();
    return BarChart(
      BarChartData(
        maxY: maxY * 1.2,
        gridData: const FlGridData(show: true, drawVerticalLine: false),
        borderData: FlBorderData(show: false),
        barTouchData: BarTouchData(
          touchTooltipData: BarTouchTooltipData(
            getTooltipItem: (g, _, rod, __) => BarTooltipItem('${StatusStyle.contract(keys[g.x]).$2}\n${rod.toY.toInt()}', const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
          ),
        ),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 28)),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 36,
              getTitlesWidget: (v, meta) {
                final i = v.toInt();
                if (i < 0 || i >= keys.length) return const SizedBox.shrink();
                final label = StatusStyle.contract(keys[i]).$2;
                return Padding(padding: const EdgeInsets.only(top: 6), child: Text(label.length > 10 ? '${label.substring(0, 9)}…' : label, style: const TextStyle(fontSize: 10)));
              },
            ),
          ),
        ),
        barGroups: [
          for (var i = 0; i < keys.length; i++)
            BarChartGroupData(x: i, barRods: [
              BarChartRodData(
                toY: _n(byStatus[keys[i]]).toDouble(),
                color: StatusStyle.contract(keys[i]).$1,
                width: 22,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
              ),
            ]),
        ],
      ),
    );
  }
}

class _TaskMiniList extends StatelessWidget {
  const _TaskMiniList({required this.rows, required this.reviewer});
  final List<Map<String, dynamic>> rows;
  final bool reviewer;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return EmptyState(
        icon: Icons.task_alt_rounded,
        title: reviewer ? 'Antrean review kosong' : 'Tidak ada task yang harus dikerjakan',
        message: reviewer ? 'Semua dokumen sudah diproses.' : 'Kerja bagus! Semua kewajiban terpenuhi.',
      );
    }
    return Column(children: [
      for (final t in rows)
        ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 4),
          onTap: () => context.go('/tasks/${t['id']}'),
          leading: Icon(
            t['is_blocker'] == true ? Icons.block_rounded : Icons.description_outlined,
            color: t['is_blocker'] == true ? Brand.red : Brand.blue,
          ),
          title: Row(children: [
            Flexible(child: MonoText(str(t['task_id']), size: 12)),
            const SizedBox(width: 8),
            StatusBadge.task(t['status'] as String?),
          ]),
          subtitle: Text('${str(t['doc_label'] ?? t['title'])} · ${str(t['contract_no'] ?? t['contractor_name'])}', maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: reviewer
              ? Text(t['review_overdue'] == true ? 'SLA lewat' : 'SLA ${fmtRelative(t['review_due_at'])}',
                  style: TextStyle(color: t['review_overdue'] == true ? Brand.red : Brand.grey, fontWeight: FontWeight.w700, fontSize: 12))
              : Text(dueLabel(t['due_date']), style: TextStyle(color: dueColor(t['due_date']), fontWeight: FontWeight.w700, fontSize: 12)),
        ),
    ]);
  }
}

class _ContractsCard extends StatelessWidget {
  const _ContractsCard({required this.rows});
  final List<Map<String, dynamic>> rows;

  @override
  Widget build(BuildContext context) => SectionCard(
        title: 'Kontrak berjalan',
        icon: Icons.handshake_rounded,
        trailing: TextButton(onPressed: () => context.go('/contracts'), child: const Text('Semua kontrak')),
        child: rows.isEmpty
            ? const EmptyState(icon: Icons.handshake_outlined, title: 'Belum ada kontrak aktif')
            : ResponsiveGrid(minItemWidth: 280, children: [
                for (final k in rows)
                  InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () => context.go('/contracts/${k['id']}'),
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: Theme.of(context).dividerColor),
                      ),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          HealthDot(k['health_flag'] as String?),
                          const SizedBox(width: 8),
                          Expanded(child: MonoText(str(k['contract_no'], 'CTR-…'), size: 12)),
                          StatusBadge.contract(k['status'] as String?),
                        ]),
                        const SizedBox(height: 8),
                        Text(str(k['title']), maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 6),
                        Text('Mobilisasi ${fmtDate(k['target_mob_date'])} · selesai ${fmtDate(k['end_date'])}', style: Theme.of(context).textTheme.bodySmall),
                      ]),
                    ),
                  ),
              ]),
      );
}

class _OpsRow extends StatelessWidget {
  const _OpsRow({required this.icon, required this.color, required this.label, required this.value, this.onTap});
  final IconData icon;
  final Color color;
  final String label;
  final int value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => ListTile(
        contentPadding: EdgeInsets.zero,
        onTap: onTap,
        leading: CircleAvatar(backgroundColor: color.withValues(alpha: 0.12), child: Icon(icon, color: color, size: 20)),
        title: Text(label),
        trailing: Text('$value', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18, color: value > 0 ? color : null)),
      );
}

String phaseText(dynamic p) => Labels.phaseOf(p);
