import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../core/router/gate.dart';
import '../../core/session/failure_handler.dart';
import '../../core/session/session_controller.dart';
import '../../data/api.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../shell/app_shell.dart';

typedef J = Map<String, dynamic>;

const _cols = 'id,kind,title,body,link,severity,read_at,created_at';
const _page = 50;

class NotificationsPage extends ConsumerStatefulWidget {
  const NotificationsPage({super.key});
  @override
  ConsumerState<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends ConsumerState<NotificationsPage> {
  StreamSubscription<String>? _sub;
  List<J>? _items;
  Object? _error;
  bool _unreadOnly = false, _loading = false, _hasMore = false, _busyAll = false;
  int _limit = _page, _gen = 0;

  @override
  void initState() {
    super.initState();
    _load();
    _sub = ref.read(notificationBus).stream.listen((_) => _load());
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final gen = ++_gen;
    final unreadOnly = _unreadOnly, limit = _limit;
    setState(() => _loading = true);
    try {
      final rows = await ref.read(apiProvider).select('notifications', _cols,
          build: (q) => (unreadOnly ? q.isFilter('read_at', null) : q).order('created_at', ascending: false).limit(limit + 1));
      if (!mounted || gen != _gen) return;
      setState(() {
        _hasMore = rows.length > limit;
        _items = rows.take(limit).toList();
        _error = null;
      });
      _syncBadge();
    } catch (e) {
      if (mounted && gen == _gen) setState(() => _error = e);
    } finally {
      if (mounted && gen == _gen) setState(() => _loading = false);
    }
  }

  Future<void> _syncBadge() async {
    try {
      final rows = await ref.read(apiProvider).select('notifications', 'id', build: (q) => q.isFilter('read_at', null).limit(100));
      if (mounted) ref.read(unreadNotificationsProvider.notifier).state = rows.length;
    } catch (_) {}
  }

  void _setFilter(bool unread) {
    setState(() {
      _unreadOnly = unread;
      _limit = _page;
      _items = null;
    });
    _load();
  }

  Future<void> _markRead(J n) async {
    if (n['read_at'] != null) return;
    final r = await runAction(context, ref, () => ref.read(apiProvider).rpc('mark_notifications_read', {'p_ids': [n['id']]}));
    if (r == null || !mounted) return;
    setState(() {
      n['read_at'] = DateTime.now().toUtc().toIso8601String();
      if (_unreadOnly) _items?.remove(n);
    });
    _syncBadge();
  }

  Future<void> _markAll() async {
    setState(() => _busyAll = true);
    final n = await runAction(context, ref, () => ref.read(apiProvider).rpc('mark_notifications_read', {'p_ids': null}));
    if (!mounted) return;
    setState(() => _busyAll = false);
    if (n != null) {
      showSnack(context, n is num && n > 0 ? '$n notifikasi ditandai dibaca' : 'Semua notifikasi sudah dibaca');
      _load();
    }
  }

  Future<void> _open(J n) async {
    final link = safeNext(n['link'] as String?);
    if (n['read_at'] == null) {
      // tanpa runAction-snackbar: navigasi tetap jalan walau gagal menandai
      try {
        await ref.read(apiProvider).rpc('mark_notifications_read', {'p_ids': [n['id']]});
        n['read_at'] = DateTime.now().toUtc().toIso8601String();
        _syncBadge();
      } catch (_) {}
    }
    if (!mounted) return;
    if (link == null) {
      setState(() {});
      if (n['link'] != null) showSnack(context, 'Tautan notifikasi tidak valid', error: true);
      return;
    }
    context.go(link);
  }

  @override
  Widget build(BuildContext context) {
    final unread = ref.watch(unreadNotificationsProvider);
    return PageScaffold(
      title: 'Notifikasi',
      subtitle: unread > 0 ? '$unread belum dibaca' : 'Semua notifikasi sudah dibaca',
      maxWidth: 960,
      actions: [
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('Semua'), icon: Icon(Icons.inbox_rounded)),
            ButtonSegment(value: true, label: Text('Belum dibaca'), icon: Icon(Icons.mark_email_unread_outlined)),
          ],
          selected: {_unreadOnly},
          onSelectionChanged: (v) => _setFilter(v.first),
        ),
        FilledButton.tonalIcon(
          onPressed: _busyAll || unread == 0 ? null : _markAll,
          icon: _busyAll ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.done_all_rounded),
          label: const Text('Tandai semua dibaca'),
        ),
        IconButton(tooltip: 'Pengaturan notifikasi', onPressed: () => context.go('/settings/notifications'), icon: const Icon(Icons.tune_rounded)),
      ],
      child: _body(),
    );
  }

  Widget _body() {
    if (_items == null && _error != null) return ErrorView(_error!, onRetry: _load);
    if (_items == null) return const LoadingView();
    final items = _items!;
    if (items.isEmpty) {
      return Card(
        child: EmptyState(
          icon: _unreadOnly ? Icons.mark_email_read_outlined : Icons.notifications_off_outlined,
          title: _unreadOnly ? 'Tidak ada notifikasi belum dibaca' : 'Belum ada notifikasi',
          message: 'Notifikasi task, kontrak, chat, dan keamanan akan muncul di sini secara realtime.',
        ),
      );
    }
    final children = <Widget>[];
    String? lastDay;
    for (final (i, n) in items.indexed) {
      final d = parseDate(n['created_at']);
      final day = _dayLabel(d);
      if (day != lastDay) {
        lastDay = day;
        children.add(Padding(
          padding: EdgeInsets.fromLTRB(4, children.isEmpty ? 0 : 20, 4, 8),
          child: Text(day.toUpperCase(),
              style: Theme.of(context).textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w800, letterSpacing: 0.8, color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ));
      }
      children.add(_NotificationTile(n: n, onOpen: () => _open(n), onMarkRead: () => _markRead(n))
          .animate()
          .fadeIn(duration: 180.ms, delay: (i.clamp(0, 12) * 18).ms));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (_loading) const LinearProgressIndicator(minHeight: 2),
      ...children,
      if (_hasMore)
        Padding(
          padding: const EdgeInsets.only(top: 16),
          child: Center(
            child: OutlinedButton.icon(
              onPressed: _loading
                  ? null
                  : () {
                      _limit += _page;
                      _load();
                    },
              icon: const Icon(Icons.expand_more_rounded),
              label: const Text('Muat lebih banyak'),
            ),
          ),
        ),
    ]);
  }

  static String _dayLabel(DateTime? d) {
    if (d == null) return '-';
    final now = DateTime.now();
    final days = DateTime(now.year, now.month, now.day).difference(DateTime(d.year, d.month, d.day)).inDays;
    if (days == 0) return 'Hari ini';
    if (days == 1) return 'Kemarin';
    return DateFormat('EEEE, d MMMM yyyy', 'id').format(d);
  }
}

