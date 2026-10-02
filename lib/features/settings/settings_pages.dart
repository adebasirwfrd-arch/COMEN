import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:web/web.dart' as web;
import '../../core/env.dart';
import '../../core/errors/app_failure.dart';
import '../../core/router/route_rules.dart';
import '../../core/session/failure_handler.dart';
import '../../core/session/session_controller.dart';
import '../../core/session/session_state.dart';
import '../../data/api.dart';
import '../../data/columns.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../auth/auth_gateway.dart';
import '../auth/step_up_dialog.dart';

typedef J = Map<String, dynamic>;

SessionState? _session(WidgetRef ref) {
  final st = ref.watch(sessionProvider);
  return st is SessionReady ? st.s : null;
}

// ═══════════════════════════ Navigasi pengaturan ═══════════════════════════
class _SettingsNav extends ConsumerWidget {
  const _SettingsNav(this.current);
  final String current;

  static const _items = [
    ('/settings/profile', 'Profil', Icons.person_outline_rounded),
    ('/settings/devices', 'Perangkat', Icons.devices_rounded),
    ('/settings/security', 'Keamanan & MFA', Icons.verified_user_outlined),
    ('/settings/notifications', 'Notifikasi', Icons.notifications_none_rounded),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = _session(ref);
    final items = _items.where((i) => s != null && (RouteRules.match(i.$1)?.allows(s) ?? false)).toList();
    if (items.length < 2) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          for (final (path, label, icon) in items)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                avatar: Icon(icon, size: 18),
                label: Text(label),
                selected: path == current,
                showCheckmark: false,
                onSelected: (_) => path == current ? null : context.go(path),
              ),
            ),
        ]),
      ),
    );
  }
}

// ═══════════════════════════ Profil ═══════════════════════════
class ProfilePage extends ConsumerStatefulWidget {
  const ProfilePage({super.key});
  @override
  ConsumerState<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends ConsumerState<ProfilePage> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _job = TextEditingController();
  final _phone = TextEditingController();
  String _locale = 'id';
  J? _profile;
  Object? _error;
  bool _busy = false, _dirty = false;

  static final _phoneRe = RegExp(r'^\+?[0-9 ()-]{6,20}$');

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    _job.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final p = await ref.read(apiProvider).rpcMap('get_my_profile');
      if (!mounted) return;
      _name.text = str(p['full_name'], '');
      _job.text = str(p['job_title'], '');
      _phone.text = str(p['phone'], '');
      setState(() {
        _locale = (p['locale'] as String?) ?? 'id';
        _profile = p;
        _dirty = false;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  String? _opt(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();

  Future<void> _save() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    setState(() => _busy = true);
    final ok = await runAction(
      context,
      ref,
      () async {
        await ref.read(apiProvider).rpc('update_my_profile', {
          'p_full_name': _name.text.trim(),
          'p_job_title': _opt(_job),
          'p_phone': _opt(_phone),
          'p_locale': _locale,
        });
        return true;
      },
      success: 'Profil disimpan',
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok == true) {
      await ref.read(sessionProvider.notifier).refresh();
      await _load();
    }
  }

  void _touch() {
    if (!_dirty) setState(() => _dirty = true);
  }

  @override
  Widget build(BuildContext context) {
    final s = _session(ref);
    return PageScaffold(
      title: 'Pengaturan',
      subtitle: 'Profil, perangkat, keamanan, dan notifikasi akun Anda',
      maxWidth: 980,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const _SettingsNav('/settings/profile'),
        if (_profile == null && _error != null)
          ErrorView(_error!, onRetry: _load)
        else if (_profile == null)
          const LoadingView()
        else ...[
          _ProfileHeader(profile: _profile!, session: s),
          const SizedBox(height: 16),
          SectionCard(
            title: 'Data diri',
            subtitle: 'Nama & jabatan terlihat oleh rekan di chat dan task. Nomor telepon disimpan terenkripsi.',
            icon: Icons.badge_outlined,
            child: Form(
              key: _form,
              onChanged: _touch,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                ResponsiveGrid(minItemWidth: 300, spacing: 16, children: [
                  TextFormField(
                    controller: _name,
                    maxLength: 120,
                    decoration: const InputDecoration(labelText: 'Nama lengkap *', prefixIcon: Icon(Icons.person_outline_rounded)),
                    validator: (v) => (v == null || v.trim().isEmpty) ? 'Nama wajib diisi' : null,
                  ),
                  TextFormField(
                    controller: _job,
                    maxLength: 120,
                    decoration: const InputDecoration(labelText: 'Jabatan', prefixIcon: Icon(Icons.work_outline_rounded)),
                  ),
                  TextFormField(
                    controller: _phone,
                    maxLength: 20,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(labelText: 'Telepon', hintText: '+62 812 3456 7890', prefixIcon: Icon(Icons.phone_outlined)),
                    validator: (v) => (v == null || v.trim().isEmpty || _phoneRe.hasMatch(v.trim())) ? null : 'Format: +62… (6–20 digit, spasi/()/- boleh)',
                  ),
                  InputDecorator(
                    decoration: const InputDecoration(labelText: 'Email (login)', prefixIcon: Icon(Icons.alternate_email_rounded)),
                    child: Text(str(_profile!['email']), overflow: TextOverflow.ellipsis),
                  ),
                ]),
                const SizedBox(height: 16),
                Text('Bahasa antarmuka', style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'id', label: Text('Bahasa Indonesia')),
                      ButtonSegment(value: 'en', label: Text('English')),
                    ],
                    selected: {_locale},
                    onSelectionChanged: (v) => setState(() {
                      _locale = v.first;
                      _dirty = true;
                    }),
                  ),
                ),
                const SizedBox(height: 20),
                Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                  TextButton(onPressed: _busy || !_dirty ? null : _load, child: const Text('Batalkan perubahan')),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _busy || !_dirty ? null : _save,
                    icon: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.save_rounded),
                    label: const Text('Simpan profil'),
                  ),
                ]),
              ]),
            ),
          ),
        ],
      ]),
    );
  }
}

