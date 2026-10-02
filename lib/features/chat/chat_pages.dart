import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math' as math;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:web/web.dart' as web;
import '../../core/env.dart';
import '../../core/security/fingerprint.dart';
import '../../core/security/url_policy.dart';
import '../../core/session/failure_handler.dart';
import '../../core/session/session_controller.dart';
import '../../core/session/session_state.dart';
import '../../data/api.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

typedef J = Map<String, dynamic>;
J _m(dynamic v) => v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
List<String> _ids(dynamic v) => (v as List? ?? const []).whereType<String>().toList();
int _seq(J m) => (m['seq'] as num?)?.toInt() ?? 0;
J? _find(Iterable<J>? l, dynamic id) {
  if (l == null || id == null) return null;
  for (final x in l) {
    if (x['id'] == id) return x;
  }
  return null;
}

// ═══════════════════════════ Cache memori (per user) ═══════════════════════════
class _ChatStore {
  List<J>? channels;
  List<J>? people;
  bool pushOfferDismissed = false;
  final drafts = <String, String>{};
  final cards = <String, J>{};
  final taskLookups = <String, Future<String?>>{};
}

final _chatStoreProvider = Provider<_ChatStore>((ref) {
  ref.watch(sessionProvider.select((s) => s is SessionReady ? s.s.userId : null));
  return _ChatStore();
});

SessionState? _sessionOf(WidgetRef ref) {
  final st = ref.read(sessionProvider);
  return st is SessionReady ? st.s : null;
}

Future<void> _ensureCards(WidgetRef ref, Iterable<dynamic> ids) async {
  final store = ref.read(_chatStoreProvider);
  final missing = ids.whereType<String>().where((id) => !store.cards.containsKey(id)).toSet().toList();
  if (missing.isEmpty) return;
  for (final id in missing) {
    store.cards[id] = const <String, dynamic>{};
  }
  try {
    for (var i = 0; i < missing.length; i += 200) {
      final rows = await ref.read(apiProvider).rpcList('get_user_cards', {'p_ids': missing.sublist(i, math.min(i + 200, missing.length))});
      for (final r in rows) {
        store.cards[r['id'] as String] = r;
      }
    }
  } catch (_) {
    for (final id in missing) {
      if (store.cards[id]?.isEmpty ?? false) store.cards.remove(id);
    }
  }
}

String _nameOf(_ChatStore st, dynamic id) => id == null ? 'COMEN Bot' : str(st.cards[id]?['full_name'], 'Pengguna');

/// Task ID → uuid task, hanya bila RLS mengizinkan user melihatnya (baris kosong = tidak berhak)
Future<String?> _lookupTask(WidgetRef ref, String taskId) {
  final st = ref.read(_chatStoreProvider);
  final api = ref.read(apiProvider);
  return st.taskLookups.putIfAbsent(taskId, () async {
    try {
      final r = await api.select('v_task_tracking', 'id,task_id', build: (q) => q.eq('task_id', taskId).limit(1));
      return r.isEmpty ? null : r.first['id'] as String?;
    } catch (_) {
      st.taskLookups.remove(taskId);
      return null;
    }
  });
}

Future<List<J>> _loadPeople(WidgetRef ref) async {
  final store = ref.read(_chatStoreProvider);
  if (store.people != null) return store.people!;
  final api = ref.read(apiProvider);
  final chans = store.channels ?? await api.rpcList('list_my_channels');
  final ids = <String>{for (final c in chans) if (c['peer_id'] is String) c['peer_id'] as String};
  final targets = chans.where((c) => c['type'] != 'announcement' && c['type'] != 'direct').take(25);
  final res = await Future.wait(targets.map((c) => api.rpcList('get_channel_members', {'p_channel': c['id']}).catchError((_) => <J>[])));
  for (final rows in res) {
    for (final r in rows) {
      if (r['user_id'] is String) ids.add(r['user_id'] as String);
    }
  }
  ids.remove(api.uid);
  final cards = ids.isEmpty ? <J>[] : await api.rpcList('get_user_cards', {'p_ids': ids.take(200).toList()});
  for (final c in cards) {
    store.cards[c['id'] as String] = c;
  }
  final people = cards.where((c) => c['active'] != false).toList()
    ..sort((a, b) => str(a['full_name']).toLowerCase().compareTo(str(b['full_name']).toLowerCase()));
  store.people = people;
  return people;
}

// ═══════════════════════════ Meta channel & format ═══════════════════════════
const _groups = [
  ('announcement', 'Pengumuman', Icons.campaign_rounded),
  ('contract', 'Kontrak', Icons.tag_rounded),
  ('direct', 'Langsung', Icons.person_rounded),
  ('group', 'Grup', Icons.groups_rounded),
];

String _groupOf(dynamic type) => type == 'task' ? 'contract' : str(type, 'group');

IconData _typeIcon(dynamic t) => switch (t) {
      'announcement' => Icons.campaign_rounded,
      'contract' => Icons.tag_rounded,
      'task' => Icons.task_alt_rounded,
      'direct' => Icons.person_rounded,
      _ => Icons.groups_rounded,
    };

Color _typeColor(dynamic t) => switch (t) {
      'announcement' => Brand.amber,
      'contract' => Brand.blue,
      'task' => Brand.purple,
      'direct' => Brand.green,
      _ => Brand.cyan,
    };

String _typeLabel(dynamic t) => switch (t) {
      'announcement' => 'Pengumuman',
      'contract' => 'Kanal kontrak',
      'task' => 'Thread task',
      'direct' => 'Pesan langsung',
      'group' => 'Grup',
      _ => 'Percakapan',
    };

String _channelName(J? c) => str(c?['name'], c?['type'] == 'direct' ? 'Pengguna' : 'Percakapan');

bool _isMuted(J? c) {
  if (c == null) return false;
  final until = parseDate(c['muted_until']);
  return c['notify_level'] == 'none' || (until != null && until.isAfter(DateTime.now()));
}

String _hm(dynamic v) {
  final d = parseDate(v);
  return d == null ? '' : DateFormat('HH:mm').format(d);
}

String _dayLabel(DateTime d) {
  final now = DateTime.now();
  final days = DateTime(now.year, now.month, now.day).difference(DateTime(d.year, d.month, d.day)).inDays;
  if (days == 0) return 'Hari ini';
  if (days == 1) return 'Kemarin';
  return DateFormat(d.year == now.year ? 'EEEE, d MMMM' : 'EEEE, d MMMM yyyy', 'id').format(d);
}

String _shortWhen(dynamic v) {
  final d = parseDate(v);
  if (d == null) return '';
  final now = DateTime.now();
  final days = DateTime(now.year, now.month, now.day).difference(DateTime(d.year, d.month, d.day)).inDays;
  if (days == 0) return DateFormat('HH:mm').format(d);
  if (days == 1) return 'Kemarin';
  if (days < 7) return DateFormat('EEE', 'id').format(d);
  return DateFormat(d.year == now.year ? 'd MMM' : 'd/M/yy', 'id').format(d);
}

bool _isBotKind(J m) => m['sender_id'] == null || const {'system', 'task_card', 'reminder', 'security'}.contains(m['kind']);

(Color, IconData, String) _kindStyle(dynamic kind) => switch (kind) {
      'task_card' => (Brand.blue, Icons.assignment_outlined, 'Kartu task'),
      'reminder' => (Brand.amber, Icons.alarm_rounded, 'Pengingat'),
      'security' => (Brand.red, Icons.gpp_maybe_outlined, 'Keamanan'),
      'announcement' => (Brand.amber, Icons.campaign_rounded, 'Pengumuman'),
      _ => (Brand.grey, Icons.smart_toy_outlined, 'Sistem'),
    };

const _quickEmojis = ['👍', '❤️', '😂', '🎉', '🙏', '👀', '✅', '🔥'];
const _emojiGrid = ['😀', '😁', '😊', '😉', '😍', '🤔', '😅', '😢', '😮', '👍', '👎', '👏', '🙏', '💪', '👌', '🤝', '✅', '❌', '⚠️', '🔥', '🎉', '🚀', '📌', '📎', '📅', '⏰', '🦺', '⛑️', '🛢️', '🚧'];

typedef _Member = ({String id, String name, String? sub, String? avatar});
typedef _Draft = ({String body, Set<String> mentions, String priority, bool requiresAck});

class _Act {
  const _Act(this.icon, this.label, this.onTap, {this.destructive = false});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool destructive;
}

// ═══════════════════════════ Halaman ═══════════════════════════
class ChatListPage extends StatelessWidget {
  const ChatListPage({super.key});
  @override
  Widget build(BuildContext context) => const _ChatLayout(selected: null);
}

class ChatRoomPage extends StatelessWidget {
  const ChatRoomPage({super.key, required this.channelId});
  final String channelId;
  @override
  Widget build(BuildContext context) => _ChatLayout(selected: channelId);
}

class _ChatLayout extends ConsumerStatefulWidget {
  const _ChatLayout({required this.selected});
  final String? selected;
  @override
  ConsumerState<_ChatLayout> createState() => _ChatLayoutState();
}

class _ChatLayoutState extends ConsumerState<_ChatLayout> {
  StreamSubscription<Map<String, dynamic>>? _sub;
  Timer? _debounce;
  List<J>? _channels;
  Object? _error;
  String _q = '';
  final Set<String> _collapsed = {};

  _ChatStore get _store => ref.read(_chatStoreProvider);

  @override
  void initState() {
    super.initState();
    _channels = _store.channels;
    _load();
    _sub = ref.read(chatBus).stream.listen((_) {
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 400), _load);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final rows = await ref.read(apiProvider).rpcList('list_my_channels');
      _store.channels = rows;
      await _ensureCards(ref, rows.map((c) => c['peer_id']));
      if (mounted) {
        setState(() {
          _channels = rows;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _newChat() async {
    final id = await showDialog<String>(context: context, builder: (_) => const _NewChatDialog());
    if (id == null || !mounted) return;
    await _load();
    if (mounted) context.go('/chat/$id');
  }

  bool get _pushOffer {
    if (Env.vapidPublicKey.isEmpty || _store.pushOfferDismissed) return false;
    if (!globalContext.has('Notification') || !globalContext.has('PushManager')) return false;
    return web.Notification.permission == 'default';
  }

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    final wide = w >= 900;
    final sel = widget.selected;
    final selChannel = _find(_channels, sel);
    final list = _ChannelList(
      channels: _channels,
      error: _error,
      onRetry: _load,
      selected: sel,
      query: _q,
      onQuery: (v) => setState(() => _q = v),
      collapsed: _collapsed,
      onToggle: (g) => setState(() => _collapsed.contains(g) ? _collapsed.remove(g) : _collapsed.add(g)),
    );
    final room = sel == null ? _EmptyRoom(onNew: _newChat) : _Room(key: ValueKey(sel), channelId: sel, channel: selChannel, onChanged: _load);
    final body = wide
        ? Row(children: [SizedBox(width: w >= 1280 ? 330 : 290, child: list), const VerticalDivider(width: 1), Expanded(child: room)])
        : (sel == null ? list : room);
    final inRoomMobile = !wide && sel != null;
    return PageScaffold(
      title: 'Chat',
      subtitle: wide ? 'Kanal kontrak, thread task, pesan langsung, grup & pengumuman' : null,
      leading: inRoomMobile ? IconButton(tooltip: 'Kembali', icon: const Icon(Icons.arrow_back_rounded), onPressed: () => context.go('/chat')) : null,
      scroll: false,
      maxWidth: 2200,
      actions: inRoomMobile
          ? const []
          : [
              IconButton(tooltip: 'Pesan tersimpan', onPressed: () => context.go('/chat/saved'), icon: const Icon(Icons.bookmark_border_rounded)),
              IconButton(
                tooltip: 'Pesan terjadwal',
                onPressed: () => showDialog<void>(context: context, builder: (_) => _ScheduledListDialog(channels: _channels ?? const [])),
                icon: const Icon(Icons.schedule_send_outlined),
              ),
              FilledButton.icon(onPressed: _newChat, icon: const Icon(Icons.add_comment_rounded), label: Text(wide ? 'Percakapan baru' : 'Baru')),
            ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (_pushOffer)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: InfoBanner(
              message: 'Aktifkan notifikasi push agar tidak melewatkan mention & pesan URGENT saat COMEN tidak dibuka.',
              icon: Icons.notifications_active_outlined,
              action: Row(mainAxisSize: MainAxisSize.min, children: [
                TextButton(onPressed: () => context.go('/settings/notifications'), child: const Text('Aktifkan')),
                IconButton(tooltip: 'Nanti saja', icon: const Icon(Icons.close_rounded, size: 18), onPressed: () => setState(() => _store.pushOfferDismissed = true)),
              ]),
            ),
          ),
        Expanded(child: Card(margin: EdgeInsets.zero, clipBehavior: Clip.antiAlias, child: body)),
      ]),
    );
  }
}

// ═══════════════════════════ Daftar percakapan ═══════════════════════════
class _ChannelList extends ConsumerWidget {
  const _ChannelList({
    required this.channels,
    required this.error,
    required this.onRetry,
    required this.selected,
    required this.query,
    required this.onQuery,
    required this.collapsed,
    required this.onToggle,
  });
  final List<J>? channels;
  final Object? error;
  final VoidCallback onRetry;
  final String? selected;
  final String query;
  final ValueChanged<String> onQuery;
  final Set<String> collapsed;
  final ValueChanged<String> onToggle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    Widget content;
    if (channels == null) {
      content = error != null ? ErrorView(error!, onRetry: onRetry) : const LoadingView();
    } else {
      final q = query.trim().toLowerCase();
      final all = channels!.where((c) => q.isEmpty || _channelName(c).toLowerCase().contains(q)).toList();
      if (all.isEmpty) {
        content = EmptyState(
          icon: Icons.forum_outlined,
          title: q.isEmpty ? 'Belum ada percakapan' : 'Tidak ditemukan',
          message: q.isEmpty ? 'Kanal kontrak dibuat otomatis. Mulai pesan langsung lewat tombol "Percakapan baru".' : null,
        );
      } else {
        final children = <Widget>[];
        for (final (key, label, icon) in _groups) {
          final items = all.where((c) => _groupOf(c['type']) == key).toList();
          if (items.isEmpty) continue;
          final unread = items.fold<int>(0, (a, c) => a + ((c['unread'] as num?)?.toInt() ?? 0));
          final open = !collapsed.contains(key);
          children.add(InkWell(
            onTap: () => onToggle(key),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 14, 8, 6),
              child: Row(children: [
                AnimatedRotation(turns: open ? 0 : -0.25, duration: 150.ms, child: Icon(Icons.expand_more_rounded, size: 18, color: scheme.onSurfaceVariant)),
                const SizedBox(width: 4),
                Icon(icon, size: 14, color: scheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Expanded(
                  child: Text('${label.toUpperCase()} (${items.length})',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 0.8, color: scheme.onSurfaceVariant)),
                ),
                if (!open && unread > 0) _CountPill(unread, color: Brand.blue),
              ]),
            ),
          ));
          if (open) {
            for (final c in items) {
              children.add(_ChannelTile(c: c, selected: c['id'] == selected));
            }
          }
        }
        content = ListView(padding: const EdgeInsets.fromLTRB(8, 0, 8, 16), children: children);
      }
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
        child: TextField(
          onChanged: onQuery,
          decoration: const InputDecoration(isDense: true, prefixIcon: Icon(Icons.search_rounded, size: 20), hintText: 'Cari percakapan'),
        ),
      ),
      Expanded(child: content),
    ]);
  }
}

class _ChannelTile extends ConsumerWidget {
  const _ChannelTile({required this.c, required this.selected});
  final J c;
  final bool selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final store = ref.read(_chatStoreProvider);
    final unread = (c['unread'] as num?)?.toInt() ?? 0;
    final mentions = (c['unread_mentions'] as num?)?.toInt() ?? 0;
    final acks = (c['pending_acks'] as num?)?.toInt() ?? 0;
    final muted = _isMuted(c);
    final peer = c['peer_id'] == null ? null : store.cards[c['peer_id']];
    final subtitle = c['is_archived'] == true
        ? 'Diarsipkan'
        : c['is_locked'] == true
            ? 'Dikunci'
            : c['type'] == 'direct'
                ? [peer?['job_title'], peer?['company']].whereType<Object>().map((e) => '$e').where((e) => e.isNotEmpty).join(' · ')
                : _typeLabel(c['type']);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Material(
        color: selected ? scheme.primary.withValues(alpha: 0.10) : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => context.go('/chat/${c['id']}'),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Row(children: [
              if (selected) Container(width: 3, height: 28, margin: const EdgeInsets.only(right: 5), decoration: BoxDecoration(color: scheme.primary, borderRadius: BorderRadius.circular(3))),
              _ChannelAvatar(channel: c, size: 36),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(
                      child: Text(_channelName(c),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontWeight: unread > 0 ? FontWeight.w800 : FontWeight.w600, fontSize: 13.5)),
                    ),
                    const SizedBox(width: 6),
                    Text(_shortWhen(c['last_message_at']),
                        style: TextStyle(fontSize: 11, color: unread > 0 ? scheme.primary : scheme.onSurfaceVariant, fontWeight: unread > 0 ? FontWeight.w700 : null)),
                  ]),
                  const SizedBox(height: 2),
                  Row(children: [
                    Expanded(
                      child: Text(subtitle.isEmpty ? _typeLabel(c['type']) : subtitle,
                          maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                    ),
                    if (c['is_locked'] == true) Icon(Icons.lock_outline_rounded, size: 13, color: scheme.onSurfaceVariant),
                    if (muted) Padding(padding: const EdgeInsets.only(left: 4), child: Icon(Icons.notifications_off_outlined, size: 13, color: scheme.onSurfaceVariant)),
                    if (acks > 0)
                      const Padding(
                        padding: EdgeInsets.only(left: 4),
                        child: Tooltip(message: 'Ada pesan wajib-baca', child: Icon(Icons.assignment_late_rounded, size: 16, color: Brand.amber)),
                      ),
                    if (mentions > 0)
                      Container(
                        margin: const EdgeInsets.only(left: 4),
                        width: 18,
                        height: 18,
                        alignment: Alignment.center,
                        decoration: const BoxDecoration(color: Brand.red, shape: BoxShape.circle),
                        child: const Text('@', style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w900)),
                      ),
                    if (unread > 0) Padding(padding: const EdgeInsets.only(left: 4), child: _CountPill(unread, color: muted ? Brand.grey : Brand.blue)),
                  ]),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _CountPill extends StatelessWidget {
  const _CountPill(this.n, {required this.color});
  final int n;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
        constraints: const BoxConstraints(minWidth: 18),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(999)),
        child: Text(n > 98 ? '99+' : '$n', textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800)),
      );
}

