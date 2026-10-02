import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../app.dart';
import '../../core/router/route_rules.dart';
import '../../core/security/fingerprint.dart';
import '../../core/session/act_as_controller.dart';
import '../../core/session/failure_handler.dart';
import '../../core/session/session_controller.dart';
import '../../core/session/session_state.dart';
import '../../data/api.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../act_as/act_as_widgets.dart';

class NavItem {
  const NavItem(this.path, this.label, this.icon, {this.match});
  final String path;
  final String label;
  final IconData icon;
  final String? match;
}

List<NavItem> navItemsFor(SessionState s) {
  final all = <NavItem>[
    const NavItem('/dashboard', 'Dashboard', Icons.space_dashboard_rounded),
    const NavItem('/tasks', 'Tasks', Icons.task_alt_rounded),
    const NavItem('/tasks/review', 'Antrian Review', Icons.fact_check_rounded),
    const NavItem('/tasks/tracking', 'Tracking', Icons.timeline_rounded),
    const NavItem('/contracts', 'Kontrak', Icons.handshake_rounded),
    if (s.isContractor) const NavItem('/my-company', 'Perusahaan Saya', Icons.apartment_rounded),
    const NavItem('/vendors', 'Vendor', Icons.storefront_rounded),
    const NavItem('/incidents', 'Insiden', Icons.report_gmailerrorred_rounded),
    const NavItem('/kpi', 'KPI', Icons.insights_rounded),
    const NavItem('/chat', 'Chat', Icons.forum_rounded),
    const NavItem('/admin', 'Admin Console', Icons.admin_panel_settings_rounded),
    const NavItem('/settings/profile', 'Pengaturan', Icons.settings_rounded, match: '/settings'),
  ];
  return all.where((i) {
    final r = RouteRules.match(i.path);
    return r == null || r.allows(s);
  }).toList();
}

final unreadNotificationsProvider = StateProvider<int>((_) => 0);

class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  StreamSubscription<String>? _sub;
  StreamSubscription<Map<String, dynamic>>? _chatSub;
  int _chatUnread = 0;

  @override
  void initState() {
    super.initState();
    _sub = ref.read(notificationBus).stream.listen((_) => _refreshCounts());
    _chatSub = ref.read(chatBus).stream.listen((_) => _refreshChat());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final s = ref.read(sessionProvider);
      if (s is SessionReady) ref.read(unreadNotificationsProvider.notifier).state = s.s.unread;
      _refreshChat();
      final flash = takeActAsFlash();
      if (flash != null && mounted) showSnack(context, flash);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _chatSub?.cancel();
    super.dispose();
  }

  Future<void> _refreshCounts() async {
    try {
      final rows = await ref.read(apiProvider).select('notifications', 'id', build: (q) => q.isFilter('read_at', null).limit(100));
      if (mounted) ref.read(unreadNotificationsProvider.notifier).state = rows.length;
    } catch (_) {}
  }

  Future<void> _refreshChat() async {
    final s = ref.read(sessionProvider);
    if (s is! SessionReady || !s.s.can('chat.use')) return;
    try {
      final ch = await ref.read(apiProvider).rpcList('list_my_channels');
      final n = ch.fold<int>(0, (a, c) => a + ((c['unread'] as num?)?.toInt() ?? 0));
      if (mounted) setState(() => _chatUnread = n);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(sessionProvider);
    if (status is! SessionReady) return const Scaffold(body: LoadingView());
    final s = status.s;
    final items = navItemsFor(s);
    final path = GoRouterState.of(context).uri.path;
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final selected = _selectedIndex(items, path);

    final column = Column(children: [
      if (s.isActingAs) ActAsBanner(realName: s.realFullName ?? s.realEmail),
      if (s.adminMode && !s.isActingAs) const _AdminBanner(),
      if (s.readOnly) const _ReadOnlyBanner(),
      _TopBar(session: s, chatUnread: _chatUnread, showMenu: !wide),
      Expanded(child: widget.child),
    ]);
    // R38: sesi Act As hanya diperpanjang bila ada interaksi nyata
    final content = s.isActingAs
        ? Listener(behavior: HitTestBehavior.translucent, onPointerDown: (_) => ref.read(actAsProvider.notifier).touch(), child: column)
        : column;

    if (wide) {
      return Scaffold(
        body: Row(children: [
          _Sidebar(items: items, selected: selected, session: s, chatUnread: _chatUnread),
          Expanded(child: content),
        ]),
      );
    }
    final bottom = items.where((i) => const {'/dashboard', '/tasks', '/contracts', '/chat', '/settings/profile'}.contains(i.path)).toList();
    final bIndex = bottom.indexWhere((i) => i.path == (selected >= 0 ? items[selected].path : ''));
    return Scaffold(
      drawer: Drawer(child: _Sidebar(items: items, selected: selected, session: s, chatUnread: _chatUnread, inDrawer: true)),
      body: content,
      bottomNavigationBar: bottom.length < 2
          ? null
          : NavigationBar(
              selectedIndex: bIndex < 0 ? 0 : bIndex,
              onDestinationSelected: (i) => context.go(bottom[i].path),
              destinations: [for (final i in bottom) NavigationDestination(icon: Icon(i.icon), label: i.label)],
            ),
    );
  }

  int _selectedIndex(List<NavItem> items, String path) {
    var best = -1, bestLen = -1;
    for (var i = 0; i < items.length; i++) {
      final m = items[i].match ?? items[i].path;
      if ((path == m || path.startsWith('$m/')) && m.length > bestLen) {
        best = i;
        bestLen = m.length;
      }
    }
    return best;
  }
}