class _ProfileHeader extends StatelessWidget {
  const _ProfileHeader({required this.profile, required this.session});
  final J profile;
  final SessionState? session;

  @override
  Widget build(BuildContext context) {
    final s = session;
    final name = str(profile['full_name'], s?.email ?? '-');
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(gradient: Brand.heroGradient, borderRadius: BorderRadius.circular(20)),
      child: Row(children: [
        Container(
          padding: const EdgeInsets.all(3),
          decoration: const BoxDecoration(color: Colors.white24, shape: BoxShape.circle),
          child: Avatar(name: name, url: profile['avatar_url'] as String?, radius: 34),
        ),
        const SizedBox(width: 20),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name, style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800), overflow: TextOverflow.ellipsis),
            const SizedBox(height: 2),
            Text([if (profile['job_title'] != null) profile['job_title'], s?.contractorName ?? (s?.isWfrd == true ? 'Weatherford' : null)].whereType<Object>().join(' · '),
                style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 6, children: [
              if (s != null) _GlassChip(icon: Icons.verified_rounded, label: StatusStyle.account(s.status).$2),
              if (s?.isRootAdmin == true) const _GlassChip(icon: Icons.shield_rounded, label: 'Root Admin'),
              for (final r in (s?.roles ?? const <J>[]).take(4)) _GlassChip(icon: Icons.workspace_premium_outlined, label: str(r['name'])),
              if (s != null) _GlassChip(icon: Icons.lock_outline_rounded, label: s.aal == 'aal2' ? 'MFA terverifikasi' : 'Sesi AAL1'),
            ]),
          ]),
        ),
      ]),
    );
  }
}

class _GlassChip extends StatelessWidget {
  const _GlassChip({required this.icon, required this.label});
  final IconData icon;
  final String label;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(999), border: Border.all(color: Colors.white24)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 13, color: Colors.white),
          const SizedBox(width: 5),
          Text(label, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
        ]),
      );
}

// ═══════════════════════════ Perangkat (17.7) ═══════════════════════════
class DevicesPage extends ConsumerStatefulWidget {
  const DevicesPage({super.key});
  @override
  ConsumerState<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends ConsumerState<DevicesPage> {
  Future<List<J>>? _future;

  @override
  void initState() {
    super.initState();
    final st = ref.read(sessionProvider);
    // list_my_devices memakai assert_session → hanya akun aktif
    if (st is SessionReady && st.s.status == 'active') _future = _load();
  }

  Future<List<J>> _load() => ref.read(apiProvider).rpcList('list_my_devices');
  void _reload() => setState(() => _future = _load());

  Future<void> _rename(J d) async {
    final ctl = TextEditingController(text: str(d['label'], ''));
    final label = await showDialog<String>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: const Text('Ganti nama perangkat'),
          content: SizedBox(
            width: 420,
            child: TextField(
              controller: ctl,
              autofocus: true,
              maxLength: 80,
              onChanged: (_) => set(() {}),
              onSubmitted: (v) => v.trim().isEmpty ? null : Navigator.pop(c, v.trim()),
              decoration: const InputDecoration(labelText: 'Nama perangkat', hintText: 'mis. Laptop kantor'),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c), child: const Text('Batal')),
            FilledButton(onPressed: ctl.text.trim().isEmpty ? null : () => Navigator.pop(c, ctl.text.trim()), child: const Text('Simpan')),
          ],
        ),
      ),
    );
    if (label == null || !mounted) return;
    await runAction(context, ref, () => ref.read(apiProvider).rpc('rename_my_device', {'p_device': d['id'], 'p_label': label}), success: 'Nama perangkat diperbarui');
    if (mounted) _reload();
  }

  Future<void> _revoke(J d) async {
    final ok = await showConfirm(
      context,
      title: 'Cabut perangkat?',
      message: '"${str(d['label'], 'Perangkat')}" akan langsung keluar dan harus login ulang dengan identitas perangkat baru. Langganan push di perangkat tersebut juga dihapus.',
      confirmLabel: 'Cabut',
      destructive: true,
    );
    if (!ok || !mounted) return;
    await runAction(context, ref, () => ref.read(apiProvider).rpc('revoke_my_device', {'p_device': d['id']}), success: 'Perangkat dicabut');
    if (mounted) _reload();
  }

  Future<void> _signOutHere() async {
    final ok = await showConfirm(context, title: 'Keluar dari perangkat ini?', message: 'Sesi di browser ini diakhiri. Perangkat tetap terdaftar sebagai tepercaya.', confirmLabel: 'Keluar');
    if (ok) await ref.read(sessionProvider.notifier).signOutLocal();
  }

  @override
  Widget build(BuildContext context) {
    final s = _session(ref);
    final wide = MediaQuery.sizeOf(context).width >= 900;
    return PageScaffold(
      title: 'Perangkat Saya',
      subtitle: 'Browser tepercaya yang pernah dipakai login ke akun Anda',
      maxWidth: 1100,
      actions: [
        if (_future != null) IconButton(tooltip: 'Muat ulang', onPressed: _reload, icon: const Icon(Icons.refresh_rounded)),
        OutlinedButton.icon(onPressed: _signOutHere, icon: const Icon(Icons.logout_rounded), label: const Text('Keluar dari perangkat ini')),
      ],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const _SettingsNav('/settings/devices'),
        if (_future == null)
          InfoBanner(
            message: s?.status == 'pending'
                ? 'Akun Anda masih menunggu persetujuan. Daftar perangkat tersedia setelah akun aktif — Anda tetap bisa keluar dari perangkat ini.'
                : 'Daftar perangkat hanya tersedia untuk akun aktif.',
            icon: Icons.hourglass_top_rounded,
            color: Brand.amber,
          )
        else ...[
          const InfoBanner(
            message: 'Cabut perangkat yang tidak Anda kenali. Login dari perangkat baru selalu dicatat & diberitahukan.',
            icon: Icons.shield_outlined,
          ),
          const SizedBox(height: 16),
          AsyncView<List<J>>(
            future: _future!,
            onRetry: _reload,
            builder: (context, rows) {
              if (rows.isEmpty) return const Card(child: EmptyState(icon: Icons.devices_other_rounded, title: 'Belum ada perangkat terdaftar'));
              return wide ? _deviceTable(rows) : Column(children: [for (final d in rows) _DeviceCard(d: d, onRename: () => _rename(d), onRevoke: () => _revoke(d), onSignOut: _signOutHere)]);
            },
          ),
        ],
      ]),
    );
  }

  Widget _deviceTable(List<J> rows) => Card(
        clipBehavior: Clip.antiAlias,
        child: DataList(
          columns: const ['Perangkat', 'Pertama terlihat', 'Terakhir aktif', 'Push', 'Status', ''],
          rows: [
            for (final d in rows)
              [
                _DeviceLabel(d: d),
                Text(fmtDateTime(d['first_seen'])),
                Tooltip(message: fmtDateTime(d['last_seen']), child: Text(fmtRelative(d['last_seen']))),
                _PushBadge(on: d['push_enabled'] == true),
                _DeviceStatus(d: d),
                _DeviceActions(d: d, onRename: () => _rename(d), onRevoke: () => _revoke(d), onSignOut: _signOutHere),
              ],
          ],
        ),
      );
}