class _OnlineDot extends StatelessWidget {
  const _OnlineDot({this.size = 11});
  final double size;
  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: Brand.green, shape: BoxShape.circle, border: Border.all(color: Theme.of(context).colorScheme.surface, width: 2)),
      );
}

class _ChannelAvatar extends ConsumerWidget {
  const _ChannelAvatar({required this.channel, this.size = 36, this.online = false});
  final J? channel;
  final double size;
  final bool online;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final type = channel?['type'];
    if (type == 'direct') {
      final card = ref.read(_chatStoreProvider).cards[channel?['peer_id']];
      return Stack(clipBehavior: Clip.none, children: [
        Avatar(name: _channelName(channel), url: card?['avatar_url'] as String?, radius: size / 2),
        if (online) const Positioned(right: -1, bottom: -1, child: _OnlineDot()),
      ]);
    }
    final c = _typeColor(type);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: c.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(size * 0.3)),
      child: Icon(_typeIcon(type), color: c, size: size * 0.52),
    );
  }
}

class _EmptyRoom extends StatelessWidget {
  const _EmptyRoom({required this.onNew});
  final VoidCallback onNew;
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(gradient: Brand.heroGradient, borderRadius: BorderRadius.circular(28)),
            child: const Icon(Icons.forum_rounded, color: Colors.white, size: 46),
          ).animate().scale(begin: const Offset(0.9, 0.9), duration: 300.ms, curve: Curves.easeOutBack),
          const SizedBox(height: 20),
          Text('Pilih percakapan', style: t.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text('Pilih kanal atau pesan langsung di sebelah kiri, atau mulai percakapan baru.',
              textAlign: TextAlign.center, style: t.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const SizedBox(height: 20),
          Wrap(spacing: 10, runSpacing: 10, alignment: WrapAlignment.center, children: [
            FilledButton.icon(onPressed: onNew, icon: const Icon(Icons.add_comment_rounded), label: const Text('Percakapan baru')),
            OutlinedButton.icon(onPressed: () => context.go('/chat/saved'), icon: const Icon(Icons.bookmark_border_rounded), label: const Text('Pesan tersimpan')),
          ]),
        ]),
      ),
    );
  }
}

// ═══════════════════════════ Ruang percakapan ═══════════════════════════
class _Room extends ConsumerStatefulWidget {
  const _Room({super.key, required this.channelId, required this.channel, required this.onChanged});
  final String channelId;
  final J? channel;
  final Future<void> Function() onChanged;
  @override
  ConsumerState<_Room> createState() => _RoomState();
}

class _RoomState extends ConsumerState<_Room> {
  Api get _api => ref.read(apiProvider);
  late final String? _me = ref.read(apiProvider).uid;
  List<J> _msgs = [];
  final List<J> _pending = [];
  bool _loading = true, _loadingOlder = false, _hasMore = true, _atBottom = true, _newBelow = false, _flyout = false;
  Object? _error;
  RealtimeChannel? _rt;
  Set<String> _online = {};
  final Map<String, DateTime> _typing = {};
  Timer? _typingTimer, _readTimer, _refreshTimer;
  AppLifecycleListener? _life;
  DateTime _lastTypingSent = DateTime(2000);
  int _lastMarked = 0, _threadMaxSeq = 0, _pinsTick = 0, _initialUnread = 0;
  int? _unreadFromSeq;
  J? _replyTo;
  List<J> _members = [];
  String? _thread;
  List<J>? _threadMsgs;
  String? _panel = 'members';
  final _scroll = ScrollController();

  J? get _ch => widget.channel;
  String get _type => str(_ch?['type'], '');
  String get _role => str(_ch?['member_role'], 'member');
  bool get _archived => _ch?['is_archived'] == true;
  bool get _locked => _ch?['is_locked'] == true;
  SessionState? get _s => _sessionOf(ref);
  bool get _isMod => _role == 'owner' || _role == 'moderator' || (_s?.can('chat.moderate') ?? false);
  bool get _canPin => _type == 'direct' || _isMod;
  bool get _allowPresence => _type != 'announcement' && !_archived;

  DateTime? get _silencedUntil {
    final me = _find(_members.map((m) => {...m, 'id': m['user_id']}), _me);
    final d = parseDate(me?['silenced_until']);
    return d != null && d.isAfter(DateTime.now()) ? d : null;
  }

  String? get _writeBlock {
    if (_archived) return 'Percakapan ini diarsipkan — hanya bisa dibaca.';
    if (_locked) return 'Percakapan dikunci oleh Admin.';
    if (_role == 'readonly') return 'Anda hanya bisa membaca percakapan ini.';
    final sil = _silencedUntil;
    if (sil != null) return 'Anda dibungkam moderator sampai ${fmtDateTime(sil.toIso8601String())}.';
    return null;
  }

  @override
  void initState() {
    super.initState();
    _initialUnread = (widget.channel?['unread'] as num?)?.toInt() ?? 0;
    _scroll.addListener(_onScroll);
    _life = AppLifecycleListener(onResume: _maybeMarkRead, onShow: _maybeMarkRead);
    _loadInitial();
    _loadMembers();
    _openRealtime();
  }

  @override
  void dispose() {
    _scroll.dispose();
    _typingTimer?.cancel();
    _readTimer?.cancel();
    _refreshTimer?.cancel();
    _life?.dispose();
    final ch = _rt;
    _rt = null;
    if (ch != null) Supabase.instance.client.removeChannel(ch);
    super.dispose();
  }