class _Sidebar extends ConsumerWidget {
  const _Sidebar({required this.items, required this.selected, required this.session, required this.chatUnread, this.inDrawer = false});
  final List<NavItem> items;
  final int selected;
  final SessionState session;
  final int chatUnread;
  final bool inDrawer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      width: 264,
      decoration: const BoxDecoration(gradient: Brand.sidebarGradient),
      child: SafeArea(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
            child: Row(children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(gradient: Brand.heroGradient, borderRadius: BorderRadius.circular(12)),
                child: const Icon(Icons.shield_moon_rounded, color: Colors.white),
              ),
              const SizedBox(width: 12),
              const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('COMEN', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 20, letterSpacing: 1.2)),
                Text('Contractor Management', style: TextStyle(color: Colors.white60, fontSize: 11)),
              ]),
            ]),
          ),
          if (session.contractorName != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(10)),
                child: Row(children: [
                  const Icon(Icons.apartment_rounded, size: 16, color: Colors.white70),
                  const SizedBox(width: 8),
                  Expanded(child: Text(session.contractorName!, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis)),
                ]),
              ),
            ),
          Expanded(
            child: ListView(padding: const EdgeInsets.symmetric(horizontal: 12), children: [
              for (var i = 0; i < items.length; i++)
                _NavTile(
                  item: items[i],
                  selected: i == selected,
                  badge: items[i].path == '/chat' ? chatUnread : 0,
                  onTap: () {
                    if (inDrawer) Navigator.of(context).pop();
                    context.go(items[i].path);
                  },
                ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(children: [
              Avatar(name: session.fullName ?? session.email, url: session.avatarUrl),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(session.fullName ?? session.email, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis),
                  Text(
                    session.isRootAdmin ? 'Root Admin' : (session.roles.isNotEmpty ? '${session.roles.first['name']}' : session.email),
                    style: const TextStyle(color: Colors.white60, fontSize: 11),
                    overflow: TextOverflow.ellipsis,
                  ),
                ]),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _NavTile extends StatelessWidget {
  const _NavTile({required this.item, required this.selected, required this.onTap, this.badge = 0});
  final NavItem item;
  final bool selected;
  final VoidCallback onTap;
  final int badge;

  @override
  Widget build(BuildContext context) {
    final isAdmin = item.path == '/admin';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: selected ? Colors.white.withValues(alpha: 0.12) : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            child: Row(children: [
              Icon(item.icon, size: 20, color: selected ? Colors.white : (isAdmin ? const Color(0xFFFDA29B) : Colors.white70)),
              const SizedBox(width: 12),
              Expanded(
                child: Text(item.label,
                    style: TextStyle(color: selected ? Colors.white : Colors.white70, fontWeight: selected ? FontWeight.w700 : FontWeight.w500)),
              ),
              if (badge > 0)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(color: Brand.red, borderRadius: BorderRadius.circular(999)),
                  child: Text(badge > 99 ? '99+' : '$badge', style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
                ),
              if (selected) Container(width: 4, height: 18, margin: const EdgeInsets.only(left: 6), decoration: BoxDecoration(color: Brand.cyan, borderRadius: BorderRadius.circular(4))),
            ]),
          ),
        ),
      ),
    );
  }
}

class _TopBar extends ConsumerStatefulWidget {
  const _TopBar({required this.session, required this.chatUnread, required this.showMenu});
  final SessionState session;
  final int chatUnread;
  final bool showMenu;

  @override
  ConsumerState<_TopBar> createState() => _TopBarState();
}

class _TopBarState extends ConsumerState<_TopBar> {
  final _search = TextEditingController();