class _DeviceLabel extends StatelessWidget {
  const _DeviceLabel({required this.d});
  final J d;
  @override
  Widget build(BuildContext context) {
    final label = str(d['label'], 'Perangkat tanpa nama');
    final current = d['is_current'] == true;
    final l = label.toLowerCase();
    final icon = l.contains('android') || l.contains('ios') ? Icons.smartphone_rounded : (l.contains('mac') || l.contains('windows') || l.contains('linux') ? Icons.laptop_mac_rounded : Icons.devices_rounded);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(color: (current ? Brand.green : Brand.blue).withValues(alpha: 0.1), borderRadius: BorderRadius.circular(10)),
        child: Icon(icon, size: 18, color: current ? Brand.green : Brand.blue),
      ),
      const SizedBox(width: 10),
      Flexible(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis),
          if (current)
            const Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.star_rounded, size: 14, color: Brand.amber),
              SizedBox(width: 3),
              Text('Perangkat ini', style: TextStyle(fontSize: 12, color: Brand.amber, fontWeight: FontWeight.w700)),
            ]),
        ]),
      ),
    ]);
  }
}

class _PushBadge extends StatelessWidget {
  const _PushBadge({required this.on});
  final bool on;
  @override
  Widget build(BuildContext context) =>
      on ? const StatusBadge(Brand.cyan, 'Aktif', icon: Icons.notifications_active_rounded) : const StatusBadge(Brand.grey, 'Mati', icon: Icons.notifications_off_outlined);
}

class _DeviceStatus extends StatelessWidget {
  const _DeviceStatus({required this.d});
  final J d;
  @override
  Widget build(BuildContext context) {
    if (d['revoked_at'] == null) return const StatusBadge(Brand.green, 'Tepercaya');
    return Tooltip(
      message: '${str(d['revoke_reason'], 'Dicabut')} · ${fmtDateTime(d['revoked_at'])}',
      child: const StatusBadge(Brand.red, 'Dicabut', icon: Icons.block_rounded),
    );
  }
}

class _DeviceActions extends StatelessWidget {
  const _DeviceActions({required this.d, required this.onRename, required this.onRevoke, required this.onSignOut});
  final J d;
  final VoidCallback onRename, onRevoke, onSignOut;
  @override
  Widget build(BuildContext context) {
    final revoked = d['revoked_at'] != null;
    final current = d['is_current'] == true;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      if (!revoked) TextButton.icon(onPressed: onRename, icon: const Icon(Icons.edit_outlined, size: 16), label: const Text('Ganti nama')),
      if (!revoked && !current)
        TextButton.icon(
          onPressed: onRevoke,
          style: TextButton.styleFrom(foregroundColor: Brand.red),
          icon: const Icon(Icons.block_rounded, size: 16),
          label: const Text('Cabut'),
        ),
      if (current) TextButton.icon(onPressed: onSignOut, icon: const Icon(Icons.logout_rounded, size: 16), label: const Text('Keluar')),
    ]);
  }
}