  // ── Data ──
  Future<void> _loadInitial() async {
    try {
      final rows = await _api.rpcList('get_messages', {'p_channel': widget.channelId, 'p_limit': 50});
      await _ensureCards(ref, rows.map((m) => m['sender_id']));
      if (!mounted) return;
      setState(() {
        _msgs = rows.reversed.toList();
        _hasMore = rows.length >= 50;
        _loading = false;
        _error = null;
        _computeUnreadAnchor();
      });
      _maybeMarkRead();
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e;
          _loading = false;
        });
      }
    }
  }

  void _computeUnreadAnchor() {
    if (_initialUnread <= 0 || _msgs.isEmpty) return;
    var n = 0;
    for (final m in _msgs.reversed) {
      if (m['sender_id'] != _me && m['deleted'] != true) {
        n++;
        if (n == _initialUnread) {
          _unreadFromSeq = _seq(m);
          return;
        }
      }
    }
    _unreadFromSeq = _seq(_msgs.first);
  }

  void _merge(Iterable<J> rows) {
    final byId = {for (final m in _msgs) m['id'] as String: m};
    for (final r in rows) {
      byId[r['id'] as String] = r;
    }
    _msgs = byId.values.toList()..sort((a, b) => _seq(a).compareTo(_seq(b)));
    _pending.removeWhere((p) => p['id'] != null && byId.containsKey(p['id']));
  }

  void _scheduleRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer(const Duration(milliseconds: 250), _refreshLatest);
  }

  Future<void> _refreshLatest() async {
    try {
      final rows = await _api.rpcList('get_messages', {'p_channel': widget.channelId, 'p_limit': 50});
      await _ensureCards(ref, rows.map((m) => m['sender_id']));
      if (!mounted) return;
      final before = _msgs.isEmpty ? 0 : _seq(_msgs.last);
      setState(() {
        _merge(rows);
        if (!_atBottom && _msgs.isNotEmpty && _seq(_msgs.last) > before && _msgs.last['sender_id'] != _me) _newBelow = true;
      });
      _maybeMarkRead();
    } catch (_) {}
  }

  Future<void> _refreshById(dynamic id) async {
    if (id is! String) return;
    if (_thread != null && (id == _thread || _find(_threadMsgs, id) != null)) _loadThread();
    final cur = _find(_msgs, id);
    if (cur == null) return;
    try {
      final rows = await _api.rpcList('get_messages', {'p_channel': widget.channelId, 'p_before_seq': _seq(cur) + 1, 'p_limit': 1});
      if (!mounted) return;
      final hit = rows.where((r) => r['id'] == id).toList();
      if (hit.isNotEmpty) setState(() => _merge(hit));
    } catch (_) {}
  }

  Future<void> _loadOlder() async {
    if (_loadingOlder || !_hasMore || _msgs.isEmpty) return;
    setState(() => _loadingOlder = true);
    try {
      final rows = await _api.rpcList('get_messages', {'p_channel': widget.channelId, 'p_before_seq': _seq(_msgs.first), 'p_limit': 50});
      await _ensureCards(ref, rows.map((m) => m['sender_id']));
      if (!mounted) return;
      setState(() {
        _merge(rows);
        _hasMore = rows.length >= 50;
      });
    } catch (e) {
      if (mounted) await handleFailure(context, ref, e);
    } finally {
      if (mounted) setState(() => _loadingOlder = false);
    }
  }

  Future<void> _loadMembers() async {
    try {
      final rows = await _api.rpcList('get_channel_members', {'p_channel': widget.channelId});
      await _ensureCards(ref, rows.map((m) => m['user_id']));
      if (mounted) setState(() => _members = rows);
    } catch (_) {}
  }

  Future<void> _loadThread() async {
    final root = _thread;
    if (root == null) return;
    try {
      final rows = await _api.rpcList('get_messages', {'p_channel': widget.channelId, 'p_thread_root': root, 'p_limit': 100});
      await _ensureCards(ref, rows.map((m) => m['sender_id']));
      if (!mounted || _thread != root) return;
      setState(() {
        _threadMsgs = rows.reversed.toList();
        _threadMaxSeq = math.max(_threadMaxSeq, rows.fold<int>(0, (a, m) => math.max(a, _seq(m))));
      });
      _maybeMarkRead();
    } catch (e) {
      if (mounted) await handleFailure(context, ref, e);
    }
  }

  // ── Realtime (16.14): event = petunjuk → refetch via RPC ──
  static J _hintPayload(Map<String, dynamic> p) => p['payload'] is Map ? _m(p['payload']) : p;

  void _openRealtime() {
    final sb = Supabase.instance.client;
    final me = _me;
    final allowPresence = widget.channel != null && _allowPresence;
    final ch = sb.channel('chat:${widget.channelId}', opts: const RealtimeChannelConfig(private: true));
    for (final ev in const ['message_created', 'message_updated', 'message_deleted', 'reaction_changed', 'pins_changed']) {
      ch.onBroadcast(event: ev, callback: (p) => _onHint(ev, _hintPayload(p)));
    }
    ch.onBroadcast(event: 'typing', callback: (p) {
      final u = _hintPayload(p)['u'];
      if (u is String && u != me) _onTyping(u);
    });
    if (allowPresence) {
      ch.onPresenceSync((_) {
        final online = ch.presenceState().expand((s) => s.presences).map((x) => x.payload['u']).whereType<String>().toSet();
        if (mounted) setState(() => _online = online);
      });
    }
    ch.subscribe((status, _) async {
      if (status == RealtimeSubscribeStatus.subscribed) {
        if (allowPresence && me != null) {
          try {
            await ch.track({'u': me});
          } catch (_) {}
        }
      }
      if (status == RealtimeSubscribeStatus.channelError || status == RealtimeSubscribeStatus.timedOut) _onHint('resync', const {});
    });
    _rt = ch;
  }

  void _onHint(String ev, J p) {
    if (!mounted) return;
    final id = p['id'];
    switch (ev) {
      case 'message_created':
        _scheduleRefresh();
        if (p['thread_root'] is String) _refreshById(p['thread_root']);
      case 'message_updated':
      case 'message_deleted':
      case 'reaction_changed':
        id is String ? _refreshById(id) : _scheduleRefresh();
      case 'pins_changed':
        setState(() => _pinsTick++);
        _refreshById(id);
      default:
        _scheduleRefresh();
        if (_thread != null) _loadThread();
    }
  }

  void _onTyping(String u) {
    if (_members.isNotEmpty && !_members.any((m) => m['user_id'] == u)) return;
    setState(() => _typing[u] = DateTime.now().add(const Duration(seconds: 4)));
    _typingTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final now = DateTime.now();
      setState(() => _typing.removeWhere((_, t) => t.isBefore(now)));
      if (_typing.isEmpty) {
        _typingTimer?.cancel();
        _typingTimer = null;
      }
    });
  }

  /// Maks 1 broadcast typing / 3 detik; non-otoritatif (UI saja)
  void _sendTyping() {
    final ch = _rt;
    if (ch == null || _writeBlock != null || _me == null) return;
    if (DateTime.now().difference(_lastTypingSent).inSeconds < 3) return;
    _lastTypingSent = DateTime.now();
    ch.sendBroadcastMessage(event: 'typing', payload: {'u': _me}).catchError((_) => ChannelResponse.error);
  }

  // ── Scroll & read ──
  void _onScroll() {
    if (!_scroll.hasClients) return;
    final p = _scroll.position;
    final atBottom = p.pixels <= 48;
    if (atBottom != _atBottom) {
      setState(() {
        _atBottom = atBottom;
        if (atBottom) _newBelow = false;
      });
      if (atBottom) _maybeMarkRead();
    }
    if (p.pixels >= p.maxScrollExtent - 300) _loadOlder();
  }

  void _jumpBottom() {
    if (_scroll.hasClients) _scroll.animateTo(0, duration: 250.ms, curve: Curves.easeOut);
    setState(() => _newBelow = false);
  }

  void _maybeMarkRead() {
    if (!mounted || !_atBottom || _msgs.isEmpty) return;
    if (web.document.visibilityState != 'visible') return;
    final seq = math.max(_seq(_msgs.last), _threadMaxSeq);
    if (seq <= _lastMarked) return;
    _readTimer?.cancel();
    _readTimer = Timer(const Duration(seconds: 1), () async {
      if (!mounted || seq <= _lastMarked) return;
      _lastMarked = seq;
      await runAction(context, ref, () => _api.rpc('mark_read', {'p_channel': widget.channelId, 'p_seq': seq}));
    });
  }

  // ── Kirim ──
  Future<bool> _send(_Draft d) async {
    final p = <String, dynamic>{
      'client_msg_id': const Uuid().v4(),
      'body': d.body,
      'sender_id': _me,
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'kind': 'text',
      'priority': d.priority,
      'requires_ack': d.requiresAck,
      'reply_to': _replyTo?['id'],
      'mentions': d.mentions.toList(),
      'reactions': const [],
      'pending': true,
    };
    setState(() {
      _pending.add(p);
      _replyTo = null;
      _unreadFromSeq = null;
    });
    _jumpBottom();
    _deliver(p);
    return true;
  }

  /// Retry memakai client_msg_id yang sama → server mengembalikan id lama (idempoten)
  Future<void> _deliver(J p) async {
    setState(() => p['failed'] = false);
    final r = await runAction<J>(
      context,
      ref,
      () => _api.rpcMap('send_message', {
        'p_channel': widget.channelId,
        'p_body': p['body'],
        'p_client_msg_id': p['client_msg_id'],
        'p_reply_to': p['reply_to'],
        'p_thread_root': null,
        'p_mentions': p['mentions'],
        'p_priority': p['priority'],
        'p_requires_ack': p['requires_ack'],
      }),
    );
    if (!mounted) return;
    if (r == null) {
      setState(() => p['failed'] = true);
      return;
    }
    p['id'] = r['id'];
    p['seq'] = r['seq'];
    await _refreshLatest();
    widget.onChanged();
  }

  Future<bool> _sendThread(_Draft d) async {
    final root = _thread;
    if (root == null) return false;
    final r = await runAction<J>(
      context,
      ref,
      () => _api.rpcMap('send_message', {
        'p_channel': widget.channelId,
        'p_body': d.body,
        'p_client_msg_id': const Uuid().v4(),
        'p_reply_to': null,
        'p_thread_root': root,
        'p_mentions': d.mentions.toList(),
        'p_priority': d.priority,
        'p_requires_ack': d.requiresAck,
      }),
    );
    if (r == null || !mounted) return false;
    await _loadThread();
    _refreshById(root);
    widget.onChanged();
    return true;
  }

  Future<bool> _schedule(String text) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => _ScheduleDialog(channelId: widget.channelId, channelName: _channelName(_ch), initialBody: text, isWfrd: _s?.isWfrd == true),
    );
    return ok == true;
  }

  // ── Aksi pesan ──
  Future<void> _react(J m, String emoji, bool on) async {
    await runAction(context, ref, () => _api.rpc('react_message', {'p_message': m['id'], 'p_emoji': emoji, 'p_on': on}));
    _refreshById(m['id']);
  }

  Future<void> _togglePin(J m) async {
    final on = m['pinned'] != true;
    await runAction(context, ref, () => _api.rpc('pin_message', {'p_message': m['id'], 'p_on': on}), success: on ? 'Pesan disematkan' : 'Sematan dilepas');
    if (!mounted) return;
    setState(() => _pinsTick++);
    _refreshById(m['id']);
  }

  Future<void> _toggleSave(J m) async {
    final on = m['saved'] != true;
    await runAction(context, ref, () => _api.rpc('save_message', {'p_message': m['id'], 'p_on': on}), success: on ? 'Pesan disimpan' : 'Dihapus dari tersimpan');
    _refreshById(m['id']);
  }

  Future<void> _ack(J m) async {
    final r = await runAction(context, ref, () async {
      await _api.rpc('ack_message', {'p_message': m['id']});
      return true;
    }, success: 'Tercatat: Anda sudah membaca pesan ini');
    if (r == true) {
      _refreshById(m['id']);
      widget.onChanged();
    }
  }

  Future<void> _edit(J m) async {
    final ctl = TextEditingController(text: str(m['body'], ''));
    final body = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Edit pesan'),
        content: SizedBox(
          width: 520,
          child: TextField(controller: ctl, autofocus: true, minLines: 2, maxLines: 8, maxLength: 4000, decoration: const InputDecoration(helperText: 'Riwayat edit disimpan untuk audit · maks 24 jam setelah dikirim')),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Batal')),
          FilledButton(onPressed: () => Navigator.pop(c, ctl.text.trim()), child: const Text('Simpan')),
        ],
      ),
    );
    if (body == null || body.isEmpty || body == m['body'] || !mounted) return;
    await runAction(context, ref, () => _api.rpc('edit_message', {'p_message': m['id'], 'p_body': body}), success: 'Pesan diperbarui');
    _refreshById(m['id']);
  }

  Future<void> _delete(J m) async {
    final own = m['sender_id'] == _me;
    final reason = await showReasonDialog(
      context,
      title: 'Hapus pesan',
      message: own
          ? 'Pesan disembunyikan untuk semua anggota. Konten tetap tersimpan terenkripsi untuk kepatuhan.'
          : 'Anda menghapus pesan anggota lain sebagai moderator. Tindakan tercatat di audit log.',
      confirmLabel: 'Hapus',
      destructive: true,
    );
    if (reason == null || !mounted) return;
    await runAction(context, ref, () => _api.rpc('delete_message', {'p_message': m['id'], 'p_reason': reason}), success: 'Pesan dihapus');
    _refreshById(m['id']);
  }

  void _openThread(J m) {
    setState(() {
      _thread = m['id'] as String?;
      _threadMsgs = null;
      _panel = 'thread';
      _flyout = true;
    });
    _loadThread();
  }

  void _closePanel() => setState(() {
        if (_panel == 'thread') {
          _thread = null;
          _threadMsgs = null;
        }
        if (_flyout) {
          _flyout = false;
          if (_panel == 'thread') _panel = 'members';
        } else {
          _panel = null;
        }
      });

  void _openPanel(String p) => setState(() {
        if (_panel == 'thread') {
          _thread = null;
          _threadMsgs = null;
        }
        _panel = p;
        _flyout = true;
      });

  List<_Act> _actionsFor(J m, {bool inThread = false}) {
    if (m['pending'] == true || m['id'] == null) return const [];
    final mine = m['sender_id'] != null && m['sender_id'] == _me;
    final deleted = m['deleted'] == true;
    final canWrite = _writeBlock == null;
    final created = parseDate(m['created_at']);
    final editable = mine && m['kind'] == 'text' && !deleted && created != null && DateTime.now().difference(created).inHours < 24 && canWrite;
    return [
      if (canWrite && !deleted && !inThread) _Act(Icons.reply_rounded, 'Balas', () => setState(() => _replyTo = m)),
      if (canWrite && !deleted && !inThread && m['thread_root'] == null) _Act(Icons.forum_outlined, 'Balas di thread', () => _openThread(m)),
      if (!deleted)
        _Act(Icons.copy_rounded, 'Salin teks', () async {
          await Clipboard.setData(ClipboardData(text: str(m['body'], '')));
          if (mounted) showSnack(context, 'Disalin ke clipboard');
        }),
      if (!deleted) _Act(m['saved'] == true ? Icons.bookmark_remove_outlined : Icons.bookmark_add_outlined, m['saved'] == true ? 'Hapus dari tersimpan' : 'Simpan pesan', () => _toggleSave(m)),
      if (!deleted && _canPin && !inThread) _Act(m['pinned'] == true ? Icons.push_pin : Icons.push_pin_outlined, m['pinned'] == true ? 'Lepas sematan' : 'Sematkan', () => _togglePin(m)),
      if (editable) _Act(Icons.edit_outlined, 'Edit', () => _edit(m)),
      if (m['requires_ack'] == true && (mine || _isMod)) _Act(Icons.fact_check_outlined, 'Laporan wajib-baca', () => _showAckReport(m)),
      if (mine && (_type == 'direct' || _type == 'group' || _isMod)) _Act(Icons.done_all_rounded, 'Dilihat oleh', () => _showReceipts(m)),
      if (!deleted && canWrite && (mine || _isMod)) _Act(Icons.delete_outline_rounded, 'Hapus', () => _delete(m), destructive: true),
    ];
  }

  void _showAckReport(J m) => showDialog<void>(context: context, builder: (_) => _AckReportDialog(messageId: m['id'] as String));

  void _showReceipts(J m) => showDialog<void>(context: context, builder: (_) => _ReceiptsDialog(messageId: m['id'] as String));

  List<_Member> _memberList() {
    final store = ref.read(_chatStoreProvider);
    return [
      for (final m in _members)
        if (m['user_id'] != _me && m['user_id'] is String)
          (
            id: m['user_id'] as String,
            name: _nameOf(store, m['user_id']),
            sub: store.cards[m['user_id']]?['company'] as String?,
            avatar: store.cards[m['user_id']]?['avatar_url'] as String?,
          ),
    ];
  }

  bool _groupable(J a, J b) {
    if (a['sender_id'] == null || a['sender_id'] != b['sender_id']) return false;
    if (_isBotKind(a) || _isBotKind(b) || b['reply_to'] != null || b['priority'] != 'normal' || b['kind'] == 'announcement') return false;
    final da = parseDate(a['created_at']), db = parseDate(b['created_at']);
    return da != null && db != null && db.difference(da).inMinutes.abs() < 5;
  }

  Widget _tile(J m, {required bool compact, bool inThread = false}) {
    final store = ref.read(_chatStoreProvider);
    final mine = m['sender_id'] != null && m['sender_id'] == _me;
    final mentions = _ids(m['mentions']);
    final reply = m['reply_to'] == null ? null : (_find(_msgs, m['reply_to']) ?? _find(_threadMsgs, m['reply_to']));
    final canReact = _writeBlock == null && m['deleted'] != true && m['pending'] != true;
    return _MessageTile(
      key: ValueKey(m['id'] ?? m['client_msg_id']),
      m: m,
      mine: mine,
      compact: compact,
      senderName: _nameOf(store, m['sender_id']),
      senderCard: store.cards[m['sender_id']],
      reply: reply,
      replyName: reply == null ? null : _nameOf(store, reply['sender_id']),
      mentionNames: {for (final id in mentions) id: _nameOf(store, id)},
      mentionsMe: _me != null && mentions.contains(_me),
      meId: _me,
      online: _online.contains(m['sender_id']),
      actions: _actionsFor(m, inThread: inThread),
      onReact: canReact ? (e, on) => _react(m, e, on) : null,
      onReply: canReact && !inThread ? () => setState(() => _replyTo = m) : null,
      onOpenThread: inThread ? null : () => _openThread(m),
      onAck: () => _ack(m),
      onAckReport: () => _showAckReport(m),
      onRetry: m['failed'] == true ? () => _deliver(m) : null,
    );
  }

  // ── Build ──
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final screenW = MediaQuery.sizeOf(context).width;
      final inline = screenW >= 1280 && c.maxWidth >= 760 && !(_panel == 'thread' && false);
      final showPanel = _panel != null && (inline || _flyout);
      final main = Column(children: [
        _header(inline),
        const Divider(height: 1),
        Expanded(
          child: Stack(children: [
            Positioned.fill(child: _body()),
            if (_newBelow)
              Positioned(
                bottom: 12,
                left: 0,
                right: 0,
                child: Center(
                  child: ActionChip(
                    avatar: const Icon(Icons.arrow_downward_rounded, size: 16, color: Colors.white),
                    label: const Text('Pesan baru', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
                    backgroundColor: Brand.blue,
                    side: BorderSide.none,
                    onPressed: _jumpBottom,
                  ).animate().fadeIn().slideY(begin: 0.4, end: 0),
                ),
              ),
          ]),
        ),
        _typingBar(),
        if (_replyTo != null) _replyBar(),
        _composerArea(),
      ]);
      if (!showPanel) return main;
      final panel = _panel == 'thread' ? _threadPanel() : _detailPanel();
      if (inline) return Row(children: [Expanded(child: main), const VerticalDivider(width: 1), SizedBox(width: 340, child: panel)]);
      return Stack(children: [
        main,
        Positioned(
          top: 0,
          bottom: 0,
          right: 0,
          width: math.min(380, c.maxWidth),
          child: Material(elevation: 16, child: panel).animate().slideX(begin: 0.15, end: 0, duration: 180.ms).fadeIn(duration: 180.ms),
        ),
      ]);
    });
  }

  Widget _header(bool inline) {
    final c = _ch;
    final scheme = Theme.of(context).colorScheme;
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final members = _members.length;
    final online = _online.where((u) => u != _me).length;
    final panelVisible = _panel != null && (inline || _flyout);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      child: Row(children: [
        _ChannelAvatar(channel: c, size: 40, online: _type == 'direct' && _online.contains(c?['peer_id'])),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(child: Text(_channelName(c), maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800))),
              if (_archived) const Padding(padding: EdgeInsets.only(left: 8), child: StatusBadge(Brand.grey, 'Diarsipkan', icon: Icons.inventory_2_outlined)),
              if (_locked) const Padding(padding: EdgeInsets.only(left: 8), child: StatusBadge(Brand.red, 'Dikunci', icon: Icons.lock_rounded)),
              if (_isMuted(c)) Padding(padding: const EdgeInsets.only(left: 6), child: Icon(Icons.notifications_off_outlined, size: 16, color: scheme.onSurfaceVariant)),
            ]),
            Text(
              [
                _typeLabel(c?['type']),
                if (members > 0 && _type != 'direct') '$members anggota',
                if (online > 0 && _type != 'direct') '$online online',
                if (_type == 'direct' && _online.contains(c?['peer_id'])) 'Online',
              ].join(' · '),
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ]),
        ),
        if (c?['contract_id'] != null && wide)
          IconButton(tooltip: 'Buka kontrak', icon: const Icon(Icons.handshake_outlined), onPressed: () => context.go('/contracts/${c!['contract_id']}')),
        if (c?['task_id'] != null && wide) IconButton(tooltip: 'Buka task', icon: const Icon(Icons.task_alt_rounded), onPressed: () => context.go('/tasks/${c!['task_id']}')),
        IconButton(tooltip: 'Cari di percakapan', icon: const Icon(Icons.search_rounded), onPressed: () => _openPanel('search')),
        if (wide) IconButton(tooltip: 'Pesan disematkan', icon: const Icon(Icons.push_pin_outlined), onPressed: () => _openPanel('pins')),
        if (_type != 'direct' && wide)
          IconButton(
            tooltip: 'Anggota',
            icon: Badge(isLabelVisible: members > 0, label: Text('$members'), backgroundColor: scheme.secondary, child: const Icon(Icons.group_outlined)),
            onPressed: () => _openPanel('members'),
          ),
        IconButton(
          tooltip: panelVisible ? 'Tutup panel detail' : 'Detail percakapan',
          isSelected: panelVisible,
          icon: const Icon(Icons.view_sidebar_outlined),
          selectedIcon: const Icon(Icons.view_sidebar_rounded),
          onPressed: panelVisible
              ? _closePanel
              : () => setState(() {
                    _panel = _panel == null || _panel == 'thread' ? 'members' : _panel;
                    _flyout = true;
                  }),
        ),
      ]),
    );
  }

  Widget _body() {
    if (_loading) return const LoadingView(message: 'Memuat pesan…');
    if (_error != null) {
      return ErrorView(_error!, onRetry: () {
        setState(() {
          _loading = true;
          _error = null;
        });
        _loadInitial();
      });
    }
    if (_msgs.isEmpty && _pending.isEmpty) {
      return EmptyState(
        icon: Icons.waving_hand_outlined,
        title: 'Belum ada pesan',
        message: _writeBlock ?? 'Mulai percakapan — ketik pesan di bawah. Ketik @ untuk menyebut anggota, CMN- untuk menautkan task.',
      );
    }
    final items = <Widget>[];
    DateTime? lastDay;
    J? prev;
    for (final m in [..._msgs, ..._pending]) {
      final d = parseDate(m['created_at']) ?? DateTime.now();
      final day = DateTime(d.year, d.month, d.day);
      if (lastDay == null || day != lastDay) {
        items.add(_DaySeparator(day));
        lastDay = day;
        prev = null;
      }
      if (_unreadFromSeq != null && m['seq'] != null && _seq(m) == _unreadFromSeq) {
        items.add(const _NewDivider());
        prev = null;
      }
      items.add(_tile(m, compact: prev != null && _groupable(prev, m)));
      prev = m;
    }
    final rev = items.reversed.toList();
    final list = ListView.builder(
      controller: _scroll,
      reverse: true,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      itemCount: rev.length + 1,
      itemBuilder: (context, i) => i == rev.length ? _topOfList() : rev[i],
    );
    return MediaQuery.sizeOf(context).width >= 900 ? SelectionArea(child: list) : list;
  }

  Widget _topOfList() {
    if (_loadingOlder) return const Padding(padding: EdgeInsets.all(16), child: Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))));
    if (_hasMore) return const SizedBox(height: 32);
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 24, 8, 16),
      child: Column(children: [
        _ChannelAvatar(channel: _ch, size: 56),
        const SizedBox(height: 10),
        Text(_channelName(_ch), style: t.titleMedium?.copyWith(fontWeight: FontWeight.w800), textAlign: TextAlign.center),
        Text('Awal percakapan · ${_typeLabel(_ch?['type'])}', style: t.bodySmall),
      ]),
    );
  }

  Widget _typingBar() {
    final store = ref.read(_chatStoreProvider);
    final names = _typing.keys.map((u) => _nameOf(store, u).split(' ').first).toList();
    return AnimatedSize(
      duration: 150.ms,
      child: names.isEmpty
          ? const SizedBox(width: double.infinity)
          : Padding(
              padding: const EdgeInsets.fromLTRB(20, 2, 20, 2),
              child: Row(children: [
                for (var i = 0; i < 3; i++)
                  Container(width: 5, height: 5, margin: const EdgeInsets.only(right: 3), decoration: const BoxDecoration(color: Brand.blue, shape: BoxShape.circle))
                      .animate(onPlay: (c) => c.repeat())
                      .fadeIn(delay: (i * 150).ms, duration: 300.ms)
                      .then()
                      .fadeOut(duration: 300.ms),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    names.length == 1 ? '${names.first} sedang mengetik…' : '${names.take(3).join(', ')} sedang mengetik…',
                    style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic, color: Theme.of(context).colorScheme.onSurfaceVariant),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ]),
            ),
    );
  }

  Widget _replyBar() {
    final r = _replyTo!;
    final store = ref.read(_chatStoreProvider);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 6, 16, 0),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(color: Brand.blue.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(10), border: Border.all(color: Brand.blue.withValues(alpha: 0.2))),
      child: Row(children: [
        const Icon(Icons.reply_rounded, size: 18, color: Brand.blue),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Membalas ${_nameOf(store, r['sender_id'])}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: Brand.blue)),
            Text(str(r['body'], 'Pesan dihapus').replaceAll('\n', ' '), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
          ]),
        ),
        IconButton(tooltip: 'Batal membalas', icon: const Icon(Icons.close_rounded, size: 18), onPressed: () => setState(() => _replyTo = null)),
      ]),
    );
  }

  Widget _composerArea() {
    final block = _writeBlock;
    if (block != null) {
      return Padding(padding: const EdgeInsets.all(12), child: InfoBanner(message: block, icon: Icons.lock_outline_rounded, color: Brand.grey));
    }
    return _Composer(
      key: ValueKey('main-${widget.channelId}'),
      draftKey: widget.channelId,
      members: _memberList(),
      isWfrd: _s?.isWfrd == true,
      onTyping: _sendTyping,
      onSend: _send,
      onSchedule: _schedule,
      hint: 'Ketik pesan ke ${_channelName(_ch)}',
    );
  }

  Widget _threadPanel() {
    final msgs = _threadMsgs;
    final t = Theme.of(context).textTheme;
    final replies = msgs == null ? 0 : math.max(0, msgs.length - 1);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Row(children: [
          const Icon(Icons.forum_rounded, color: Brand.blue, size: 20),
          const SizedBox(width: 8),
          Expanded(child: Text('Thread', style: t.titleMedium?.copyWith(fontWeight: FontWeight.w800))),
          IconButton(tooltip: 'Muat ulang', icon: const Icon(Icons.refresh_rounded, size: 20), onPressed: _loadThread),
          IconButton(tooltip: 'Tutup thread', icon: const Icon(Icons.close_rounded), onPressed: _closePanel),
        ]),
      ),
      const Divider(height: 1),
      Expanded(
        child: msgs == null
            ? const LoadingView()
            : ListView(padding: const EdgeInsets.fromLTRB(12, 8, 12, 12), children: [
                for (final (i, m) in msgs.indexed) ...[
                  _tile(m, compact: i > 1 && _groupable(msgs[i - 1], m), inThread: true),
                  if (i == 0)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Row(children: [
                        Text(replies == 0 ? 'Belum ada balasan' : '$replies balasan', style: t.labelMedium?.copyWith(fontWeight: FontWeight.w700, color: Brand.blue)),
                        const SizedBox(width: 8),
                        const Expanded(child: Divider()),
                      ]),
                    ),
                ],
              ]),
      ),
      if (_writeBlock == null)
        _Composer(
          key: ValueKey('thread-$_thread'),
          draftKey: '${widget.channelId}:$_thread',
          members: _memberList(),
          onTyping: _sendTyping,
          onSend: _sendThread,
          hint: 'Balas di thread',
          compact: true,
        ),
    ]);
  }

  Widget _detailPanel() => _DetailPanel(
        channelId: widget.channelId,
        channel: _ch,
        tab: _panel ?? 'members',
        onTab: (t) => setState(() => _panel = t),
        onClose: _closePanel,
        members: _members,
        online: _online,
        isMod: _isMod,
        canPin: _canPin,
        meId: _me,
        pinsTick: _pinsTick,
        onMembersChanged: _loadMembers,
        onChannelChanged: widget.onChanged,
        onMessageChanged: (id) => _refreshById(id),
      );
}

