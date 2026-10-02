// lib/features/act_as/act_as_widgets.dart — banner & switcher Act As (addition 2 §B)
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/errors/app_failure.dart';
import '../../core/session/act_as.dart';
import '../../core/session/act_as_controller.dart';
import '../../core/session/contract_classification.dart';
import '../../core/session/failure_handler.dart';
import '../../data/api.dart';
import '../../ui/classification_badges.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

typedef _J = Map<String, dynamic>;

const _actAsGradient = LinearGradient(colors: [Color(0xFFB42318), Color(0xFFF04438), Color(0xFFF79009)]);

/// Banner permanen selama Act As: siapa yang sedang dipakai, sisa waktu, perpanjang, ganti, keluar.
class ActAsBanner extends ConsumerStatefulWidget {
  const ActAsBanner({super.key, required this.realName});
  final String realName;

  @override
  ConsumerState<ActAsBanner> createState() => _ActAsBannerState();
}

class _ActAsBannerState extends ConsumerState<ActAsBanner> {
  Timer? _tick;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _extend() async {
    setState(() => _busy = true);
    await runAction(context, ref, () => ref.read(actAsProvider.notifier).extend(), success: 'Sesi Act As diperpanjang 15 menit');
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _exit() async {
    setState(() => _busy = true);
    await ref.read(actAsProvider.notifier).end();
  }

  @override
  Widget build(BuildContext context) {
    final c = ref.watch(actAsProvider);
    if (c == null) return const SizedBox.shrink();
    final left = c.remaining();
    final urgent = left < const Duration(minutes: 2);
    final narrow = MediaQuery.sizeOf(context).width < 720;
    const white = TextStyle(color: Colors.white);

    final who = Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(c.isUser ? Icons.switch_account_rounded : Icons.badge_rounded, color: Colors.white, size: 18),
      const SizedBox(width: 8),
      const Text('ACT AS', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, letterSpacing: 2, fontSize: 12)),
      const SizedBox(width: 10),
      Flexible(
        child: Text(
          narrow ? c.title : '${c.title} · ${c.subtitle}',
          style: white.copyWith(fontWeight: FontWeight.w700),
          overflow: TextOverflow.ellipsis,
        ),
      ),
    ]);

    final timer = Tooltip(
      message: 'Sesi berakhir otomatis tanpa interaksi. Batas mutlak ${fmtDateTime(c.hardExpiresAt.toIso8601String())}.',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: Colors.black.withValues(alpha: urgent ? 0.35 : 0.18), borderRadius: BorderRadius.circular(999)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.timer_outlined, color: Colors.white, size: 14),
          const SizedBox(width: 4),
          Text(formatCountdown(left), style: white.copyWith(fontFeatures: const [FontFeature.tabularFigures()], fontWeight: FontWeight.w800)),
        ]),
      ),
    );

    final actions = Row(mainAxisSize: MainAxisSize.min, children: [
      if (c.shouldAutoExtend())
        TextButton(
          onPressed: _busy ? null : _extend,
          style: TextButton.styleFrom(foregroundColor: Colors.white, visualDensity: VisualDensity.compact),
          child: const Text('Perpanjang'),
        ),
      if (!narrow)
        TextButton(
          onPressed: _busy ? null : () => showActAsSwitcher(context),
          style: TextButton.styleFrom(foregroundColor: Colors.white, visualDensity: VisualDensity.compact),
          child: const Text('Ganti'),
        ),
      const SizedBox(width: 4),
      FilledButton.icon(
        onPressed: _busy ? null : _exit,
        style: FilledButton.styleFrom(
          backgroundColor: Colors.white,
          foregroundColor: Brand.red,
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 12),
        ),
        icon: const Icon(Icons.logout_rounded, size: 16),
        label: Text(narrow ? 'Keluar' : 'Keluar dari Act As'),
      ),
    ]);

    return Semantics(
      container: true,
      label: 'Mode Act As aktif sebagai ${c.title}',
      child: Container(
        decoration: const BoxDecoration(gradient: _actAsGradient),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: SafeArea(
          bottom: false,
          child: Row(children: [
            Expanded(
              child: Tooltip(
                message: 'Login sebagai ${widget.realName}. Alasan: ${c.reason}\n'
                    'Semua aksi tercatat di audit atas nama Anda. Admin Console & pengaturan pribadi dinonaktifkan.',
                child: who,
              ),
            ),
            const SizedBox(width: 8),
            timer,
            const SizedBox(width: 8),
            actions,
          ]),
        ),
      ),
    );
  }
}