class _DeviceCard extends StatelessWidget {
  const _DeviceCard({required this.d, required this.onRename, required this.onRevoke, required this.onSignOut});
  final J d;
  final VoidCallback onRename, onRevoke, onSignOut;
  @override
  Widget build(BuildContext context) => Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [Expanded(child: _DeviceLabel(d: d)), _DeviceStatus(d: d)]),
            const SizedBox(height: 12),
            KeyValueGrid(minItemWidth: 140, [
              ('Pertama', Text(fmtDate(d['first_seen']))),
              ('Terakhir', Text(fmtRelative(d['last_seen']))),
              ('Push', _PushBadge(on: d['push_enabled'] == true)),
            ]),
            const SizedBox(height: 4),
            Align(alignment: Alignment.centerRight, child: _DeviceActions(d: d, onRename: onRename, onRevoke: onRevoke, onSignOut: onSignOut)),
          ]),
        ),
      );
}

// ═══════════════════════════ Keamanan & MFA ═══════════════════════════
class SecurityPage extends ConsumerStatefulWidget {
  const SecurityPage({super.key});
  @override
  ConsumerState<SecurityPage> createState() => _SecurityPageState();
}

class _SecurityData {
  _SecurityData(this.factors, this.profile);
  final List<Factor> factors;
  final J? profile;
}

class _SecurityPageState extends ConsumerState<SecurityPage> {
  late Future<_SecurityData> _future = _load();

  GoTrueMFAApi get _mfa => Supabase.instance.client.auth.mfa;

  Future<_SecurityData> _load() async {
    final api = ref.read(apiProvider);
    final res = await Future.wait<Object?>([
      guard(() => _mfa.listFactors()),
      api.uid == null ? Future<J?>.value() : api.selectOne('profiles', Cols.profiles, 'id', api.uid!).catchError((_) => null),
    ]);
    final f = res[0] as AuthMFAListFactorsResponse;
    return _SecurityData(f.totp, res[1] as J?);
  }

  void _reload() => setState(() => _future = _load());

  /// Perubahan faktor yang sudah terverifikasi butuh sesi aal2 → minta kode TOTP (step-up) bila belum.
  Future<bool> _ensureAal2() async {
    final st = ref.read(sessionProvider);
    if (st is SessionReady && st.s.aal == 'aal2') return true;
    final ok = await showDialog<bool>(context: context, builder: (_) => const StepUpDialog());
    if (ok != true) return false;
    await ref.read(sessionProvider.notifier).refresh();
    return true;
  }

  Future<void> _add(List<Factor> factors) async {
    if (factors.any((f) => f.status == FactorStatus.verified) && !await _ensureAal2()) return;
    if (!mounted) return;
    final ok = await showDialog<bool>(context: context, barrierDismissible: false, builder: (_) => _EnrollDialog(existing: factors.length));
    if (ok == true && mounted) {
      showSnack(context, 'Authenticator ditambahkan');
      await ref.read(sessionProvider.notifier).refresh();
      _reload();
    }
  }