class _DaySeparator extends StatelessWidget {
  const _DaySeparator(this.day);
  final DateTime day;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Row(children: [
        Expanded(child: Divider(color: scheme.outlineVariant)),
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 12),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(color: scheme.surfaceContainerHighest.withValues(alpha: 0.7), borderRadius: BorderRadius.circular(999)),
          child: Text(_dayLabel(day), style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: scheme.onSurfaceVariant)),
        ),
        Expanded(child: Divider(color: scheme.outlineVariant)),
      ]),
    );
  }
}

class _NewDivider extends StatelessWidget {
  const _NewDivider();
  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [
          Expanded(child: Divider(color: Brand.red)),
          Padding(padding: EdgeInsets.symmetric(horizontal: 10), child: Text('Pesan baru', style: TextStyle(color: Brand.red, fontWeight: FontWeight.w800, fontSize: 12))),
          Expanded(child: Divider(color: Brand.red)),
        ]),
      );
}

// ═══════════════════════════ Bubble pesan ═══════════════════════════
class _MessageTile extends StatefulWidget {
  const _MessageTile({
    super.key,
    required this.m,
    required this.mine,
    required this.compact,
    required this.senderName,
    required this.senderCard,
    required this.reply,
    required this.replyName,
    required this.mentionNames,
    required this.mentionsMe,
    required this.meId,
    required this.online,
    required this.actions,
    required this.onReact,
    required this.onReply,
    required this.onOpenThread,
    required this.onAck,
    required this.onAckReport,
    required this.onRetry,
  });
  final J m;
  final bool mine, compact, mentionsMe, online;
  final String senderName;
  final J? senderCard, reply;
  final String? replyName, meId;
  final Map<String, String> mentionNames;
  final List<_Act> actions;
  final void Function(String emoji, bool on)? onReact;
  final VoidCallback? onReply, onOpenThread, onRetry;
  final VoidCallback onAck, onAckReport;

  @override
  State<_MessageTile> createState() => _MessageTileState();
}

class _MessageTileState extends State<_MessageTile> {
  bool _hover = false;

  J get m => widget.m;

  void _sheet() {
    if (widget.actions.isEmpty && widget.onReact == null) return;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (widget.onReact != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                for (final e in _quickEmojis.take(6))
                  InkWell(
                    borderRadius: BorderRadius.circular(24),
                    onTap: () {
                      Navigator.pop(c);
                      widget.onReact!(e, !_myReaction(e));
                    },
                    child: Padding(padding: const EdgeInsets.all(8), child: Text(e, style: const TextStyle(fontSize: 26))),
                  ),
              ]),
            ),
          for (final a in widget.actions)
            ListTile(
              leading: Icon(a.icon, color: a.destructive ? Brand.red : null),
              title: Text(a.label, style: TextStyle(color: a.destructive ? Brand.red : null)),
              onTap: () {
                Navigator.pop(c);
                a.onTap();
              },
            ),
        ]),
      ),
    );
  }

  bool _myReaction(String e) => (m['reactions'] as List? ?? const []).any((r) => r is Map && r['emoji'] == e && r['mine'] == true);

  @override
  Widget build(BuildContext context) {
    final touch = MediaQuery.sizeOf(context).width < 900;
    final scheme = Theme.of(context).colorScheme;
    final bot = _isBotKind(m);
    final mine = widget.mine && !bot;
    final pr = m['priority'];

    final header = widget.compact
        ? null
        : Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              if (!mine) Text(widget.senderName, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
              if (!mine && !bot && widget.senderCard?['company'] != null && widget.senderCard?['is_wfrd'] != true)
                Text(str(widget.senderCard!['company']), style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
              Tooltip(message: fmtDateTime(m['created_at']), child: Text(_hm(m['created_at']), style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant))),
              if (m['edited_at'] != null && m['deleted'] != true) Text('Diedit', style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant, fontStyle: FontStyle.italic)),
              if (m['pinned'] == true) const Icon(Icons.push_pin, size: 12, color: Brand.purple),
              if (m['saved'] == true) const Icon(Icons.bookmark, size: 12, color: Brand.blue),
            ]),
          );

    final reactions = (m['reactions'] as List? ?? const []).whereType<Map>().toList();
    final replyCount = (m['reply_count'] as num?)?.toInt() ?? 0;

    final column = Column(crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      if (header != null) header,
      Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (mine && !touch) _toolbar(),
        Flexible(child: _bubble(context, bot, mine, pr)),
        if (!mine && !touch) _toolbar(),
      ]),
      if (reactions.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Wrap(spacing: 4, runSpacing: 4, children: [
            for (final r in reactions)
              _ReactionChip(
                emoji: str(r['emoji']),
                count: (r['count'] as num?)?.toInt() ?? 0,
                mine: r['mine'] == true,
                onTap: widget.onReact == null ? null : () => widget.onReact!(str(r['emoji']), r['mine'] != true),
              ),
          ]),
        ),
      if (replyCount > 0 && widget.onOpenThread != null)
        TextButton.icon(
          style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 6)),
          onPressed: widget.onOpenThread,
          icon: const Icon(Icons.subdirectory_arrow_right_rounded, size: 16),
          label: Text('$replyCount balasan', style: const TextStyle(fontWeight: FontWeight.w700)),
        ),
      if (m['requires_ack'] == true && m['deleted'] != true && m['id'] != null) Padding(padding: const EdgeInsets.only(top: 6), child: _ackRow()),
      if (m['pending'] == true) Padding(padding: const EdgeInsets.only(top: 3), child: _pendingRow()),
    ]);

    final avatar = widget.compact
        ? const SizedBox(width: 36)
        : bot
            ? CircleAvatar(radius: 18, backgroundColor: Brand.navy, child: Icon(_kindStyle(m['kind']).$2 == Icons.smart_toy_outlined ? Icons.smart_toy_rounded : _kindStyle(m['kind']).$2, color: Colors.white, size: 18))
            : Stack(clipBehavior: Clip.none, children: [
                Avatar(name: widget.senderName, url: widget.senderCard?['avatar_url'] as String?, radius: 18),
                if (widget.online) const Positioned(right: -1, bottom: -1, child: _OnlineDot(size: 12)),
              ]);

    final row = mine
        ? Row(mainAxisAlignment: MainAxisAlignment.end, crossAxisAlignment: CrossAxisAlignment.start, children: [const SizedBox(width: 48), Flexible(child: column)])
        : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [avatar, const SizedBox(width: 10), Flexible(child: column), const SizedBox(width: 48)]);

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onLongPress: touch ? _sheet : null,
        child: Padding(padding: EdgeInsets.only(top: widget.compact ? 2 : 12), child: row),
      ),
    );
  }

  Widget _toolbar() {
    final show = _hover && (widget.actions.isNotEmpty || widget.onReact != null);
    return IgnorePointer(
      ignoring: !show,
      child: AnimatedOpacity(
        opacity: show ? 1 : 0,
        duration: 120.ms,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Material(
            elevation: 2,
            borderRadius: BorderRadius.circular(10),
            color: Theme.of(context).colorScheme.surface,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (widget.onReact != null) ...[
                for (final e in _quickEmojis.take(3))
                  InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => widget.onReact!(e, !_myReaction(e)),
                    child: Padding(padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 4), child: Text(e, style: const TextStyle(fontSize: 16))),
                  ),
                PopupMenuButton<String>(
                  tooltip: 'Reaksi lain',
                  padding: EdgeInsets.zero,
                  iconSize: 18,
                  icon: const Icon(Icons.add_reaction_outlined),
                  onSelected: (e) => widget.onReact!(e, !_myReaction(e)),
                  itemBuilder: (_) => [
                    PopupMenuItem<String>(
                      enabled: false,
                      child: Wrap(spacing: 2, children: [
                        for (final e in _quickEmojis)
                          InkWell(
                            onTap: () {
                              Navigator.pop(context, e);
                            },
                            child: Padding(padding: const EdgeInsets.all(4), child: Text(e, style: const TextStyle(fontSize: 22))),
                          ),
                      ]),
                    ),
                  ],
                ),
              ],
              if (widget.onReply != null) IconButton(tooltip: 'Balas', iconSize: 18, visualDensity: VisualDensity.compact, onPressed: widget.onReply, icon: const Icon(Icons.reply_rounded)),
              if (widget.actions.isNotEmpty)
                PopupMenuButton<int>(
                  tooltip: 'Aksi lainnya',
                  iconSize: 18,
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.more_horiz_rounded),
                  onSelected: (i) => widget.actions[i].onTap(),
                  itemBuilder: (_) => [
                    for (final (i, a) in widget.actions.indexed)
                      PopupMenuItem<int>(
                        value: i,
                        child: Row(children: [
                          Icon(a.icon, size: 18, color: a.destructive ? Brand.red : null),
                          const SizedBox(width: 12),
                          Text(a.label, style: TextStyle(color: a.destructive ? Brand.red : null)),
                        ]),
                      ),
                  ],
                ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _bubble(BuildContext context, bool bot, bool mine, dynamic pr) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final deleted = m['deleted'] == true;
    final prColor = pr == 'urgent' ? Brand.red : (pr == 'important' ? Brand.amber : null);
    final (kColor, kIcon, kLabel) = _kindStyle(m['kind']);
    final announce = m['kind'] == 'announcement';
    Color bg;
    Color? borderColor;
    if (deleted) {
      bg = Colors.transparent;
      borderColor = scheme.outlineVariant;
    } else if (bot || announce) {
      bg = kColor.withValues(alpha: dark ? 0.16 : 0.07);
      borderColor = kColor.withValues(alpha: 0.35);
    } else if (mine) {
      bg = Brand.blue.withValues(alpha: dark ? 0.28 : 0.10);
    } else {
      bg = dark ? scheme.surfaceContainerHighest : const Color(0xFFF2F4F7);
    }
    if (widget.mentionsMe && !mine && !deleted) {
      bg = Color.alphaBlend(Brand.amber.withValues(alpha: 0.10), bg);
      borderColor = Brand.amber.withValues(alpha: 0.5);
    }
    if (prColor != null && !deleted) borderColor = prColor.withValues(alpha: 0.7);
    final r = const Radius.circular(14);
    final small = const Radius.circular(4);
    final radius = BorderRadius.only(
      topLeft: !mine && !widget.compact ? small : r,
      topRight: mine && !widget.compact ? small : r,
      bottomLeft: r,
      bottomRight: r,
    );
    final body = str(m['body'], '');
    final taskRefs = _ids(m['task_refs']).where((t) => !body.contains(t)).toList();
    return Container(
      constraints: const BoxConstraints(maxWidth: 680),
      padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
      decoration: BoxDecoration(color: bg, borderRadius: radius, border: borderColor == null ? null : Border.all(color: borderColor, width: prColor != null ? 1.5 : 1)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        if (prColor != null && !deleted)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(pr == 'urgent' ? Icons.priority_high_rounded : Icons.error_outline_rounded, size: 14, color: prColor),
              const SizedBox(width: 4),
              Text(pr == 'urgent' ? 'URGENT' : 'PENTING', style: TextStyle(color: prColor, fontWeight: FontWeight.w900, fontSize: 11, letterSpacing: 1)),
            ]),
          ),
        if ((bot || announce) && !deleted)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(kIcon, size: 14, color: kColor),
              const SizedBox(width: 4),
              Text(kLabel.toUpperCase(), style: TextStyle(color: kColor, fontWeight: FontWeight.w800, fontSize: 10.5, letterSpacing: 0.8)),
            ]),
          ),
        if (m['reply_to'] != null && !deleted) _ReplyQuote(name: widget.replyName, msg: widget.reply),
        if (deleted)
          Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.block_rounded, size: 14, color: scheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Text('Pesan ini dihapus', style: TextStyle(fontStyle: FontStyle.italic, color: scheme.onSurfaceVariant)),
          ])
        else
          _RichBody(text: body, mentionNames: widget.mentionNames, meId: widget.meId),
        if (taskRefs.isNotEmpty && !deleted)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Wrap(spacing: 6, runSpacing: 6, children: [for (final t in taskRefs) _TaskRefChip(taskId: t, card: true)]),
          ),
      ]),
    );
  }

  Widget _ackRow() {
    if (widget.mine) {
      return TextButton.icon(
        style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
        onPressed: widget.onAckReport,
        icon: const Icon(Icons.fact_check_outlined, size: 16),
        label: const Text('Wajib dibaca · lihat laporan'),
      );
    }
    if (m['acked_by_me'] == true) return const StatusBadge(Brand.green, 'Anda sudah membaca', icon: Icons.task_alt_rounded);
    return FilledButton.tonalIcon(
      style: FilledButton.styleFrom(visualDensity: VisualDensity.compact, backgroundColor: Brand.amber.withValues(alpha: 0.18), foregroundColor: const Color(0xFF93370D)),
      onPressed: widget.onAck,
      icon: const Icon(Icons.check_circle_outline_rounded, size: 18),
      label: const Text('Saya sudah membaca'),
    );
  }

  Widget _pendingRow() {
    final scheme = Theme.of(context).colorScheme;
    if (m['failed'] == true) {
      return Row(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.error_outline_rounded, size: 14, color: Brand.red),
        const SizedBox(width: 4),
        const Text('Gagal terkirim', style: TextStyle(color: Brand.red, fontSize: 12, fontWeight: FontWeight.w600)),
        TextButton(onPressed: widget.onRetry, style: TextButton.styleFrom(visualDensity: VisualDensity.compact), child: const Text('Kirim ulang')),
      ]);
    }
    return Row(mainAxisSize: MainAxisSize.min, children: [
      SizedBox(width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 1.5, color: scheme.onSurfaceVariant)),
      const SizedBox(width: 6),
      Text('Mengirim…', style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
    ]);
  }
}

class _ReactionChip extends StatelessWidget {
  const _ReactionChip({required this.emoji, required this.count, required this.mine, this.onTap});
  final String emoji;
  final int count;
  final bool mine;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: mine ? Brand.blue.withValues(alpha: 0.12) : scheme.surface,
      shape: StadiumBorder(side: BorderSide(color: mine ? Brand.blue.withValues(alpha: 0.5) : scheme.outlineVariant)),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          child: Text('$emoji $count', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: mine ? Brand.blue : scheme.onSurface)),
        ),
      ),
    );
  }
}

class _ReplyQuote extends StatelessWidget {
  const _ReplyQuote({required this.name, required this.msg});
  final String? name;
  final J? msg;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = msg == null ? 'Pesan sebelumnya' : (msg!['deleted'] == true ? 'Pesan dihapus' : str(msg!['body'], '').replaceAll('\n', ' '));
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(color: scheme.onSurface.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(8)),
      clipBehavior: Clip.antiAlias,
      child: IntrinsicHeight(
        child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(width: 3, color: Brand.blue),
          Flexible(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 5, 10, 5),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                if (name != null) Text(name!, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: Brand.blue)),
                Text(text, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}

// ═══════════════════════════ Teks kaya (markdown subset aman) ═══════════════════════════
final _taskInText = taskIdRe.pattern.replaceAll(RegExp(r'^\^|\$$'), '');

class _RichBody extends ConsumerStatefulWidget {
  const _RichBody({required this.text, this.mentionNames = const {}, this.meId, this.maxLines});
  final String text;
  final Map<String, String> mentionNames;
  final String? meId;
  final int? maxLines;
  @override
  ConsumerState<_RichBody> createState() => _RichBodyState();
}

class _RichBodyState extends ConsumerState<_RichBody> {
  final _recognizers = <TapGestureRecognizer>[];

  void _clear() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _clear();
    super.dispose();
  }