class _NotificationTile extends StatelessWidget {
  const _NotificationTile({required this.n, required this.onOpen, required this.onMarkRead});
  final J n;
  final VoidCallback onOpen, onMarkRead;

  static (Color, String) severity(String? s) => switch (s) {
        'critical' => (Brand.red, 'Kritis'),
        'warning' => (Brand.amber, 'Peringatan'),
        _ => (Brand.blue, 'Info'),
      };

  static IconData icon(String kind) {
    if (kind.startsWith('chat')) return kind == 'chat_mention' ? Icons.alternate_email_rounded : Icons.forum_rounded;
    if (kind.contains('device')) return Icons.devices_rounded;
    if (kind.contains('security') || kind.contains('login')) return Icons.shield_outlined;
    if (kind.contains('task') || kind.contains('review')) return Icons.task_alt_rounded;
    if (kind.contains('contract')) return Icons.handshake_rounded;
    if (kind.contains('incident')) return Icons.report_gmailerrorred_rounded;
    if (kind.contains('vendor') || kind.contains('asl')) return Icons.storefront_rounded;
    if (kind.contains('user') || kind.contains('account') || kind.contains('role')) return Icons.person_outline_rounded;
    return Icons.notifications_rounded;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final unread = n['read_at'] == null;
    final (color, label) = severity(n['severity'] as String?);
    final hasLink = safeNext(n['link'] as String?) != null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: unread ? color.withValues(alpha: 0.05) : scheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: unread ? color.withValues(alpha: 0.35) : Theme.of(context).dividerColor),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onOpen,
          child: IntrinsicHeight(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Container(width: 4, color: unread ? color : Colors.transparent),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 14, 8, 14),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
                      child: Icon(icon(str(n['kind'], '')), color: color, size: 20),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          Expanded(
                            child: Text(str(n['title']),
                                style: t.titleSmall?.copyWith(fontWeight: unread ? FontWeight.w800 : FontWeight.w600), maxLines: 2, overflow: TextOverflow.ellipsis),
                          ),
                          const SizedBox(width: 8),
                          Tooltip(message: fmtDateTime(n['created_at']), child: Text(fmtRelative(n['created_at']), style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant))),
                        ]),
                        if (n['body'] != null && str(n['body'], '').isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(str(n['body']), style: t.bodyMedium?.copyWith(color: scheme.onSurfaceVariant), maxLines: 3, overflow: TextOverflow.ellipsis),
                        ],
                        const SizedBox(height: 8),
                        Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                          StatusBadge(color, label),
                          if (hasLink)
                            Row(mainAxisSize: MainAxisSize.min, children: [
                              Icon(Icons.arrow_forward_rounded, size: 14, color: scheme.primary),
                              const SizedBox(width: 4),
                              Text('Buka', style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w700, fontSize: 12)),
                            ]),
                        ]),
                      ]),
                    ),
                    if (unread)
                      IconButton(tooltip: 'Tandai dibaca', onPressed: onMarkRead, icon: const Icon(Icons.mark_email_read_outlined, size: 20))
                    else
                      const SizedBox(width: 8),
                  ]),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