  Future<void> _remove(Factor f) async {
    final ok = await showConfirm(
      context,
      title: 'Hapus authenticator?',
      message: '"${f.friendlyName ?? 'Authenticator'}" tidak bisa lagi dipakai untuk verifikasi. Pastikan Anda masih punya authenticator lain.',
      confirmLabel: 'Hapus',
      destructive: true,
    );
    if (!ok || !mounted) return;
    if (f.status == FactorStatus.verified && !await _ensureAal2()) return;
    if (!mounted) return;
    final r = await runAction(context, ref, () => guard(() => _mfa.unenroll(f.id)), success: 'Authenticator dihapus');
    if (r != null && mounted) {
      await ref.read(sessionProvider.notifier).refresh();
      _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _session(ref);
    return PageScaffold(
      title: 'Keamanan & MFA',
      subtitle: 'Autentikasi dua langkah (TOTP) dan status sesi Anda',
      maxWidth: 1100,
      actions: [IconButton(tooltip: 'Muat ulang', onPressed: _reload, icon: const Icon(Icons.refresh_rounded))],
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const _SettingsNav('/settings/security'),
        AsyncView<_SecurityData>(
          future: _future,
          onRetry: _reload,
          builder: (context, d) {
            final verified = d.factors.where((f) => f.status == FactorStatus.verified).toList();
            final mfaCard = _mfaCard(s, d.factors, verified);
            final sessionCard = _sessionCard(s, d.profile, verified.length);
            return LayoutBuilder(
              builder: (context, c) => c.maxWidth >= 900
                  ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(flex: 3, child: mfaCard), const SizedBox(width: 16), Expanded(flex: 2, child: sessionCard)])
                  : Column(children: [mfaCard, const SizedBox(height: 16), sessionCard]),
            );
          },
        ),
      ]),
    );
  }

  Widget _mfaCard(SessionState? s, List<Factor> all, List<Factor> verified) {
    final lastLocked = (s?.mfaRequired ?? false) && verified.length <= 1;
    return SectionCard(
      title: 'Authenticator (TOTP)',
      subtitle: 'Google Authenticator, Microsoft Authenticator, 1Password, dll.',
      icon: Icons.phonelink_lock_rounded,
      trailing: FilledButton.tonalIcon(
        onPressed: all.length >= 10 ? null : () => _add(all),
        icon: const Icon(Icons.add_rounded),
        label: Text(verified.isEmpty ? 'Aktifkan MFA' : 'Tambah cadangan'),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (verified.isEmpty)
          InfoBanner(
            message: s?.mfaRequired == true ? 'Kebijakan keamanan COMEN mewajibkan MFA. Aktifkan authenticator sekarang.' : 'MFA belum aktif. Aktifkan untuk melindungi akun Anda dari pengambilalihan.',
            color: s?.mfaRequired == true ? Brand.red : Brand.amber,
            icon: Icons.warning_amber_rounded,
          )
        else if (verified.length == 1)
          const InfoBanner(
            message: 'Hanya ada 1 authenticator. Tambahkan cadangan (mis. di ponsel kedua). Bila semuanya hilang, authenticator bisa direset lewat kode email di halaman verifikasi.',
            color: Brand.amber,
            icon: Icons.key_rounded,
          ),
        if (all.isNotEmpty) const SizedBox(height: 12),
        for (final f in all)
          Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(border: Border.all(color: Theme.of(context).dividerColor), borderRadius: BorderRadius.circular(14)),
            child: Row(children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: (f.status == FactorStatus.verified ? Brand.green : Brand.grey).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(Icons.qr_code_2_rounded, color: f.status == FactorStatus.verified ? Brand.green : Brand.grey),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(f.friendlyName ?? 'Authenticator', style: const TextStyle(fontWeight: FontWeight.w700)),
                  Text('Ditambahkan ${fmtDate(f.createdAt.toIso8601String())}', style: Theme.of(context).textTheme.bodySmall),
                ]),
              ),
              f.status == FactorStatus.verified ? const StatusBadge(Brand.green, 'Aktif') : const StatusBadge(Brand.grey, 'Belum diverifikasi'),
              const SizedBox(width: 4),
              Tooltip(
                message: lastLocked && f.status == FactorStatus.verified ? 'MFA wajib untuk akun Anda — tambah cadangan dulu sebelum menghapus' : 'Hapus',
                child: IconButton(
                  onPressed: lastLocked && f.status == FactorStatus.verified ? null : () => _remove(f),
                  icon: const Icon(Icons.delete_outline_rounded),
                  color: Brand.red,
                ),
              ),
            ]),
          ),
        if (all.isEmpty) const EmptyState(icon: Icons.phonelink_lock_rounded, title: 'Belum ada authenticator'),
      ]),
    );
  }

  Widget _sessionCard(SessionState? s, J? profile, int verified) {
    if (s == null) return const SizedBox.shrink();
    return SectionCard(
      title: 'Sesi & login',
      icon: Icons.security_rounded,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        KeyValueGrid(minItemWidth: 180, [
          ('Tingkat sesi', s.aal == 'aal2' ? const StatusBadge(Brand.green, 'AAL2 · MFA', icon: Icons.verified_user_rounded) : const StatusBadge(Brand.amber, 'AAL1', icon: Icons.lock_open_rounded)),
          ('MFA wajib', Text(s.mfaRequired ? 'Ya (kebijakan keamanan)' : 'Tidak')),
          ('Step-up', s.stepUpFresh ? const StatusBadge(Brand.green, 'Masih berlaku') : const StatusBadge(Brand.grey, 'Perlu kode untuk aksi kritis')),
          ('Login Email OTP', s.emailOtpEnabled ? const StatusBadge(Brand.blue, 'Aktif (diatur Admin)') : const StatusBadge(Brand.grey, 'Nonaktif (diatur Admin)')),
          ('Login terakhir', Text(profile == null ? '-' : '${fmtDateTime(profile['last_login_at'])}${profile['last_login_at'] == null ? '' : ' · ${fmtRelative(profile['last_login_at'])}'}')),
          ('Akun dibuat', Text(profile == null ? '-' : fmtDate(profile['created_at']))),
        ]),
        const Divider(height: 28),
        Text('Riwayat login & perangkat dicatat sebagai security event dan ditinjau Admin. Login dari perangkat baru selalu dikirimkan sebagai notifikasi kepada Anda.',
            style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton.icon(onPressed: () => context.go('/settings/devices'), icon: const Icon(Icons.devices_rounded), label: const Text('Kelola perangkat')),
          OutlinedButton.icon(onPressed: () => context.go('/notifications'), icon: const Icon(Icons.notifications_none_rounded), label: const Text('Lihat notifikasi')),
        ]),
      ]),
    );
  }
}

class _EnrollDialog extends ConsumerStatefulWidget {
  const _EnrollDialog({required this.existing});
  final int existing;
  @override
  ConsumerState<_EnrollDialog> createState() => _EnrollDialogState();
}

class _EnrollDialogState extends ConsumerState<_EnrollDialog> {
  late final _name = TextEditingController(text: widget.existing == 0 ? 'Authenticator utama' : 'Authenticator cadangan ${widget.existing + 1}');
  final _code = TextEditingController();
  AuthMFAEnrollResponse? _enroll;
  String? _error;
  bool _busy = false;

  GoTrueMFAApi get _mfa => Supabase.instance.client.auth.mfa;