  RegExp _regex() {
    final names = widget.mentionNames.values.where((n) => n.isNotEmpty).toSet().toList()..sort((a, b) => b.length.compareTo(a.length));
    final parts = [
      r'(?<url>https?://[^\s<>"]+)',
      '(?<task>\\b$_taskInText)',
      r'(?<bold>\*\*[^*\n]+\*\*)',
      r'(?<code>`[^`\n]+`)',
      r'(?<ital>(?<![\w])_[^_\n]+_(?![\w]))',
      if (names.isNotEmpty) '(?<men>@(?:${names.map(RegExp.escape).join('|')}))',
    ];
    return RegExp(parts.join('|'));
  }

  List<InlineSpan> _inline(String s, RegExp re, TextStyle? lineStyle) {
    final scheme = Theme.of(context).colorScheme;
    final out = <InlineSpan>[];
    var i = 0;
    for (final mt in re.allMatches(s)) {
      if (mt.start > i) out.add(TextSpan(text: s.substring(i, mt.start), style: lineStyle));
      i = mt.end;
      final url = mt.namedGroup('url');
      final task = mt.namedGroup('task');
      final bold = mt.namedGroup('bold');
      final code = mt.namedGroup('code');
      final ital = mt.namedGroup('ital');
      final men = re.pattern.contains('(?<men>') ? mt.namedGroup('men') : null;
      if (url != null) {
        final trail = RegExp(r'[.,;:!?)\]]+$').firstMatch(url)?.group(0) ?? '';
        final clean = url.substring(0, url.length - trail.length);
        if (UrlPolicy.clickable(clean)) {
          final rec = TapGestureRecognizer()..onTap = () => runAction(context, ref, () => UrlPolicy.open(clean));
          _recognizers.add(rec);
          out.add(TextSpan(
            text: clean,
            recognizer: rec,
            mouseCursor: SystemMouseCursors.click,
            style: TextStyle(color: scheme.primary, decoration: TextDecoration.underline, decorationColor: scheme.primary, fontWeight: FontWeight.w600),
          ));
        } else {
          out.add(TextSpan(text: clean, style: lineStyle));
        }
        if (trail.isNotEmpty) out.add(TextSpan(text: trail, style: lineStyle));
      } else if (task != null) {
        out.add(WidgetSpan(alignment: PlaceholderAlignment.middle, child: _TaskRefChip(taskId: task)));
      } else if (bold != null) {
        out.add(TextSpan(text: bold.substring(2, bold.length - 2), style: (lineStyle ?? const TextStyle()).copyWith(fontWeight: FontWeight.w800)));
      } else if (code != null) {
        out.add(TextSpan(
          text: code.substring(1, code.length - 1),
          style: TextStyle(fontFamily: 'monospace', fontSize: 13, backgroundColor: scheme.onSurface.withValues(alpha: 0.08), color: const Color(0xFFC11574)),
        ));
      } else if (ital != null) {
        out.add(TextSpan(text: ital.substring(1, ital.length - 1), style: (lineStyle ?? const TextStyle()).copyWith(fontStyle: FontStyle.italic)));
      } else if (men != null) {
        final name = men.substring(1);
        final isMe = widget.meId != null && widget.mentionNames[widget.meId] == name;
        out.add(TextSpan(
          text: men,
          style: TextStyle(color: isMe ? const Color(0xFF93370D) : scheme.primary, fontWeight: FontWeight.w800, backgroundColor: isMe ? Brand.amber.withValues(alpha: 0.25) : null),
        ));
      }
    }
    if (i < s.length) out.add(TextSpan(text: s.substring(i), style: lineStyle));
    return out;
  }

  @override
  Widget build(BuildContext context) {
    _clear();
    final scheme = Theme.of(context).colorScheme;
    final re = _regex();
    final spans = <InlineSpan>[];
    final lines = widget.text.split('\n');
    for (final (i, raw) in lines.indexed) {
      var line = raw;
      TextStyle? ls;
      if (line.startsWith('> ')) {
        spans.add(TextSpan(text: '▎ ', style: TextStyle(color: scheme.outline, fontWeight: FontWeight.w900)));
        line = line.substring(2);
        ls = TextStyle(color: scheme.onSurfaceVariant, fontStyle: FontStyle.italic);
      } else if (RegExp(r'^\s*[-*] ').hasMatch(line)) {
        spans.add(const TextSpan(text: '  •  ', style: TextStyle(fontWeight: FontWeight.w900)));
        line = line.replaceFirst(RegExp(r'^\s*[-*] '), '');
      }
      spans.addAll(_inline(line, re, ls));
      if (i < lines.length - 1) spans.add(const TextSpan(text: '\n'));
    }
    return Text.rich(
      TextSpan(children: spans),
      maxLines: widget.maxLines,
      overflow: widget.maxLines == null ? null : TextOverflow.ellipsis,
      style: const TextStyle(fontSize: 14, height: 1.42),
    );
  }
}

class _TaskRefChip extends ConsumerStatefulWidget {
  const _TaskRefChip({required this.taskId, this.card = false});
  final String taskId;
  final bool card;
  @override
  ConsumerState<_TaskRefChip> createState() => _TaskRefChipState();
}

class _TaskRefChipState extends ConsumerState<_TaskRefChip> {
  late final Future<String?> _f = _lookupTask(ref, widget.taskId);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String?>(
      future: _f,
      builder: (context, s) {
        final id = s.data;
        final mono = TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.w800, fontSize: 12.5, color: id == null ? null : Brand.blue);
        if (id == null) {
          return Tooltip(
            message: s.connectionState == ConnectionState.done ? 'Task tidak ditemukan atau Anda tidak berhak melihatnya' : 'Memeriksa akses…',
            child: Text(widget.taskId, style: mono),
          );
        }
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 1),
          child: Material(
            color: Brand.blue.withValues(alpha: 0.08),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: BorderSide(color: Brand.blue.withValues(alpha: 0.3))),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => context.go('/tasks/$id'),
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 7, vertical: widget.card ? 5 : 1),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.task_alt_rounded, size: 13, color: Brand.blue),
                  const SizedBox(width: 4),
                  Text(widget.taskId, style: mono),
                  if (widget.card) ...[const SizedBox(width: 6), const Text('Buka', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Brand.blue))],
                ]),
              ),
            ),
          ),
        );
      },
    );
  }
}

// ═══════════════════════════ Composer ═══════════════════════════
typedef _Sug = ({String key, String title, String? sub, Widget leading, VoidCallback pick});

class _Composer extends ConsumerStatefulWidget {
  const _Composer({
    super.key,
    required this.draftKey,
    required this.members,
    required this.onSend,
    this.onSchedule,
    this.onTyping,
    this.isWfrd = false,
    this.hint = 'Ketik pesan',
    this.compact = false,
  });
  final String draftKey;
  final List<_Member> members;
  final Future<bool> Function(_Draft d) onSend;
  final Future<bool> Function(String text)? onSchedule;
  final VoidCallback? onTyping;
  final bool isWfrd, compact;
  final String hint;
  @override
  ConsumerState<_Composer> createState() => _ComposerState();
}

class _ComposerState extends ConsumerState<_Composer> {
  late final _ctl = TextEditingController(text: ref.read(_chatStoreProvider).drafts[widget.draftKey] ?? '');
  late final _focus = FocusNode(onKeyEvent: _onKey);
  final Map<String, String> _mentions = {};
  String _priority = 'normal';
  bool _ack = false, _sending = false, _focused = false;
  String? _mq, _tq;
  List<J> _taskSugs = const [];
  int _sel = 0;
  Timer? _taskDebounce;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() => _focused = _focus.hasFocus));
  }

  @override
  void dispose() {
    _taskDebounce?.cancel();
    _ctl.dispose();
    _focus.dispose();
    super.dispose();
  }

  List<_Sug> get _sugs {
    if (_mq != null) {
      final q = _mq!.toLowerCase();
      return [
        for (final m in widget.members.where((m) => m.name.toLowerCase().contains(q)).take(6))
          (key: m.id, title: m.name, sub: m.sub, leading: Avatar(name: m.name, url: m.avatar, radius: 14), pick: () => _pickMention(m)),
      ];
    }
    if (_tq != null) {
      return [
        for (final t in _taskSugs)
          (
            key: str(t['task_id']),
            title: str(t['task_id']),
            sub: str(t['title'], ''),
            leading: const Icon(Icons.task_alt_rounded, color: Brand.blue, size: 20),
            pick: () => _replaceToken(str(t['task_id']), RegExp(r'CMN-[A-Z0-9-]*$')),
          ),
      ];
    }
    return const [];
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final sugs = _sugs;
    if (sugs.isNotEmpty) {
      if (k == LogicalKeyboardKey.arrowDown) {
        setState(() => _sel = (_sel + 1) % sugs.length);
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.arrowUp) {
        setState(() => _sel = (_sel - 1 + sugs.length) % sugs.length);
        return KeyEventResult.handled;
      }
      if (e is KeyDownEvent && (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter || k == LogicalKeyboardKey.tab)) {
        sugs[_sel.clamp(0, sugs.length - 1)].pick();
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.escape) {
        setState(() {
          _mq = null;
          _tq = null;
        });
        return KeyEventResult.handled;
      }
    }
    if ((k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter) && !HardwareKeyboard.instance.isShiftPressed) {
      final composing = _ctl.value.composing;
      if (composing.isValid && !composing.isCollapsed) return KeyEventResult.ignored;
      if (e is KeyDownEvent) _send();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _onChanged(String v) {
    ref.read(_chatStoreProvider).drafts[widget.draftKey] = v;
    if (v.isNotEmpty) widget.onTyping?.call();
    final cursor = _ctl.selection.baseOffset < 0 ? v.length : _ctl.selection.baseOffset.clamp(0, v.length);
    final before = v.substring(0, cursor);
    final mm = RegExp(r'(?:^|\s)@([^\s@]{0,30})$').firstMatch(before);
    final tm = mm == null ? RegExp(r'(?:^|\s)(CMN-[A-Za-z0-9-]{0,30})$').firstMatch(before) : null;
    setState(() {
      _mq = mm?.group(1);
      _sel = 0;
      final tq = tm?.group(1)?.toUpperCase();
      if (tq != _tq) {
        _tq = tq;
        _taskSugs = const [];
        _taskDebounce?.cancel();
        if (tq != null && tq.length >= 5 && !taskIdRe.hasMatch(tq)) {
          _taskDebounce = Timer(const Duration(milliseconds: 250), () => _searchTasks(tq));
        }
      }
    });
  }

  Future<void> _searchTasks(String q) async {
    try {
      final rows = await ref.read(apiProvider).select('v_task_tracking', 'id,task_id,title',
          build: (b) => b.ilike('task_id', '${q.replaceAll('%', '').replaceAll('_', r'\_')}%').order('task_id').limit(6));
      if (mounted && _tq == q) setState(() => _taskSugs = rows);
    } catch (_) {}
  }

  void _replaceToken(String insert, RegExp tokenAtEnd) {
    final v = _ctl.text;
    final cursor = _ctl.selection.baseOffset < 0 ? v.length : _ctl.selection.baseOffset.clamp(0, v.length);
    final before = v.substring(0, cursor), after = v.substring(cursor);
    final mt = tokenAtEnd.firstMatch(before);
    final start = mt?.start ?? cursor;
    final ins = '$insert ';
    _ctl.value = TextEditingValue(text: before.substring(0, start) + ins + after, selection: TextSelection.collapsed(offset: start + ins.length));
    ref.read(_chatStoreProvider).drafts[widget.draftKey] = _ctl.text;
    setState(() {
      _mq = null;
      _tq = null;
      _taskSugs = const [];
    });
    _focus.requestFocus();
  }

  void _pickMention(_Member m) {
    _mentions[m.id] = m.name;
    _replaceToken('@${m.name}', RegExp(r'@[^\s@]*$'));
  }

  void _insert(String s) {
    final v = _ctl.value;
    final sel = v.selection.isValid ? v.selection : TextSelection.collapsed(offset: v.text.length);
    final nt = v.text.replaceRange(sel.start, sel.end, s);
    _ctl.value = TextEditingValue(text: nt, selection: TextSelection.collapsed(offset: sel.start + s.length));
    _onChanged(nt);
    _focus.requestFocus();
  }

  void _wrap(String token) {
    final v = _ctl.value;
    final s = v.selection.isValid ? v.selection : TextSelection.collapsed(offset: v.text.length);
    final picked = v.text.substring(s.start, s.end);
    final nt = v.text.replaceRange(s.start, s.end, '$token$picked$token');
    _ctl.value = TextEditingValue(
      text: nt,
      selection: picked.isEmpty
          ? TextSelection.collapsed(offset: s.start + token.length)
          : TextSelection(baseOffset: s.start + token.length, extentOffset: s.end + token.length),
    );
    _onChanged(nt);
    _focus.requestFocus();
  }

  void _bullet() {
    final v = _ctl.value;
    final pos = v.selection.isValid ? v.selection.start : v.text.length;
    final lineStart = v.text.lastIndexOf('\n', pos - 1 < 0 ? 0 : pos - 1) + 1;
    final nt = v.text.replaceRange(lineStart, lineStart, '- ');
    _ctl.value = TextEditingValue(text: nt, selection: TextSelection.collapsed(offset: pos + 2));
    _onChanged(nt);
    _focus.requestFocus();
  }

  Future<void> _send() async {
    final body = _ctl.text.trim();
    if (body.isEmpty || _sending) return;
    if (body.length > 4000) {
      showSnack(context, 'Pesan maksimal 4.000 karakter', error: true);
      return;
    }
    final mentions = {for (final e in _mentions.entries) if (body.contains('@${e.value}')) e.key};
    final d = (body: body, mentions: mentions, priority: _priority, requiresAck: _ack);
    final prev = _ctl.text;
    final store = ref.read(_chatStoreProvider);
    _ctl.clear();
    store.drafts.remove(widget.draftKey);
    setState(() {
      _sending = true;
      _mq = null;
      _tq = null;
    });
    final ok = await widget.onSend(d);
    if (!mounted) return;
    setState(() {
      _sending = false;
      if (ok) {
        _mentions.clear();
        _priority = 'normal';
        _ack = false;
      }
    });
    if (!ok) {
      _ctl.text = prev;
      store.drafts[widget.draftKey] = prev;
    }
    _focus.requestFocus();
  }

  Future<void> _schedule() async {
    final ok = await widget.onSchedule!(_ctl.text.trim());
    if (ok && mounted) {
      _ctl.clear();
      ref.read(_chatStoreProvider).drafts.remove(widget.draftKey);
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final sugs = _sugs;
    final canSend = _ctl.text.trim().isNotEmpty && !_sending;
    Widget tb(IconData icon, String tip, VoidCallback onTap) =>
        IconButton(tooltip: tip, onPressed: onTap, icon: Icon(icon, size: 19), visualDensity: VisualDensity.compact, color: scheme.onSurfaceVariant);
    return Padding(
      padding: EdgeInsets.fromLTRB(widget.compact ? 10 : 16, 6, widget.compact ? 10 : 16, widget.compact ? 10 : 14),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (sugs.isNotEmpty)
          Material(
            elevation: 6,
            borderRadius: BorderRadius.circular(12),
            color: scheme.surface,
            clipBehavior: Clip.antiAlias,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              for (final (i, s) in sugs.indexed)
                ListTile(
                  dense: true,
                  selected: i == _sel,
                  selectedTileColor: scheme.primary.withValues(alpha: 0.08),
                  leading: s.leading,
                  title: Text(s.title, style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: s.sub == null || s.sub!.isEmpty ? null : Text(s.sub!, maxLines: 1, overflow: TextOverflow.ellipsis),
                  onTap: s.pick,
                ),
            ]),
          ).animate().fadeIn(duration: 120.ms).slideY(begin: 0.1, end: 0),
        if (sugs.isNotEmpty) const SizedBox(height: 6),
        AnimatedContainer(
          duration: 150.ms,
          decoration: BoxDecoration(
            color: scheme.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: _focused ? scheme.primary : scheme.outlineVariant, width: _focused ? 1.5 : 1),
            boxShadow: _focused ? [BoxShadow(color: scheme.primary.withValues(alpha: 0.10), blurRadius: 10)] : null,
          ),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (_priority != 'normal' || _ack)
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
                child: Wrap(spacing: 6, children: [
                  if (_priority != 'normal')
                    InputChip(
                      visualDensity: VisualDensity.compact,
                      avatar: Icon(_priority == 'urgent' ? Icons.priority_high_rounded : Icons.error_outline_rounded, size: 16, color: _priority == 'urgent' ? Brand.red : Brand.amber),
                      label: Text(_priority == 'urgent' ? 'URGENT' : 'PENTING', style: TextStyle(fontWeight: FontWeight.w800, color: _priority == 'urgent' ? Brand.red : Brand.amber)),
                      onDeleted: () => setState(() => _priority = 'normal'),
                    ),
                  if (_ack)
                    InputChip(
                      visualDensity: VisualDensity.compact,
                      avatar: const Icon(Icons.fact_check_outlined, size: 16),
                      label: const Text('Wajib dibaca'),
                      onDeleted: () => setState(() => _ack = false),
                    ),
                ]),
              ),
            TextField(
              controller: _ctl,
              focusNode: _focus,
              onChanged: _onChanged,
              minLines: 1,
              maxLines: widget.compact ? 5 : 8,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
              style: const TextStyle(fontSize: 14, height: 1.4),
              decoration: InputDecoration(
                hintText: '${widget.hint}…',
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                filled: false,
                isDense: true,
                contentPadding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 6, 4),
              child: Row(children: [
                if (!widget.compact || wide) ...[
                  tb(Icons.format_bold_rounded, 'Tebal (**teks**)', () => _wrap('**')),
                  tb(Icons.format_italic_rounded, 'Miring (_teks_)', () => _wrap('_')),
                  tb(Icons.code_rounded, 'Kode (`teks`)', () => _wrap('`')),
                  tb(Icons.format_list_bulleted_rounded, 'Daftar', _bullet),
                ],
                PopupMenuButton<String>(
                  tooltip: 'Emoji',
                  icon: Icon(Icons.emoji_emotions_outlined, size: 19, color: scheme.onSurfaceVariant),
                  onSelected: _insert,
                  itemBuilder: (_) => [
                    PopupMenuItem<String>(
                      enabled: false,
                      child: SizedBox(
                        width: 260,
                        child: Wrap(children: [
                          for (final e in _emojiGrid)
                            InkWell(
                              borderRadius: BorderRadius.circular(8),
                              onTap: () => Navigator.pop(context, e),
                              child: Padding(padding: const EdgeInsets.all(5), child: Text(e, style: const TextStyle(fontSize: 22))),
                            ),
                        ]),
                      ),
                    ),
                  ],
                ),
                tb(Icons.alternate_email_rounded, 'Sebut anggota', () => _insert(_ctl.text.isEmpty || _ctl.text.endsWith(' ') || _ctl.text.endsWith('\n') ? '@' : ' @')),
                if (widget.isWfrd)
                  PopupMenuButton<String>(
                    tooltip: 'Prioritas & wajib-baca (WFRD)',
                    icon: Icon(Icons.priority_high_rounded, size: 19, color: _priority != 'normal' || _ack ? Brand.red : scheme.onSurfaceVariant),
                    onSelected: (v) => setState(() => v == 'ack' ? _ack = !_ack : _priority = v),
                    itemBuilder: (_) => [
                      CheckedPopupMenuItem(value: 'normal', checked: _priority == 'normal', child: const Text('Normal')),
                      CheckedPopupMenuItem(value: 'important', checked: _priority == 'important', child: const Text('Penting')),
                      CheckedPopupMenuItem(value: 'urgent', checked: _priority == 'urgent', child: const Text('Urgent (push berulang)')),
                      const PopupMenuDivider(),
                      CheckedPopupMenuItem(value: 'ack', checked: _ack, child: const Text('Wajib dibaca')),
                    ],
                  ),
                if (widget.onSchedule != null) tb(Icons.schedule_send_outlined, 'Jadwalkan / berulang', _schedule),
                const Spacer(),
                if (wide && !widget.compact)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Text('Enter kirim · Shift+Enter baris baru', style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
                  ),
                IconButton.filled(
                  tooltip: 'Kirim (Enter)',
                  onPressed: canSend ? _send : null,
                  icon: _sending ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.send_rounded, size: 18),
                ),
              ]),
            ),
          ]),
        ),
      ]),
    );
  }
}