  Future<void> _go(String raw) async {
    final q = raw.trim().toUpperCase();
    if (q.isEmpty) return;
    if (taskIdRe.hasMatch(q)) {
      try {
        final rows = await ref.read(apiProvider).select('v_task_tracking', 'id,task_id', build: (b) => b.eq('task_id', q).limit(1));
        if (!mounted) return;
        if (rows.isEmpty) {
          showSnack(context, 'Task $q tidak ditemukan atau Anda tidak berhak melihatnya', error: true);
        } else {
          context.go('/tasks/${rows.first['id']}');
        }
      } catch (e) {
        if (mounted) await handleFailure(context, ref, e);
      }
      return;
    }
    if (RegExp(r'^CTR-').hasMatch(q) || RegExp(r'^\d{4}-\d{5}$').hasMatch(q)) {
      try {
        final rows = await ref.read(apiProvider).select('contracts', 'id,contract_no', build: (b) => b.ilike('contract_no', '%$q%').limit(1));
        if (mounted && rows.isNotEmpty) context.go('/contracts/${rows.first['id']}');
        if (mounted && rows.isEmpty) showSnack(context, 'Kontrak tidak ditemukan', error: true);
      } catch (e) {
        if (mounted) await handleFailure(context, ref, e);
      }
      return;
    }
    if (mounted) context.go('/tasks?q=${Uri.encodeComponent(raw.trim())}');
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.session;
    final unread = ref.watch(unreadNotificationsProvider);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 68,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(color: scheme.surface, border: Border(bottom: BorderSide(color: Theme.of(context).dividerColor))),
      child: Row(children: [
        if (widget.showMenu) Builder(builder: (c) => IconButton(icon: const Icon(Icons.menu_rounded), onPressed: () => Scaffold.of(c).openDrawer())),
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: TextField(
                controller: _search,
                onSubmitted: _go,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search_rounded),
                  hintText: 'Cari Task ID (CMN-…) / nomor kontrak',
                  isDense: true,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        IconButton(
          tooltip: 'Notifikasi',
          onPressed: () => context.go('/notifications'),
          icon: Badge(isLabelVisible: unread > 0, label: Text('$unread'), child: const Icon(Icons.notifications_none_rounded)),
        ),
        if (s.can('chat.use'))
          IconButton(
            tooltip: 'Chat',
            onPressed: () => context.go('/chat'),
            icon: Badge(isLabelVisible: widget.chatUnread > 0, label: Text('${widget.chatUnread}'), child: const Icon(Icons.chat_bubble_outline_rounded)),
          ),
        if (s.canActAs && s.aal == 'aal2')
          IconButton(
            tooltip: s.isActingAs ? 'Ganti target Act As' : 'Act As (lihat & bertindak sebagai user/role lain)',
            onPressed: () => showActAsSwitcher(context),
            icon: Icon(Icons.switch_account_rounded, color: s.isActingAs ? Brand.red : null),
          ),
        PopupMenuButton<String>(
          tooltip: 'Akun',
          offset: const Offset(0, 48),
          onSelected: (v) {
            switch (v) {
              case 'theme':
                final m = ref.read(themeModeProvider);
                ref.read(themeModeProvider.notifier).state = m == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
              case 'act_as_exit':
                ref.read(actAsProvider.notifier).end();
              default:
                context.go(v);
            }
          },
          itemBuilder: (_) => [
            PopupMenuItem(
              enabled: false,
              child: Text(s.isActingAs ? '${s.email}\nlogin sebagai ${s.realEmail}' : s.email, style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
            const PopupMenuDivider(),
            if (s.isActingAs)
              const PopupMenuItem(value: 'act_as_exit', child: ListTile(leading: Icon(Icons.logout_rounded, color: Brand.red), title: Text('Keluar dari Act As'), dense: true))
            else ...[
              const PopupMenuItem(value: '/settings/profile', child: ListTile(leading: Icon(Icons.person_outline), title: Text('Profil'), dense: true)),
              const PopupMenuItem(value: '/settings/devices', child: ListTile(leading: Icon(Icons.devices_rounded), title: Text('Perangkat Saya'), dense: true)),
              const PopupMenuItem(value: '/settings/security', child: ListTile(leading: Icon(Icons.verified_user_outlined), title: Text('Keamanan & MFA'), dense: true)),
            ],
            const PopupMenuItem(value: 'theme', child: ListTile(leading: Icon(Icons.dark_mode_outlined), title: Text('Mode gelap / terang'), dense: true)),
          ],
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: Avatar(name: s.fullName ?? s.email, url: s.avatarUrl)),
        ),
      ]),
    );
  }
}

class _AdminBanner extends StatelessWidget {
  const _AdminBanner();
  @override
  Widget build(BuildContext context) => Container(
        height: 26,
        decoration: const BoxDecoration(gradient: Brand.adminGradient),
        alignment: Alignment.center,
        child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.admin_panel_settings_rounded, size: 14, color: Colors.white),
          SizedBox(width: 6),
          Text('ADMIN MODE', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 11, letterSpacing: 3)),
        ]),
      ).animate(onPlay: (c) => c.repeat(reverse: true)).shimmer(duration: 3.seconds, color: Colors.white24);
}

class _ReadOnlyBanner extends StatelessWidget {
  const _ReadOnlyBanner();
  @override
  Widget build(BuildContext context) => Container(
        height: 30,
        color: Brand.amber,
        alignment: Alignment.center,
        child: const Text('SISTEM READ-ONLY — perubahan data dinonaktifkan sementara oleh Admin',
            style: TextStyle(color: Colors.black87, fontWeight: FontWeight.w800, fontSize: 12)),
      );
}