  Future<void> _start() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final factors = await guard(() => _mfa.listFactors());
      for (final f in factors.all.where((f) => f.status == FactorStatus.unverified)) {
        await guard(() => _mfa.unenroll(f.id));
      }
      final r = await ref.read(authGatewayProvider).enrollTotp(name: '${_name.text.trim()} · ${DateTime.now().millisecondsSinceEpoch % 10000}');
      if (mounted) setState(() => _enroll = r);
    } catch (e) {
      if (mounted) setState(() => _error = AppFailure.from(e).message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verify() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(authGatewayProvider).verifyEnrollment(_enroll!.id, _code.text);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _error = AppFailure.from(e).message);
        _code.clear();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancel() async {
    final id = _enroll?.id;
    if (id != null) {
      try {
        await _mfa.unenroll(id);
      } catch (_) {}
    }
    if (mounted) Navigator.pop(context, false);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final totp = _enroll?.totp;
    return AlertDialog(
      icon: const Icon(Icons.phonelink_lock_rounded, color: Brand.blue, size: 36),
      title: Text(widget.existing == 0 ? 'Aktifkan authenticator' : 'Tambah authenticator cadangan'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (_error != null) ...[InfoBanner(message: _error!, color: Brand.red), const SizedBox(height: 12)],
            if (totp == null) ...[
              Text('Beri nama agar mudah dikenali (mis. "iPhone pribadi").', style: t.bodyMedium),
              const SizedBox(height: 12),
              TextField(controller: _name, maxLength: 40, autofocus: true, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'Nama authenticator')),
            ] else ...[
              Text('Pindai QR berikut dengan aplikasi authenticator, lalu masukkan kode 6 digit.', style: t.bodyMedium),
              const SizedBox(height: 16),
              Center(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFFE4E7EC))),
                  child: QrImageView(data: totp.uri, size: 200, backgroundColor: Colors.white),
                ),
              ),
              const SizedBox(height: 10),
              Text('Atau masukkan kunci manual:', style: t.bodySmall, textAlign: TextAlign.center),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [Flexible(child: MonoText(totp.secret, size: 12)), CopyButton(totp.secret)]),
              const SizedBox(height: 12),
              TextField(
                controller: _code,
                autofocus: true,
                keyboardType: TextInputType.number,
                maxLength: 6,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 26, letterSpacing: 10, fontWeight: FontWeight.w800),
                onChanged: (v) {
                  setState(() {});
                  if (v.trim().length == 6 && !_busy) _verify();
                },
                decoration: const InputDecoration(counterText: '', labelText: 'Kode 6 digit'),
              ),
            ],
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : _cancel, child: const Text('Batal')),
        if (totp == null)
          FilledButton(onPressed: _busy || _name.text.trim().isEmpty ? null : _start, child: _busy ? const _BtnSpinner() : const Text('Lanjut'))
        else
          FilledButton(onPressed: _busy || _code.text.trim().length != 6 ? null : _verify, child: _busy ? const _BtnSpinner() : const Text('Verifikasi & simpan')),
      ],
    );
  }
}

class _BtnSpinner extends StatelessWidget {
  const _BtnSpinner();
  @override
  Widget build(BuildContext context) => const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white));
}

// ═══════════════════════════ Web Push (16.15) ═══════════════════════════
typedef _PushKeys = ({String endpoint, String p256dh, String auth});

abstract final class _WebPush {
  static const _scope = '/push/';

  static bool get supported =>
      globalContext.has('PushManager') && globalContext.has('Notification') && web.window.navigator.has('serviceWorker') && web.window.isSecureContext;

  static String get permission => supported ? web.Notification.permission : 'unsupported';

  static Future<web.PushSubscription?> current() async {
    if (!supported) return null;
    final reg = await web.window.navigator.serviceWorker.getRegistration(_scope).toDart;
    if (reg == null) return null;
    return reg.pushManager.getSubscription().toDart;
  }

  /// null = izin ditolak / tidak didukung
  static Future<_PushKeys?> subscribe(String vapidKey) async {
    if (!supported) return null;
    final perm = (await web.Notification.requestPermission().toDart).toDart;
    if (perm != 'granted') return null;
    final reg = await web.window.navigator.serviceWorker.register('/push_sw.js'.toJS, web.RegistrationOptions(scope: _scope)).toDart;
    for (var i = 0; i < 50 && reg.active == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    final key = base64Url.decode(base64Url.normalize(vapidKey));
    final sub = await reg.pushManager.getSubscription().toDart ??
        await reg.pushManager.subscribe(web.PushSubscriptionOptionsInit(userVisibleOnly: true, applicationServerKey: key.toJS)).toDart;
    final j = sub.toJSON();
    final keys = j.keys;
    return (
      endpoint: j.endpoint,
      p256dh: keys.getProperty<JSString>('p256dh'.toJS).toDart,
      auth: keys.getProperty<JSString>('auth'.toJS).toDart,
    );
  }

  /// Mengembalikan endpoint yang dilepas (untuk dihapus di server)
  static Future<String?> unsubscribe() async {
    final sub = await current();
    if (sub == null) return null;
    final endpoint = sub.endpoint;
    await sub.unsubscribe().toDart;
    return endpoint;
  }
}

// ═══════════════════════════ Preferensi notifikasi ═══════════════════════════
class NotificationSettingsPage extends ConsumerStatefulWidget {
  const NotificationSettingsPage({super.key});
  @override
  ConsumerState<NotificationSettingsPage> createState() => _NotificationSettingsPageState();
}

class _NotificationSettingsPageState extends ConsumerState<NotificationSettingsPage> {
  String _permission = 'default';
  String? _endpoint;
  bool _pushLoading = true, _pushBusy = false;
  Future<List<J>>? _channels;

  @override
  void initState() {
    super.initState();
    _checkPush();
    final st = ref.read(sessionProvider);
    if (st is SessionReady && st.s.can('chat.use')) _channels = _loadChannels();
  }

  Future<List<J>> _loadChannels() => ref.read(apiProvider).rpcList('list_my_channels');