// ═══════════════════════════ Panel detail ═══════════════════════════
class _DetailPanel extends ConsumerWidget {
  const _DetailPanel({
    required this.channelId,
    required this.channel,
    required this.tab,
    required this.onTab,
    required this.onClose,
    required this.members,
    required this.online,
    required this.isMod,
    required this.canPin,
    required this.meId,
    required this.pinsTick,
    required this.onMembersChanged,
    required this.onChannelChanged,
    required this.onMessageChanged,
  });
  final String channelId;
  final J? channel;
  final String tab;
  final ValueChanged<String> onTab;
  final VoidCallback onClose;
  final List<J> members;
  final Set<String> online;
  final bool isMod, canPin;
  final String? meId;
  final int pinsTick;
  final Future<void> Function() onMembersChanged, onChannelChanged;
  final ValueChanged<String> onMessageChanged;

  static const _tabs = [
    ('members', 'Anggota', Icons.group_outlined),
    ('pins', 'Disematkan', Icons.push_pin_outlined),
    ('saved', 'Tersimpan', Icons.bookmark_border_rounded),
    ('search', 'Cari', Icons.search_rounded),
    ('settings', 'Notifikasi', Icons.notifications_none_rounded),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final current = _tabs.firstWhere((x) => x.$1 == tab, orElse: () => _tabs.first);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
        child: Row(children: [
          Expanded(child: Text('Detail', style: t.titleMedium?.copyWith(fontWeight: FontWeight.w800))),
          IconButton(tooltip: 'Tutup', icon: const Icon(Icons.close_rounded), onPressed: onClose),
        ]),
      ),
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(children: [
          for (final (key, label, icon) in _tabs)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ChoiceChip(
                showCheckmark: false,
                visualDensity: VisualDensity.compact,
                avatar: Icon(icon, size: 16),
                label: Text(label),
                selected: key == current.$1,
                onSelected: (_) => onTab(key),
              ),
            ),
        ]),
      ),
      const SizedBox(height: 8),
      const Divider(height: 1),
      Expanded(
        child: switch (current.$1) {
          'pins' => _PinsTab(key: ValueKey('pins-$pinsTick'), channelId: channelId, canPin: canPin, onChanged: onMessageChanged),
          'saved' => _SavedTab(channelId: channelId, onChanged: onMessageChanged),
          'search' => _SearchTab(channelId: channelId),
          'settings' => _ChannelSettingsTab(channel: channel, channelId: channelId, onChanged: onChannelChanged),
          _ => _MembersTab(channel: channel, channelId: channelId, members: members, online: online, isMod: isMod, meId: meId, onChanged: onMembersChanged, onChannelChanged: onChannelChanged),
        },
      ),
    ]);
  }
}

class _MembersTab extends ConsumerWidget {
  const _MembersTab({
    required this.channel,
    required this.channelId,
    required this.members,
    required this.online,
    required this.isMod,
    required this.meId,
    required this.onChanged,
    required this.onChannelChanged,
  });
  final J? channel;
  final String channelId;
  final List<J> members;
  final Set<String> online;
  final bool isMod;
  final String? meId;
  final Future<void> Function() onChanged, onChannelChanged;

  static const _roleOrder = {'owner': 0, 'moderator': 1, 'member': 2, 'readonly': 3};

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final ids = await showDialog<List<String>>(
      context: context,
      builder: (_) => _UserPickerDialog(title: 'Tambah anggota', confirmLabel: 'Tambahkan', multi: true, exclude: {for (final m in members) str(m['user_id'])}),
    );
    if (ids == null || ids.isEmpty || !context.mounted) return;
    final n = await runAction(context, ref, () => ref.read(apiProvider).rpc('chat_add_members', {'p_channel': channelId, 'p_users': ids}));
    if (n != null && context.mounted) showSnack(context, '$n anggota ditambahkan');
    await onChanged();
  }

  Future<void> _dm(BuildContext context, WidgetRef ref, String uid) async {
    final id = await runAction(context, ref, () => ref.read(apiProvider).rpc('create_direct_channel', {'p_user': uid}));
    if (id is String && context.mounted) {
      await onChannelChanged();
      if (context.mounted) context.go('/chat/$id');
    }
  }

  Future<void> _remove(BuildContext context, WidgetRef ref, String uid, String name) async {
    final ok = await showConfirm(context, title: 'Keluarkan $name?', message: 'Ia tidak lagi bisa membaca atau mengirim pesan di percakapan ini.', confirmLabel: 'Keluarkan', destructive: true);
    if (!ok || !context.mounted) return;
    await runAction(context, ref, () => ref.read(apiProvider).rpc('chat_remove_member', {'p_channel': channelId, 'p_user': uid}), success: '$name dikeluarkan');
    await onChanged();
  }

  Future<void> _silence(BuildContext context, WidgetRef ref, String uid, String name, bool on) async {
    final reason = await showReasonDialog(
      context,
      title: on ? 'Bungkam $name (24 jam)' : 'Cabut bungkam $name',
      message: on ? 'Anggota tidak bisa mengirim pesan selama 24 jam.' : 'Anggota bisa kembali mengirim pesan.',
      confirmLabel: on ? 'Bungkam' : 'Cabut',
      destructive: on,
    );
    if (reason == null || !context.mounted) return;
    await runAction(
      context,
      ref,
      () => ref.read(apiProvider).rpc('chat_moderate_member', {
        'p_channel': channelId,
        'p_user': uid,
        'p_silenced_until': on ? DateTime.now().add(const Duration(hours: 24)).toUtc().toIso8601String() : null,
        'p_reason': reason,
      }),
      success: on ? '$name dibungkam 24 jam' : 'Bungkam dicabut',
    );
    await onChanged();
  }

  Future<void> _leave(BuildContext context, WidgetRef ref) async {
    final ok = await showConfirm(context, title: 'Tinggalkan grup?', message: 'Anda tidak akan menerima pesan dari grup ini lagi.', confirmLabel: 'Tinggalkan', destructive: true);
    if (!ok || !context.mounted) return;
    final r = await runAction(context, ref, () async {
      await ref.read(apiProvider).rpc('leave_channel', {'p_channel': channelId});
      return true;
    }, success: 'Anda meninggalkan grup');
    if (r == true && context.mounted) {
      await onChannelChanged();
      if (context.mounted) context.go('/chat');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final store = ref.read(_chatStoreProvider);
    final type = channel?['type'];
    final manageable = isMod && (type == 'group' || type == 'contract');
    final sorted = [...members]..sort((a, b) {
        final oa = online.contains(a['user_id']) ? 0 : 1, ob = online.contains(b['user_id']) ? 0 : 1;
        if (oa != ob) return oa - ob;
        final ra = _roleOrder[a['role']] ?? 9, rb = _roleOrder[b['role']] ?? 9;
        if (ra != rb) return ra - rb;
        return _nameOf(store, a['user_id']).compareTo(_nameOf(store, b['user_id']));
      });
    return ListView(padding: const EdgeInsets.fromLTRB(8, 8, 8, 16), children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
        child: Row(children: [
          Expanded(child: Text('${members.length} anggota · ${online.length} online', style: Theme.of(context).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700))),
          if (manageable) TextButton.icon(onPressed: () => _add(context, ref), icon: const Icon(Icons.person_add_alt_1_rounded, size: 18), label: const Text('Tambah')),
        ]),
      ),
      if (type == 'announcement')
        const Padding(
          padding: EdgeInsets.all(8),
          child: InfoBanner(message: 'Pengumuman: anggota dari perusahaan lain disembunyikan. Presence tidak tersedia.', icon: Icons.visibility_off_outlined),
        ),
      if (members.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Center(child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5)))),
      for (final m in sorted) _memberTile(context, ref, store, m, manageable),
      if (type == 'group') ...[
        const Divider(height: 24),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: OutlinedButton.icon(
            onPressed: () => _leave(context, ref),
            style: OutlinedButton.styleFrom(foregroundColor: Brand.red),
            icon: const Icon(Icons.logout_rounded),
            label: const Text('Tinggalkan grup'),
          ),
        ),
      ],
    ]);
  }

  Widget _memberTile(BuildContext context, WidgetRef ref, _ChatStore store, J m, bool manageable) {
    final uid = str(m['user_id']);
    final card = store.cards[uid];
    final name = _nameOf(store, uid);
    final me = uid == meId;
    final role = m['role'];
    final silenced = parseDate(m['silenced_until'])?.isAfter(DateTime.now()) ?? false;
    final items = <PopupMenuEntry<String>>[
      if (!me) const PopupMenuItem(value: 'dm', child: ListTile(dense: true, leading: Icon(Icons.chat_outlined), title: Text('Kirim pesan langsung'))),
      if (!me && isMod && role != 'owner')
        PopupMenuItem(value: silenced ? 'unsilence' : 'silence', child: ListTile(dense: true, leading: const Icon(Icons.voice_over_off_outlined), title: Text(silenced ? 'Cabut bungkam' : 'Bungkam 24 jam'))),
      if (!me && manageable && role != 'owner')
        const PopupMenuItem(value: 'remove', child: ListTile(dense: true, leading: Icon(Icons.person_remove_outlined, color: Brand.red), title: Text('Keluarkan', style: TextStyle(color: Brand.red)))),
    ];
    final roleBadge = switch (role) {
      'owner' => const StatusBadge(Brand.purple, 'Pemilik'),
      'moderator' => const StatusBadge(Brand.blue, 'Moderator'),
      'readonly' => const StatusBadge(Brand.grey, 'Baca saja'),
      _ => null,
    };
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
      leading: Stack(clipBehavior: Clip.none, children: [
        Avatar(name: name, url: card?['avatar_url'] as String?, radius: 17),
        if (online.contains(uid)) const Positioned(right: -1, bottom: -1, child: _OnlineDot()),
      ]),
      title: Text(me ? '$name (Anda)' : name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
      subtitle: Text(
        [if (silenced) 'Dibungkam', card?['job_title'], card?['company']].whereType<Object>().map((e) => '$e').where((e) => e.isNotEmpty).join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: silenced ? Brand.red : null),
      ),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (roleBadge != null) roleBadge,
        if (items.isNotEmpty)
          PopupMenuButton<String>(
            iconSize: 18,
            onSelected: (v) => switch (v) {
              'dm' => _dm(context, ref, uid),
              'silence' => _silence(context, ref, uid, name, true),
              'unsilence' => _silence(context, ref, uid, name, false),
              _ => _remove(context, ref, uid, name),
            },
            itemBuilder: (_) => items,
          ),
      ]),
    );
  }
}

class _PinsTab extends ConsumerStatefulWidget {
  const _PinsTab({super.key, required this.channelId, required this.canPin, required this.onChanged});
  final String channelId;
  final bool canPin;
  final ValueChanged<String> onChanged;
  @override
  ConsumerState<_PinsTab> createState() => _PinsTabState();
}

class _PinsTabState extends ConsumerState<_PinsTab> {
  late Future<List<J>> _f = _load();

  Future<List<J>> _load() async {
    final rows = await ref.read(apiProvider).rpcList('list_pins', {'p_channel': widget.channelId});
    await _ensureCards(ref, rows.map((r) => r['sender_id']));
    return rows;
  }

  @override
  Widget build(BuildContext context) => AsyncView<List<J>>(
        future: _f,
        onRetry: () => setState(() => _f = _load()),
        builder: (context, rows) {
          if (rows.isEmpty) return const EmptyState(icon: Icons.push_pin_outlined, title: 'Belum ada pesan disematkan', message: 'Sematkan pesan penting agar mudah ditemukan anggota.');
          return ListView(padding: const EdgeInsets.all(12), children: [
            for (final r in rows)
              _MiniMessage(
                r: r,
                meta: 'Disematkan ${fmtRelative(r['pinned_at'])}',
                trailing: widget.canPin
                    ? IconButton(
                        tooltip: 'Lepas sematan',
                        icon: const Icon(Icons.push_pin, size: 18, color: Brand.purple),
                        onPressed: () async {
                          await runAction(context, ref, () => ref.read(apiProvider).rpc('pin_message', {'p_message': r['id'], 'p_on': false}), success: 'Sematan dilepas');
                          widget.onChanged(r['id'] as String);
                          if (mounted) setState(() => _f = _load());
                        },
                      )
                    : null,
              ),
          ]);
        },
      );
}

class _SavedTab extends ConsumerStatefulWidget {
  const _SavedTab({required this.channelId, required this.onChanged});
  final String channelId;
  final ValueChanged<String> onChanged;
  @override
  ConsumerState<_SavedTab> createState() => _SavedTabState();
}

class _SavedTabState extends ConsumerState<_SavedTab> {
  late Future<List<J>> _f = _load();

  Future<List<J>> _load() async {
    final rows = (await ref.read(apiProvider).rpcList('list_saved_messages')).where((r) => r['channel_id'] == widget.channelId).toList();
    await _ensureCards(ref, rows.map((r) => r['sender_id']));
    return rows;
  }

  @override
  Widget build(BuildContext context) => AsyncView<List<J>>(
        future: _f,
        onRetry: () => setState(() => _f = _load()),
        builder: (context, rows) {
          if (rows.isEmpty) return const EmptyState(icon: Icons.bookmark_border_rounded, title: 'Belum ada pesan tersimpan', message: 'Simpan pesan dari menu ⋯ untuk dibaca nanti.');
          return ListView(padding: const EdgeInsets.all(12), children: [
            for (final r in rows)
              _MiniMessage(
                r: r,
                meta: 'Disimpan ${fmtRelative(r['saved_at'])}',
                trailing: IconButton(
                  tooltip: 'Hapus dari tersimpan',
                  icon: const Icon(Icons.bookmark_remove_outlined, size: 18),
                  onPressed: () async {
                    await runAction(context, ref, () => ref.read(apiProvider).rpc('save_message', {'p_message': r['id'], 'p_on': false}), success: 'Dihapus dari tersimpan');
                    widget.onChanged(r['id'] as String);
                    if (mounted) setState(() => _f = _load());
                  },
                ),
              ),
          ]);
        },
      );
}

class _SearchTab extends ConsumerStatefulWidget {
  const _SearchTab({required this.channelId});
  final String channelId;
  @override
  ConsumerState<_SearchTab> createState() => _SearchTabState();
}