Future<void> showActAsSwitcher(BuildContext context) =>
    showDialog<void>(context: context, builder: (_) => const _ActAsSwitcherDialog());

/// Pilihan target: template role WFRD atau user aktif (bukan admin). Alasan wajib (audit).
class _ActAsSwitcherDialog extends ConsumerStatefulWidget {
  const _ActAsSwitcherDialog();

  @override
  ConsumerState<_ActAsSwitcherDialog> createState() => _ActAsSwitcherDialogState();
}

class _ActAsSwitcherDialogState extends ConsumerState<_ActAsSwitcherDialog> {
  final _reason = TextEditingController();
  final _query = TextEditingController();
  Timer? _debounce;
  _J? _data;
  Object? _error;
  bool _loading = true, _starting = false;
  ({String? userId, String? roleKey, String label})? _pick;

  @override
  void initState() {
    super.initState();
    _reason.addListener(() => setState(() {}));
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _reason.dispose();
    _query.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final q = _query.text.trim();
      final d = await ref.read(apiProvider).rpcMap('act_as_list_targets', {'p_query': q.isEmpty ? null : q, 'p_limit': 100});
      if (mounted) setState(() => (_data = d, _error = null));
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _onQuery(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), _load);
  }

  bool get _canStart => _pick != null && _reason.text.trim().length >= 5 && !_starting;

  Future<void> _start() async {
    final p = _pick;
    if (p == null) return;
    setState(() => _starting = true);
    await runAction(context, ref,
        () => ref.read(actAsProvider.notifier).start(userId: p.userId, roleKey: p.roleKey, reason: _reason.text.trim()));
    if (mounted) setState(() => _starting = false);
  }

  List<_J> _list(String k) => ((_data?[k] as List?) ?? const []).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final roles = _list('roles'), users = _list('users'), recent = _list('recent');
    final contractors = users.where((u) => u['is_wfrd'] != true).toList();
    final wfrd = users.where((u) => u['is_wfrd'] == true).toList();

    Widget tile({required String? userId, required String? roleKey, required String title, String? subtitle,
        required IconData icon, Widget? trailing}) {
      final selected = _pick != null && _pick!.userId == userId && _pick!.roleKey == roleKey;
      return Card(
        margin: const EdgeInsets.only(bottom: 6),
        elevation: 0,
        color: selected ? Brand.red.withValues(alpha: 0.08) : null,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: selected ? Brand.red : Theme.of(context).dividerColor),
        ),
        child: ListTile(
          dense: true,
          leading: Icon(icon, color: selected ? Brand.red : scheme.onSurfaceVariant),
          title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
          subtitle: subtitle == null ? null : Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
          trailing: trailing,
          onTap: () => setState(() => _pick = (userId: userId, roleKey: roleKey, label: title)),
        ),
      );
    }

    Widget userTile(_J u) {
      final lvl = ContractorUserLevel.tryCode(u['level'] as String?);
      final roleNames = ((u['roles'] as List?) ?? const []).join(', ');
      return tile(
        userId: u['id'] as String,
        roleKey: null,
        title: str(u['full_name']),
        subtitle: [str(u['email']), if (u['contractor_name'] != null) str(u['contractor_name']), if (roleNames.isNotEmpty) roleNames].join(' · '),
        icon: u['is_wfrd'] == true ? Icons.engineering_rounded : Icons.apartment_rounded,
        trailing: lvl == null ? null : LevelBadge(lvl),
      );
    }

    return AlertDialog(
      titlePadding: EdgeInsets.zero,
      title: Container(
        decoration: const BoxDecoration(gradient: _actAsGradient, borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
        child: const Row(children: [
          Icon(Icons.switch_account_rounded, color: Colors.white),
          SizedBox(width: 12),
          Expanded(
            child: Text('Act As — lihat & bertindak sebagai', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
          ),
        ]),
      ),
      content: SizedBox(
        width: 640,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const InfoBanner(
            icon: Icons.policy_rounded,
            color: Brand.amber,
            message: 'Aksi dijalankan dengan hak akses target dan tercatat di audit atas nama Anda. Admin Console, '
                'tanda tangan & pengaturan pribadi target dinonaktifkan. Sesi 15 menit (diperpanjang saat aktif, maks. 2 jam).',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _reason,
            maxLength: 500,
            decoration: const InputDecoration(labelText: 'Alasan (wajib, min. 5 karakter)', hintText: 'mis. Uji alur upload dokumen kontraktor', isDense: true),
          ),
          TextField(
            controller: _query,
            onChanged: _onQuery,
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search_rounded), hintText: 'Cari nama, email, perusahaan, atau role', isDense: true),
          ),
          const SizedBox(height: 12),
          Flexible(
            child: _loading && _data == null
                ? const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
                : _error != null
                    ? Text(AppFailure.from(_error!).message, style: const TextStyle(color: Brand.red))
                    : ListView(shrinkWrap: true, children: [
                        if (recent.isNotEmpty) ...[
                          const _Group('Terakhir dipakai'),
                          Wrap(spacing: 8, runSpacing: 8, children: [
                            for (final r in recent)
                              ActionChip(
                                avatar: Icon(r['kind'] == 'role' ? Icons.badge_rounded : Icons.person_rounded, size: 16),
                                label: Text(str(r['kind'] == 'role' ? r['role_name'] : r['target_name'])),
                                onPressed: () => setState(() => _pick = (
                                      userId: r['target_user_id'] as String?,
                                      roleKey: r['role_key'] as String?,
                                      label: str(r['kind'] == 'role' ? r['role_name'] : r['target_name']),
                                    )),
                              ),
                          ]),
                          const SizedBox(height: 12),
                        ],
                        if (roles.isNotEmpty) ...[
                          const _Group('Role WFRD (template, scope global)'),
                          for (final r in roles)
                            tile(
                              userId: null,
                              roleKey: r['key'] as String,
                              title: str(r['name']),
                              subtitle: '${str(r['description'], '')} · ${r['permission_count']} permission'.replaceFirst(RegExp(r'^ · '), ''),
                              icon: Icons.badge_rounded,
                            ),
                        ],
                        if (contractors.isNotEmpty) ...[const _Group('User kontraktor'), for (final u in contractors) userTile(u)],
                        if (wfrd.isNotEmpty) ...[const _Group('User Weatherford'), for (final u in wfrd) userTile(u)],
                        if (roles.isEmpty && users.isEmpty)
                          const Padding(padding: EdgeInsets.all(16), child: Text('Tidak ada target yang cocok.')),
                      ]),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: _starting ? null : () => Navigator.of(context).pop(), child: const Text('Batal')),
        FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: Brand.red),
          onPressed: _canStart ? _start : null,
          icon: _starting
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.play_arrow_rounded),
          label: Text(_pick == null ? 'Pilih target' : 'Act As ${_pick!.label}', overflow: TextOverflow.ellipsis),
        ),
      ],
    );
  }
}

class _Group extends StatelessWidget {
  const _Group(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 6),
        child: Text(text.toUpperCase(),
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1.2, color: Theme.of(context).colorScheme.onSurfaceVariant)),
      );
}