  Future<void> _checkPush() async {
    try {
      final sub = await _WebPush.current();
      if (!mounted) return;
      setState(() {
        _permission = _WebPush.permission;
        _endpoint = sub?.endpoint;
      });
    } catch (_) {
      if (mounted) setState(() => _permission = _WebPush.permission);
    } finally {
      if (mounted) setState(() => _pushLoading = false);
    }
  }

  Future<void> _enablePush() async {
    setState(() => _pushBusy = true);
    final r = await runAction<bool>(context, ref, () async {
      final k = await _subscribeGuarded();
      if (k == null) return false;
      await ref.read(apiProvider).rpc('save_push_subscription', {'p_endpoint': k.endpoint, 'p_p256dh': k.p256dh, 'p_auth': k.auth});
      return true;
    });
    if (!mounted) return;
    setState(() => _pushBusy = false);
    if (r == true) showSnack(context, 'Notifikasi push aktif di perangkat ini');
    if (r == false) showSnack(context, 'Izin notifikasi browser tidak diberikan', error: true);
    await _checkPush();
  }

  Future<_PushKeys?> _subscribeGuarded() async {
    try {
      return await _WebPush.subscribe(Env.vapidPublicKey);
    } catch (e) {
      throw AppFailure(Hint.unknown, 'Browser menolak langganan push: $e');
    }
  }

  Future<void> _disablePush() async {
    setState(() => _pushBusy = true);
    await runAction(context, ref, () async {
      final endpoint = await _WebPush.unsubscribe();
      if (endpoint != null) await ref.read(apiProvider).rpc('delete_push_subscription', {'p_endpoint': endpoint});
      return true;
    }, success: 'Notifikasi push dimatikan di perangkat ini');
    if (!mounted) return;
    setState(() => _pushBusy = false);
    await _checkPush();
  }

  @override
  Widget build(BuildContext context) {
    final s = _session(ref);
    return PageScaffold(
      title: 'Notifikasi',
      subtitle: 'Atur cara COMEN memberi tahu Anda',
      maxWidth: 1100,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const _SettingsNav('/settings/notifications'),
        _pushCard(),
        const SizedBox(height: 16),
        const _CategoryCard(),
        if (_channels != null) ...[
          const SizedBox(height: 16),
          _ChannelPrefs(future: _channels!, onRetry: () => setState(() => _channels = _loadChannels())),
        ] else if (s != null && !s.can('chat.use')) ...[
          const SizedBox(height: 16),
          const InfoBanner(message: 'Preferensi per percakapan tersedia bila Anda memiliki akses Chat.'),
        ],
      ]),
    );
  }

  Widget _pushCard() {
    final configured = Env.vapidPublicKey.isNotEmpty;
    final supported = _WebPush.supported;
    final on = _endpoint != null;
    final (Color c, String label, IconData icon) = !supported
        ? (Brand.grey, 'Tidak didukung browser ini', Icons.block_rounded)
        : _permission == 'denied'
            ? (Brand.red, 'Diblokir di browser', Icons.notifications_off_rounded)
            : on
                ? (Brand.green, 'Aktif di perangkat ini', Icons.notifications_active_rounded)
                : (Brand.grey, 'Mati', Icons.notifications_none_rounded);
    return SectionCard(
      title: 'Web Push (perangkat ini)',
      subtitle: 'Pemberitahuan pesan chat & pesan URGENT saat COMEN tidak sedang dibuka. Isi pesan tidak pernah dikirim lewat push.',
      icon: Icons.notifications_active_outlined,
      trailing: _pushLoading ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : StatusBadge(c, label, icon: icon),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (!configured)
          const InfoBanner(message: 'Web Push belum dikonfigurasi di lingkungan ini (VAPID key kosong).', color: Brand.amber, icon: Icons.construction_rounded)
        else if (!supported)
          const InfoBanner(message: 'Browser ini tidak mendukung Web Push (butuh HTTPS + Service Worker). Di iOS, tambahkan COMEN ke Layar Utama terlebih dulu.', color: Brand.grey)
        else if (_permission == 'denied')
          const InfoBanner(
            message: 'Izin notifikasi diblokir. Buka pengaturan situs di browser (ikon gembok di address bar) → izinkan Notifikasi, lalu muat ulang halaman.',
            color: Brand.red,
            icon: Icons.notifications_off_rounded,
          ),
        const SizedBox(height: 12),
        Wrap(spacing: 10, runSpacing: 10, alignment: WrapAlignment.end, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text('Status per perangkat juga terlihat di halaman Perangkat.', style: Theme.of(context).textTheme.bodySmall),
          if (on)
            OutlinedButton.icon(
              onPressed: _pushBusy ? null : _disablePush,
              icon: const Icon(Icons.notifications_off_outlined),
              label: const Text('Matikan push'),
            )
          else
            FilledButton.icon(
              onPressed: _pushBusy || !configured || !supported || _permission == 'denied' ? null : _enablePush,
              icon: _pushBusy ? const _BtnSpinner() : const Icon(Icons.notifications_active_rounded),
              label: const Text('Aktifkan push'),
            ),
        ]),
      ]),
    );
  }
}

class _CategoryCard extends StatelessWidget {
  const _CategoryCard();