class _SearchTabState extends ConsumerState<_SearchTab> {
  final _q = TextEditingController();
  Future<List<J>>? _f;

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  void _search() {
    final q = _q.text.trim();
    if (q.length < 2) {
      showSnack(context, 'Kata kunci minimal 2 karakter', error: true);
      return;
    }
    setState(() => _f = () async {
          final rows = await ref.read(apiProvider).rpcList('search_messages', {'p_query': q, 'p_channel': widget.channelId, 'p_limit': 50});
          await _ensureCards(ref, rows.map((r) => r['sender_id']));
          return rows;
        }());
  }

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            controller: _q,
            autofocus: true,
            onSubmitted: (_) => _search(),
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Cari pesan (90 hari terakhir)',
              prefixIcon: const Icon(Icons.search_rounded, size: 20),
              suffixIcon: IconButton(icon: const Icon(Icons.arrow_forward_rounded, size: 18), onPressed: _search),
            ),
          ),
        ),
        Expanded(
          child: _f == null
              ? const EmptyState(icon: Icons.manage_search_rounded, title: 'Cari di percakapan ini', message: 'Ketik kata kunci lalu tekan Enter.')
              : AsyncView<List<J>>(
                  future: _f!,
                  onRetry: _search,
                  builder: (context, rows) => rows.isEmpty
                      ? const EmptyState(icon: Icons.search_off_rounded, title: 'Tidak ada hasil')
                      : ListView(padding: const EdgeInsets.fromLTRB(12, 0, 12, 12), children: [
                          for (final r in rows) _MiniMessage(r: {...r, 'body': r['snippet']}, meta: fmtDateTime(r['created_at'])),
                        ]),
                ),
        ),
      ]);
}

class _MiniMessage extends ConsumerWidget {
  const _MiniMessage({required this.r, required this.meta, this.trailing});
  final J r;
  final String meta;
  final Widget? trailing;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final store = ref.read(_chatStoreProvider);
    final scheme = Theme.of(context).colorScheme;
    final name = _nameOf(store, r['sender_id']);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
      decoration: BoxDecoration(border: Border.all(color: scheme.outlineVariant), borderRadius: BorderRadius.circular(12)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Avatar(name: name, url: store.cards[r['sender_id']]?['avatar_url'] as String?, radius: 14),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
            Text(meta, style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
            const SizedBox(height: 4),
            r['body'] == null
                ? Text('Pesan dihapus', style: TextStyle(fontStyle: FontStyle.italic, color: scheme.onSurfaceVariant))
                : _RichBody(text: str(r['body'], ''), maxLines: 5),
          ]),
        ),
        if (trailing != null) trailing!,
      ]),
    );
  }
}

class _ChannelSettingsTab extends ConsumerWidget {
  const _ChannelSettingsTab({required this.channel, required this.channelId, required this.onChanged});
  final J? channel;
  final String channelId;
  final Future<void> Function() onChanged;

  Future<void> _set(BuildContext context, WidgetRef ref, String level, DateTime? until) async {
    await runAction(
      context,
      ref,
      () => ref.read(apiProvider).rpc('chat_set_notify', {'p_channel': channelId, 'p_level': level, 'p_muted_until': until?.toUtc().toIso8601String()}),
      success: 'Preferensi notifikasi disimpan',
    );
    await onChanged();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = channel;
    if (c == null) return const LoadingView();
    final level = str(c['notify_level'], 'all');
    final muted = parseDate(c['muted_until']);
    final isMuted = muted != null && muted.isAfter(DateTime.now());
    final t = Theme.of(context).textTheme;
    return ListView(padding: const EdgeInsets.all(16), children: [
      Text('Beri tahu saya untuk', style: t.labelLarge?.copyWith(fontWeight: FontWeight.w700)),
      const SizedBox(height: 8),
      SegmentedButton<String>(
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(value: 'all', label: Text('Semua'), icon: Icon(Icons.notifications_active_outlined)),
          ButtonSegment(value: 'mentions', label: Text('Mention'), icon: Icon(Icons.alternate_email_rounded)),
          ButtonSegment(value: 'none', label: Text('Mati'), icon: Icon(Icons.notifications_off_outlined)),
        ],
        selected: {level},
        onSelectionChanged: (v) => _set(context, ref, v.first, isMuted ? muted : null),
      ),
      const SizedBox(height: 6),
      Text('Pesan URGENT & wajib-baca dari WFRD tetap diberitahukan.', style: t.bodySmall),
      const SizedBox(height: 20),
      Text('Bisukan sementara', style: t.labelLarge?.copyWith(fontWeight: FontWeight.w700)),
      const SizedBox(height: 8),
      if (isMuted)
        InfoBanner(
          message: 'Dibisukan s/d ${fmtDateTime(c['muted_until'])}',
          icon: Icons.notifications_paused_rounded,
          color: Brand.amber,
          action: TextButton(onPressed: () => _set(context, ref, level, null), child: const Text('Aktifkan')),
        )
      else
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final (d, l) in const [(Duration(hours: 1), '1 jam'), (Duration(hours: 8), '8 jam'), (Duration(days: 1), '24 jam'), (Duration(days: 7), '1 minggu')])
            ActionChip(avatar: const Icon(Icons.snooze_rounded, size: 16), label: Text(l), onPressed: () => _set(context, ref, level, DateTime.now().add(d))),
        ]),
      const Divider(height: 36),
      Text('Info percakapan', style: t.labelLarge?.copyWith(fontWeight: FontWeight.w700)),
      const SizedBox(height: 10),
      KeyValueGrid(minItemWidth: 130, [
        ('Jenis', Text(_typeLabel(c['type']))),
        ('Peran Anda', Text(switch (c['member_role']) { 'owner' => 'Pemilik', 'moderator' => 'Moderator', 'readonly' => 'Baca saja', _ => 'Anggota' })),
        ('Aktivitas terakhir', Text(fmtRelative(c['last_message_at']))),
        ('Status', c['is_archived'] == true ? const StatusBadge(Brand.grey, 'Diarsipkan') : (c['is_locked'] == true ? const StatusBadge(Brand.red, 'Dikunci') : const StatusBadge(Brand.green, 'Aktif'))),
      ]),
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 8, children: [
        if (c['contract_id'] != null)
          OutlinedButton.icon(onPressed: () => context.go('/contracts/${c['contract_id']}'), icon: const Icon(Icons.handshake_outlined, size: 18), label: const Text('Buka kontrak')),
        if (c['task_id'] != null) OutlinedButton.icon(onPressed: () => context.go('/tasks/${c['task_id']}'), icon: const Icon(Icons.task_alt_rounded, size: 18), label: const Text('Buka task')),
      ]),
      const SizedBox(height: 16),
      Text('Pesan terenkripsi di server (AES-256) dan disimpan sesuai kebijakan retensi. Link hanya bisa diklik untuk domain OneDrive/SharePoint/COMEN.', style: t.bodySmall),
    ]);
  }
}

// ═══════════════════════════ Dialog ═══════════════════════════
class _AckReportDialog extends ConsumerWidget {
  const _AckReportDialog({required this.messageId});
  final String messageId;
  @override
  Widget build(BuildContext context, WidgetRef ref) => AlertDialog(
        title: const Text('Laporan wajib-baca'),
        content: SizedBox(
          width: 460,
          height: 420,
          child: AsyncView<List<J>>(
            future: ref.read(apiProvider).rpcList('get_ack_report', {'p_message': messageId}),
            builder: (context, rows) {
              final done = rows.where((r) => r['acked_at'] != null).length;
              return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  StatusBadge(Brand.green, '$done sudah membaca', icon: Icons.task_alt_rounded),
                  const SizedBox(width: 8),
                  StatusBadge(Brand.amber, '${rows.length - done} belum', icon: Icons.hourglass_top_rounded),
                ]),
                const SizedBox(height: 8),
                if (rows.isNotEmpty) LinearProgressIndicator(value: done / rows.length, minHeight: 6, borderRadius: BorderRadius.circular(6), color: Brand.green),
                const SizedBox(height: 8),
                Expanded(
                  child: rows.isEmpty
                      ? const EmptyState(title: 'Tidak ada penerima')
                      : ListView(children: [
                          for (final r in rows)
                            ListTile(
                              dense: true,
                              leading: Avatar(name: str(r['name']), radius: 15),
                              title: Text(str(r['name'])),
                              trailing: r['acked_at'] == null
                                  ? const StatusBadge(Brand.amber, 'Belum')
                                  : Tooltip(message: fmtDateTime(r['acked_at']), child: StatusBadge(Brand.green, fmtRelative(r['acked_at']))),
                            ),
                        ]),
                ),
              ]);
            },
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Tutup'))],
      );
}

class _ReceiptsDialog extends ConsumerWidget {
  const _ReceiptsDialog({required this.messageId});
  final String messageId;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Future<List<String>> load() async {
      final r = await ref.read(apiProvider).rpc('get_read_receipts', {'p_message': messageId});
      final ids = _ids(r);
      await _ensureCards(ref, ids);
      return ids;
    }

    return AlertDialog(
      title: const Text('Dilihat oleh'),
      content: SizedBox(
        width: 400,
        height: 360,
        child: AsyncView<List<String>>(
          future: load(),
          builder: (context, ids) {
            final store = ref.read(_chatStoreProvider);
            if (ids.isEmpty) return const EmptyState(icon: Icons.visibility_off_outlined, title: 'Belum ada yang membaca');
            return ListView(children: [
              for (final id in ids)
                ListTile(
                  dense: true,
                  leading: Avatar(name: _nameOf(store, id), url: store.cards[id]?['avatar_url'] as String?, radius: 15),
                  title: Text(_nameOf(store, id)),
                  subtitle: Text(str(store.cards[id]?['company'], '')),
                  trailing: const Icon(Icons.done_all_rounded, color: Brand.blue, size: 18),
                ),
            ]);
          },
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Tutup'))],
    );
  }
}

class _PeoplePicker extends ConsumerStatefulWidget {
  const _PeoplePicker({required this.multi, required this.selected, required this.onChanged, this.exclude = const {}});
  final bool multi;
  final Set<String> selected;
  final ValueChanged<Set<String>> onChanged;
  final Set<String> exclude;
  @override
  ConsumerState<_PeoplePicker> createState() => _PeoplePickerState();
}

class _PeoplePickerState extends ConsumerState<_PeoplePicker> {
  late final Future<List<J>> _f = _loadPeople(ref);
  String _q = '';

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextField(
          autofocus: true,
          onChanged: (v) => setState(() => _q = v.trim().toLowerCase()),
          decoration: const InputDecoration(isDense: true, prefixIcon: Icon(Icons.search_rounded, size: 20), hintText: 'Cari nama / perusahaan'),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: AsyncView<List<J>>(
            future: _f,
            builder: (context, people) {
              final list = people
                  .where((p) => !widget.exclude.contains(p['id']))
                  .where((p) => _q.isEmpty || '${p['full_name']} ${p['company']} ${p['job_title']}'.toLowerCase().contains(_q))
                  .toList();
              if (list.isEmpty) {
                return const EmptyState(icon: Icons.person_search_rounded, title: 'Tidak ada orang ditemukan', message: 'Daftar berisi orang yang berbagi percakapan dengan Anda.');
              }
              return ListView(children: [
                for (final p in list)
                  _personTile(p),
              ]);
            },
          ),
        ),
      ]);

  Widget _personTile(J p) {
    final id = p['id'] as String;
    final sel = widget.selected.contains(id);
    final sub = [p['job_title'], p['company']].whereType<Object>().map((e) => '$e').where((e) => e.isNotEmpty).join(' · ');
    void toggle() {
      final next = {...widget.selected};
      if (widget.multi) {
        sel ? next.remove(id) : next.add(id);
      } else {
        next
          ..clear()
          ..add(id);
      }
      widget.onChanged(next);
    }

    return ListTile(
      dense: true,
      selected: sel,
      selectedTileColor: Brand.blue.withValues(alpha: 0.06),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      leading: Avatar(name: str(p['full_name']), url: p['avatar_url'] as String?, radius: 16),
      title: Text(str(p['full_name']), style: const TextStyle(fontWeight: FontWeight.w700)),
      subtitle: Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: widget.multi ? Checkbox(value: sel, onChanged: (_) => toggle()) : (sel ? const Icon(Icons.check_circle_rounded, color: Brand.blue) : null),
      onTap: toggle,
    );
  }
}

class _UserPickerDialog extends StatefulWidget {
  const _UserPickerDialog({required this.title, required this.confirmLabel, this.multi = false, this.exclude = const {}});
  final String title, confirmLabel;
  final bool multi;
  final Set<String> exclude;
  @override
  State<_UserPickerDialog> createState() => _UserPickerDialogState();
}

class _UserPickerDialogState extends State<_UserPickerDialog> {
  Set<String> _sel = {};
  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.title),
        content: SizedBox(width: 460, height: 440, child: _PeoplePicker(multi: widget.multi, selected: _sel, exclude: widget.exclude, onChanged: (s) => setState(() => _sel = s))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
          FilledButton(onPressed: _sel.isEmpty ? null : () => Navigator.pop(context, _sel.toList()), child: Text('${widget.confirmLabel}${_sel.length > 1 ? ' (${_sel.length})' : ''}')),
        ],
      );
}

class _NewChatDialog extends ConsumerStatefulWidget {
  const _NewChatDialog();
  @override
  ConsumerState<_NewChatDialog> createState() => _NewChatDialogState();
}

class _NewChatDialogState extends ConsumerState<_NewChatDialog> {
  String _mode = 'direct';
  Set<String> _sel = {};
  final _name = TextEditingController();
  final _topic = TextEditingController();
  final _body = TextEditingController();
  bool _allContractors = true, _wfrd = false, _ack = true, _busy = false;
  String _priority = 'important';

  @override
  void dispose() {
    _name.dispose();
    _topic.dispose();
    _body.dispose();
    super.dispose();
  }

  bool get _valid => switch (_mode) {
        'direct' => _sel.length == 1,
        'group' => _name.text.trim().isNotEmpty && _sel.isNotEmpty,
        _ => _name.text.trim().isNotEmpty && _body.text.trim().isNotEmpty && (_allContractors || _wfrd),
      };

  Future<void> _submit() async {
    setState(() => _busy = true);
    final api = ref.read(apiProvider);
    final id = await runAction<dynamic>(context, ref, () {
      switch (_mode) {
        case 'direct':
          return api.rpc('create_direct_channel', {'p_user': _sel.first});
        case 'group':
          return api.rpc('create_group_channel', {'p_name': _name.text.trim(), 'p_members': _sel.toList(), 'p_topic': _topic.text.trim().isEmpty ? null : _topic.text.trim()});
        default:
          return api.rpc('create_announcement', {
            'p_name': _name.text.trim(),
            'p_audience': {if (_allContractors) 'all_contractors': true, if (_wfrd) 'wfrd': true},
            'p_body': _body.text.trim(),
            'p_requires_ack': _ack,
            'p_priority': _priority,
          });
      }
    });
    if (!mounted) return;
    setState(() => _busy = false);
    if (id is String) {
      ref.read(_chatStoreProvider).people = null;
      Navigator.pop(context, id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _sessionOf(ref);
    final canGroup = s?.can('chat.group.create') ?? false;
    final canAnnounce = s?.can('chat.announce') ?? false;
    final t = Theme.of(context).textTheme;
    return AlertDialog(
      title: const Text('Percakapan baru'),
      content: SizedBox(
        width: 540,
        height: 520,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (canGroup || canAnnounce) ...[
            SegmentedButton<String>(
              segments: [
                const ButtonSegment(value: 'direct', label: Text('Langsung'), icon: Icon(Icons.person_rounded)),
                if (canGroup) const ButtonSegment(value: 'group', label: Text('Grup'), icon: Icon(Icons.groups_rounded)),
                if (canAnnounce) const ButtonSegment(value: 'announcement', label: Text('Pengumuman'), icon: Icon(Icons.campaign_rounded)),
              ],
              selected: {_mode},
              onSelectionChanged: (v) => setState(() {
                _mode = v.first;
                _sel = {};
              }),
            ),
            const SizedBox(height: 16),
          ],
          if (_mode == 'direct') ...[
            Text('Pilih orang untuk pesan langsung 1:1.', style: t.bodySmall),
            const SizedBox(height: 8),
            Expanded(child: _PeoplePicker(multi: false, selected: _sel, onChanged: (v) => setState(() => _sel = v))),
          ] else if (_mode == 'group') ...[
            TextField(controller: _name, maxLength: 120, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'Nama grup *', isDense: true)),
            TextField(controller: _topic, maxLength: 500, decoration: const InputDecoration(labelText: 'Topik (opsional)', isDense: true)),
            Text('Anggota (maks 50, maksimal 1 perusahaan contractor) · ${_sel.length} dipilih', style: t.bodySmall),
            const SizedBox(height: 8),
            Expanded(child: _PeoplePicker(multi: true, selected: _sel, onChanged: (v) => setState(() => _sel = v))),
          ] else
            Expanded(
              child: ListView(children: [
                TextField(controller: _name, maxLength: 120, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'Judul pengumuman *')),
                TextField(controller: _body, minLines: 3, maxLines: 6, maxLength: 4000, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'Isi pengumuman *')),
                const SizedBox(height: 8),
                Text('Audiens', style: t.labelLarge),
                CheckboxListTile(value: _allContractors, onChanged: (v) => setState(() => _allContractors = v ?? false), title: const Text('Semua contractor aktif'), contentPadding: EdgeInsets.zero, dense: true),
                CheckboxListTile(value: _wfrd, onChanged: (v) => setState(() => _wfrd = v ?? false), title: const Text('Semua user WFRD'), contentPadding: EdgeInsets.zero, dense: true),
                SwitchListTile(value: _ack, onChanged: (v) => setState(() => _ack = v), title: const Text('Wajib dibaca (tombol "Saya sudah membaca")'), contentPadding: EdgeInsets.zero, dense: true),
                const SizedBox(height: 8),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'normal', label: Text('Normal')),
                    ButtonSegment(value: 'important', label: Text('Penting')),
                    ButtonSegment(value: 'urgent', label: Text('Urgent')),
                  ],
                  selected: {_priority},
                  onSelectionChanged: (v) => setState(() => _priority = v.first),
                ),
              ]),
            ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
        FilledButton(
          onPressed: _busy || !_valid ? null : _submit,
          child: _busy
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : Text(switch (_mode) { 'direct' => 'Mulai chat', 'group' => 'Buat grup', _ => 'Kirim pengumuman' }),
        ),
      ],
    );
  }
}