  static const _rows = [
    (Icons.task_alt_rounded, 'Task & review', 'Task baru, jatuh tempo, keputusan review, revisi', 'In-app · email'),
    (Icons.handshake_rounded, 'Kontrak & vendor', 'Perubahan fase, gate mobilisasi, ASL', 'In-app · email'),
    (Icons.shield_outlined, 'Keamanan akun', 'Login perangkat baru, perubahan role/status', 'In-app · email (wajib)'),
    (Icons.forum_rounded, 'Chat', 'Mention, DM, pesan wajib-baca, URGENT', 'In-app · push · email fallback'),
  ];

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return SectionCard(
      title: 'Kategori notifikasi',
      subtitle: 'Notifikasi kepatuhan & keamanan selalu dikirim (kebijakan WFRD). Notifikasi chat dapat diatur per percakapan di bawah.',
      icon: Icons.category_outlined,
      child: ResponsiveGrid(minItemWidth: 240, spacing: 12, children: [
        for (final (icon, title, desc, via) in _rows)
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(border: Border.all(color: Theme.of(context).dividerColor), borderRadius: BorderRadius.circular(14)),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(icon, color: Brand.blue, size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: t.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(desc, style: t.bodySmall),
                  const SizedBox(height: 6),
                  Text(via, style: t.labelSmall?.copyWith(color: Brand.blue, fontWeight: FontWeight.w700)),
                ]),
              ),
            ]),
          ),
      ]),
    );
  }
}

class _ChannelPrefs extends ConsumerStatefulWidget {
  const _ChannelPrefs({required this.future, required this.onRetry});
  final Future<List<J>> future;
  final VoidCallback onRetry;
  @override
  ConsumerState<_ChannelPrefs> createState() => _ChannelPrefsState();
}

class _ChannelPrefsState extends ConsumerState<_ChannelPrefs> {
  String _q = '';

  static const _typeIcon = {
    'announcement': Icons.campaign_rounded,
    'contract': Icons.tag_rounded,
    'task': Icons.task_alt_rounded,
    'direct': Icons.person_rounded,
    'group': Icons.groups_rounded,
  };

  Future<void> _set(J c, String level, DateTime? mutedUntil) async {
    final r = await runAction(
      context,
      ref,
      () async {
        await ref.read(apiProvider).rpc('chat_set_notify', {'p_channel': c['id'], 'p_level': level, 'p_muted_until': mutedUntil?.toUtc().toIso8601String()});
        return true;
      },
      success: 'Preferensi disimpan',
    );
    if (r == true && mounted) {
      setState(() {
        c['notify_level'] = level;
        c['muted_until'] = mutedUntil?.toUtc().toIso8601String();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: 'Notifikasi per percakapan',
      subtitle: 'Semua pesan · hanya mention · mati. Pesan URGENT & wajib-baca tetap diberitahukan.',
      icon: Icons.forum_outlined,
      trailing: SizedBox(
        width: 220,
        child: TextField(
          onChanged: (v) => setState(() => _q = v.trim().toLowerCase()),
          decoration: const InputDecoration(isDense: true, prefixIcon: Icon(Icons.search_rounded, size: 18), hintText: 'Cari percakapan'),
        ),
      ),
      child: AsyncView<List<J>>(
        future: widget.future,
        onRetry: widget.onRetry,
        builder: (context, rows) {
          final list = rows.where((c) => _q.isEmpty || str(c['name'], '').toLowerCase().contains(_q)).toList();
          if (list.isEmpty) return const EmptyState(icon: Icons.forum_outlined, title: 'Tidak ada percakapan');
          return Column(children: [
            for (final c in list) _row(c),
          ]);
        },
      ),
    );
  }

  Widget _row(J c) {
    final level = (c['notify_level'] as String?) ?? 'all';
    final muted = parseDate(c['muted_until']);
    final isMuted = muted != null && muted.isAfter(DateTime.now());
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final seg = SegmentedButton<String>(
      showSelectedIcon: false,
      style: const ButtonStyle(visualDensity: VisualDensity.compact),
      segments: const [
        ButtonSegment(value: 'all', label: Text('Semua')),
        ButtonSegment(value: 'mentions', label: Text('Mention')),
        ButtonSegment(value: 'none', label: Text('Mati')),
      ],
      selected: {level},
      onSelectionChanged: (v) => _set(c, v.first, isMuted ? muted : null),
    );
    final mute = PopupMenuButton<Duration>(
      tooltip: 'Bisukan sementara',
      icon: Icon(isMuted ? Icons.notifications_paused_rounded : Icons.snooze_rounded, color: isMuted ? Brand.amber : null),
      onSelected: (d) => _set(c, level, d == Duration.zero ? null : DateTime.now().add(d)),
      itemBuilder: (_) => [
        for (final (d, l) in const [(Duration(hours: 1), '1 jam'), (Duration(hours: 8), '8 jam'), (Duration(days: 1), '24 jam'), (Duration(days: 7), '1 minggu')])
          PopupMenuItem(value: d, child: Text('Bisukan $l')),
        if (isMuted) const PopupMenuItem(value: Duration.zero, child: Text('Aktifkan kembali')),
      ],
    );
    final title = Row(children: [
      Icon(_typeIcon[c['type']] ?? Icons.chat_bubble_outline_rounded, size: 20, color: Brand.blue),
      const SizedBox(width: 10),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(str(c['name'], 'Percakapan'), style: const TextStyle(fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis),
          if (isMuted) Text('Dibisukan s/d ${fmtDateTime(c['muted_until'])}', style: const TextStyle(fontSize: 12, color: Brand.amber)),
        ]),
      ),
    ]);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Theme.of(context).dividerColor.withValues(alpha: 0.5)))),
      child: wide
          ? Row(children: [Expanded(child: title), seg, mute])
          : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [title, const SizedBox(height: 8), Row(children: [Flexible(child: seg), mute])]),
    );
  }
}