class _ScheduleDialog extends ConsumerStatefulWidget {
  const _ScheduleDialog({required this.channelId, required this.channelName, required this.initialBody, required this.isWfrd});
  final String channelId, channelName, initialBody;
  final bool isWfrd;
  @override
  ConsumerState<_ScheduleDialog> createState() => _ScheduleDialogState();
}

class _ScheduleDialogState extends ConsumerState<_ScheduleDialog> {
  late final _body = TextEditingController(text: widget.initialBody);
  static const _zones = [('Asia/Jakarta', 'WIB (UTC+7)', 7), ('Asia/Makassar', 'WITA (UTC+8)', 8), ('Asia/Jayapura', 'WIT (UTC+9)', 9)];
  static const _dows = ['Sen', 'Sel', 'Rab', 'Kam', 'Jum', 'Sab', 'Min'];
  String _tz = 'Asia/Jakarta';
  late DateTime _date;
  TimeOfDay _time = const TimeOfDay(hour: 8, minute: 0);
  String _freq = 'none';
  final Set<int> _dow = {1, 2, 3, 4, 5};
  DateTime? _until;
  String _priority = 'normal';
  bool _ack = false, _busy = false;

  int get _offset => _zones.firstWhere((z) => z.$1 == _tz).$3;

  @override
  void initState() {
    super.initState();
    final n = DateTime.now().add(const Duration(days: 1));
    _date = DateTime(n.year, n.month, n.day);
  }

  @override
  void dispose() {
    _body.dispose();
    super.dispose();
  }

  /// Jam dinding di zona terpilih → instan UTC (zona Indonesia tanpa DST)
  DateTime get _sendAtUtc => DateTime.utc(_date.year, _date.month, _date.day, _time.hour, _time.minute).subtract(Duration(hours: _offset));

  String _two(int v) => v.toString().padLeft(2, '0');
  String _ymd(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';

  bool get _valid =>
      _body.text.trim().isNotEmpty && _sendAtUtc.isAfter(DateTime.now().toUtc()) && (_freq != 'weekly' || _dow.isNotEmpty) && (_until == null || !_until!.isBefore(_date));

  Future<void> _submit() async {
    setState(() => _busy = true);
    final ok = await runAction(
      context,
      ref,
      () async {
        await ref.read(apiProvider).rpc('schedule_message', {
          'p_channel': widget.channelId,
          'p_body': _body.text.trim(),
          'p_send_at': _sendAtUtc.toIso8601String(),
          'p_priority': _priority,
          'p_requires_ack': _ack,
          'p_recur_freq': _freq,
          'p_recur_dow': _freq == 'weekly' ? (_dow.toList()..sort()) : null,
          'p_recur_time': _freq == 'none' ? null : '${_two(_time.hour)}:${_two(_time.minute)}:00',
          'p_recur_tz': _tz,
          'p_recur_until': _freq == 'none' || _until == null ? null : _ymd(_until!),
          'p_task': null,
        });
        return true;
      },
      success: _freq == 'none' ? 'Pesan dijadwalkan' : 'Pesan berulang dijadwalkan',
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok == true) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return AlertDialog(
      icon: const Icon(Icons.schedule_send_rounded, color: Brand.blue, size: 32),
      title: Text('Jadwalkan ke ${widget.channelName}', maxLines: 2, overflow: TextOverflow.ellipsis),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            TextField(controller: _body, minLines: 3, maxLines: 6, maxLength: 4000, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'Pesan *')),
            const SizedBox(height: 8),
            Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.event_rounded, size: 18),
                label: Text(DateFormat('EEE, d MMM yyyy', 'id').format(_date)),
                onPressed: () async {
                  final now = DateTime.now();
                  final d = await showDatePicker(context: context, firstDate: DateTime(now.year, now.month, now.day), lastDate: now.add(const Duration(days: 365)), initialDate: _date);
                  if (d != null) setState(() => _date = d);
                },
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.schedule_rounded, size: 18),
                label: Text('${_two(_time.hour)}:${_two(_time.minute)}'),
                onPressed: () async {
                  final tm = await showTimePicker(context: context, initialTime: _time);
                  if (tm != null) setState(() => _time = tm);
                },
              ),
              DropdownButton<String>(
                value: _tz,
                underline: const SizedBox.shrink(),
                items: [for (final z in _zones) DropdownMenuItem(value: z.$1, child: Text(z.$2))],
                onChanged: (v) => setState(() => _tz = v ?? _tz),
              ),
            ]),
            if (!_sendAtUtc.isAfter(DateTime.now().toUtc()))
              const Padding(padding: EdgeInsets.only(top: 6), child: Text('Waktu kirim harus di masa depan.', style: TextStyle(color: Brand.red, fontSize: 12))),
            const SizedBox(height: 16),
            Text('Pengulangan', style: t.labelLarge),
            const SizedBox(height: 6),
            SegmentedButton<String>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 'none', label: Text('Sekali')),
                ButtonSegment(value: 'daily', label: Text('Harian')),
                ButtonSegment(value: 'weekly', label: Text('Mingguan')),
                ButtonSegment(value: 'monthly', label: Text('Bulanan')),
              ],
              selected: {_freq},
              onSelectionChanged: (v) => setState(() => _freq = v.first),
            ),
            if (_freq == 'weekly') ...[
              const SizedBox(height: 10),
              Wrap(spacing: 6, children: [
                for (var i = 1; i <= 7; i++)
                  FilterChip(label: Text(_dows[i - 1]), selected: _dow.contains(i), onSelected: (v) => setState(() => v ? _dow.add(i) : _dow.remove(i))),
              ]),
            ],
            if (_freq != 'none') ...[
              const SizedBox(height: 10),
              Row(children: [
                Expanded(child: Text(_until == null ? 'Berulang tanpa batas akhir' : 'Berakhir ${fmtDate(_until!.toIso8601String())}', style: t.bodyMedium)),
                TextButton(
                  onPressed: () async {
                    final d = await showDatePicker(context: context, firstDate: _date, lastDate: _date.add(const Duration(days: 730)), initialDate: _until ?? _date.add(const Duration(days: 30)));
                    if (d != null) setState(() => _until = d);
                  },
                  child: Text(_until == null ? 'Atur tanggal akhir' : 'Ubah'),
                ),
                if (_until != null) IconButton(tooltip: 'Hapus batas', icon: const Icon(Icons.close_rounded, size: 18), onPressed: () => setState(() => _until = null)),
              ]),
            ],
            if (widget.isWfrd) ...[
              const SizedBox(height: 12),
              Text('Prioritas (WFRD)', style: t.labelLarge),
              const SizedBox(height: 6),
              SegmentedButton<String>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 'normal', label: Text('Normal')),
                  ButtonSegment(value: 'important', label: Text('Penting')),
                  ButtonSegment(value: 'urgent', label: Text('Urgent')),
                ],
                selected: {_priority},
                onSelectionChanged: (v) => setState(() => _priority = v.first),
              ),
              SwitchListTile(value: _ack, onChanged: (v) => setState(() => _ack = v), title: const Text('Wajib dibaca'), contentPadding: EdgeInsets.zero, dense: true),
            ],
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Batal')),
        FilledButton.icon(
          onPressed: _busy || !_valid ? null : _submit,
          icon: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.schedule_send_rounded),
          label: const Text('Jadwalkan'),
        ),
      ],
    );
  }
}

class _ScheduledListDialog extends ConsumerStatefulWidget {
  const _ScheduledListDialog({required this.channels});
  final List<J> channels;
  @override
  ConsumerState<_ScheduledListDialog> createState() => _ScheduledListDialogState();
}

class _ScheduledListDialogState extends ConsumerState<_ScheduledListDialog> {
  late Future<List<J>> _f = ref.read(apiProvider).rpcList('list_my_scheduled');
  static const _dows = ['Sen', 'Sel', 'Rab', 'Kam', 'Jum', 'Sab', 'Min'];

  String _recur(J r) {
    final time = str(r['recur_time'], '').length >= 5 ? str(r['recur_time']).substring(0, 5) : '';
    final tz = str(r['recur_tz'], '');
    final until = r['recur_until'] == null ? '' : ' · s/d ${fmtDate(r['recur_until'])}';
    return switch (r['recur_freq']) {
      'daily' => 'Setiap hari $time ($tz)$until',
      'weekly' => 'Setiap ${(r['recur_dow'] as List? ?? const []).map((d) => _dows[((d as num).toInt() - 1).clamp(0, 6)]).join(', ')} $time ($tz)$until',
      'monthly' => 'Setiap bulan $time ($tz)$until',
      _ => 'Sekali',
    };
  }

  Future<void> _cancel(J r) async {
    final ok = await showConfirm(context, title: 'Batalkan pesan terjadwal?', message: 'Pesan tidak akan dikirim${r['recur_freq'] != 'none' ? ' dan pengulangan dihentikan' : ''}.', confirmLabel: 'Batalkan jadwal', destructive: true);
    if (!ok || !mounted) return;
    await runAction(context, ref, () => ref.read(apiProvider).rpc('cancel_scheduled', {'p_id': r['id']}), success: 'Jadwal dibatalkan');
    if (mounted) setState(() => _f = ref.read(apiProvider).rpcList('list_my_scheduled'));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Row(children: [Icon(Icons.schedule_send_rounded, color: Brand.blue), SizedBox(width: 10), Text('Pesan terjadwal saya')]),
        content: SizedBox(
          width: 580,
          height: 460,
          child: AsyncView<List<J>>(
            future: _f,
            onRetry: () => setState(() => _f = ref.read(apiProvider).rpcList('list_my_scheduled')),
            builder: (context, rows) {
              if (rows.isEmpty) {
                return const EmptyState(icon: Icons.schedule_rounded, title: 'Tidak ada pesan terjadwal', message: 'Gunakan ikon ⏰ di kolom pesan untuk menjadwalkan atau membuat pesan berulang.');
              }
              return ListView(children: [
                for (final r in rows)
                  Card(
                    margin: const EdgeInsets.only(bottom: 10),
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          _ChannelAvatar(channel: _find(widget.channels, r['channel_id']), size: 26),
                          const SizedBox(width: 8),
                          Expanded(child: Text(_channelName(_find(widget.channels, r['channel_id'])), style: const TextStyle(fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis)),
                          if (r['priority'] != 'normal') StatusBadge(r['priority'] == 'urgent' ? Brand.red : Brand.amber, r['priority'] == 'urgent' ? 'Urgent' : 'Penting'),
                          IconButton(tooltip: 'Batalkan jadwal', icon: const Icon(Icons.cancel_schedule_send_outlined, color: Brand.red), onPressed: () => _cancel(r)),
                        ]),
                        const SizedBox(height: 6),
                        Wrap(spacing: 8, runSpacing: 6, children: [
                          StatusBadge(Brand.blue, fmtDateTime(r['send_at']), icon: Icons.event_rounded),
                          StatusBadge(Brand.purple, _recur(r), icon: Icons.repeat_rounded),
                          if (r['requires_ack'] == true) const StatusBadge(Brand.amber, 'Wajib dibaca', icon: Icons.fact_check_outlined),
                        ]),
                        const SizedBox(height: 8),
                        Text(str(r['body']), maxLines: 4, overflow: TextOverflow.ellipsis),
                      ]),
                    ),
                  ),
              ]);
            },
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Tutup'))],
      );
}

// ═══════════════════════════ Pesan tersimpan ═══════════════════════════
class ChatSavedPage extends ConsumerStatefulWidget {
  const ChatSavedPage({super.key});
  @override
  ConsumerState<ChatSavedPage> createState() => _ChatSavedPageState();
}

class _ChatSavedPageState extends ConsumerState<ChatSavedPage> {
  late Future<(List<J>, List<J>)> _f = _load();
  String _q = '';

  Future<(List<J>, List<J>)> _load() async {
    final api = ref.read(apiProvider);
    final store = ref.read(_chatStoreProvider);
    final res = await Future.wait([api.rpcList('list_saved_messages'), store.channels == null ? api.rpcList('list_my_channels') : Future.value(store.channels!)]);
    store.channels ??= res[1];
    await _ensureCards(ref, [...res[0].map((r) => r['sender_id']), ...res[1].map((c) => c['peer_id'])]);
    return (res[0], res[1]);
  }

  void _reload() => setState(() => _f = _load());

  Future<void> _unsave(J r) async {
    final ok = await runAction(context, ref, () async {
      await ref.read(apiProvider).rpc('save_message', {'p_message': r['id'], 'p_on': false});
      return true;
    }, success: 'Dihapus dari tersimpan');
    if (ok == true && mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    return PageScaffold(
      title: 'Pesan Tersimpan',
      subtitle: 'Pesan yang Anda simpan dari semua percakapan',
      maxWidth: 980,
      leading: IconButton(tooltip: 'Kembali ke chat', icon: const Icon(Icons.arrow_back_rounded), onPressed: () => context.go('/chat')),
      actions: [
        SizedBox(
          width: 260,
          child: TextField(
            onChanged: (v) => setState(() => _q = v.trim().toLowerCase()),
            decoration: const InputDecoration(isDense: true, prefixIcon: Icon(Icons.search_rounded, size: 20), hintText: 'Cari pesan tersimpan'),
          ),
        ),
        IconButton(tooltip: 'Muat ulang', onPressed: _reload, icon: const Icon(Icons.refresh_rounded)),
      ],
      child: AsyncView<(List<J>, List<J>)>(
        future: _f,
        onRetry: _reload,
        builder: (context, data) {
          final (saved, channels) = data;
          final list = saved.where((r) => _q.isEmpty || str(r['body'], '').toLowerCase().contains(_q)).toList();
          if (list.isEmpty) {
            return Card(
              child: EmptyState(
                icon: Icons.bookmark_border_rounded,
                title: saved.isEmpty ? 'Belum ada pesan tersimpan' : 'Tidak ada yang cocok',
                message: saved.isEmpty ? 'Arahkan kursor ke pesan lalu pilih ⋯ → Simpan pesan.' : null,
                action: saved.isEmpty ? FilledButton.tonalIcon(onPressed: () => context.go('/chat'), icon: const Icon(Icons.forum_rounded), label: const Text('Buka chat')) : null,
              ),
            );
          }
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final (i, r) in list.indexed)
              _SavedCard(r: r, channel: _find(channels, r['channel_id']), onUnsave: () => _unsave(r))
                  .animate()
                  .fadeIn(duration: 200.ms, delay: (i.clamp(0, 10) * 25).ms)
                  .slideY(begin: 0.04, end: 0),
          ]);
        },
      ),
    );
  }
}

class _SavedCard extends ConsumerWidget {
  const _SavedCard({required this.r, required this.channel, required this.onUnsave});
  final J r;
  final J? channel;
  final VoidCallback onUnsave;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final store = ref.read(_chatStoreProvider);
    final scheme = Theme.of(context).colorScheme;
    final name = _nameOf(store, r['sender_id']);
    final deleted = r['body'] == null;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 12, 10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          r['sender_id'] == null
              ? const CircleAvatar(radius: 20, backgroundColor: Brand.navy, child: Icon(Icons.smart_toy_rounded, color: Colors.white, size: 20))
              : Avatar(name: name, url: store.cards[r['sender_id']]?['avatar_url'] as String?, radius: 20),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                Text(name, style: const TextStyle(fontWeight: FontWeight.w800)),
                Tooltip(message: fmtDateTime(r['created_at']), child: Text(fmtRelative(r['created_at']), style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant))),
                if (channel != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(color: _typeColor(channel!['type']).withValues(alpha: 0.10), borderRadius: BorderRadius.circular(999)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(_typeIcon(channel!['type']), size: 12, color: _typeColor(channel!['type'])),
                      const SizedBox(width: 4),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 260),
                        child: Text(_channelName(channel), overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: _typeColor(channel!['type']))),
                      ),
                    ]),
                  ),
              ]),
              const SizedBox(height: 8),
              deleted
                  ? Text('Pesan ini sudah dihapus', style: TextStyle(fontStyle: FontStyle.italic, color: scheme.onSurfaceVariant))
                  : _RichBody(text: str(r['body'], '')),
              const SizedBox(height: 6),
              Row(children: [
                Text('Disimpan ${fmtRelative(r['saved_at'])}', style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
                const Spacer(),
                TextButton.icon(onPressed: () => context.go('/chat/${r['channel_id']}'), icon: const Icon(Icons.forum_outlined, size: 18), label: const Text('Buka percakapan')),
                IconButton(tooltip: 'Hapus dari tersimpan', onPressed: onUnsave, icon: const Icon(Icons.bookmark_remove_outlined)),
              ]),
            ]),
          ),
        ]),
      ),
    );
  }
}
