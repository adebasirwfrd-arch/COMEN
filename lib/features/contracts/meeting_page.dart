import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/errors/app_failure.dart';
import '../../core/session/failure_handler.dart';
import '../../core/session/session_controller.dart';
import '../../data/api.dart';
import '../../data/columns.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'contract_common.dart';

const _meetingCols = 'id,contract_id,meeting_type,mom_no,scheduled_at,location,agenda,minutes,status,created_by,finalized_at,signed_at,created_at';

class _Data {
  _Data(this.m, this.k, this.contractor, this.attendees, this.signatures, this.tasks, this.cards);
  final J m, k, contractor;
  final List<J> attendees, signatures, tasks;
  final Map<String, J> cards;
  String get status => m['status'] as String? ?? 'draft';
  String get momNo => str(m['mom_no']);
}

/// Detail meeting / MoM: agenda, notulen, peserta, action item → task, finalisasi & tanda tangan dua pihak (Part 9.3).
class MeetingPage extends ConsumerStatefulWidget {
  const MeetingPage({super.key, required this.contractId, required this.meetingId});
  final String contractId, meetingId;
  @override
  ConsumerState<MeetingPage> createState() => _MeetingPageState();
}

class _MeetingPageState extends ConsumerState<MeetingPage> {
  late Future<_Data> _future = _load();
  StreamSubscription<String>? _sub;

  final _summary = TextEditingController();
  final Map<int, TextEditingController> _notes = {};
  List<J> _attendees = [];
  List<J> _actions = [];
  bool _dirty = false, _busy = false;

  @override
  void initState() {
    super.initState();
    _sub = ref.read(notificationBus).stream.listen((_) {
      if (!_dirty && mounted) _reload();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _summary.dispose();
    for (final c in _notes.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<_Data> _load() async {
    final api = ref.read(apiProvider);
    final m = await api.selectOne('meetings', _meetingCols, 'id', widget.meetingId);
    if (m == null || m['contract_id'] != widget.contractId) {
      throw const AppFailure(Hint.forbidden, 'Meeting tidak ditemukan atau Anda tidak memiliki akses.');
    }
    final r = await Future.wait<dynamic>([
      api.selectOne('contracts', 'id,contract_no,title,status,contractor_id', 'id', widget.contractId),
      api.select('meeting_attendees', 'id,meeting_id,user_id,name,party,role_title', build: (q) => q.eq('meeting_id', widget.meetingId).order('party')),
      api.select('signatures', 'id,entity,entity_id,signer_id,party,method,sig_hash,signed_at',
          build: (q) => q.eq('entity', 'meeting').eq('entity_id', widget.meetingId).order('signed_at')),
      m['mom_no'] == null
          ? Future.value(<J>[])
          : api.select('tasks', Cols.tasks, build: (q) => q.eq('contract_id', widget.contractId).eq('source_ref', m['mom_no'] as String).order('created_at')),
    ]);
    final k = (r[0] as J?) ?? <String, dynamic>{};
    final attendees = r[1] as List<J>;
    final sigs = r[2] as List<J>;
    final more = await Future.wait<dynamic>([
      k['contractor_id'] == null ? Future.value(null) : api.selectOne('contractors', Cols.contractors, 'id', k['contractor_id'] as String),
      loadUserCards(api, [m['created_by'] as String?, ...sigs.map((s) => s['signer_id'] as String?), ...attendees.map((a) => a['user_id'] as String?)]),
    ]);
    final d = _Data(m, k, (more[0] as J?) ?? <String, dynamic>{}, attendees, sigs, r[3] as List<J>, more[1] as Map<String, J>);
    _hydrate(d);
    return d;
  }

  void _hydrate(_Data d) {
    final minutes = jm(d.m['minutes'] is Map ? d.m['minutes'] : null);
    _summary.text = minutes['summary'] as String? ?? '';
    final notes = jm(minutes['agenda_notes'] is Map ? minutes['agenda_notes'] : null);
    for (final c in _notes.values) {
      c.dispose();
    }
    _notes.clear();
    final agenda = _agenda(d);
    for (var i = 0; i < agenda.length; i++) {
      _notes[i] = TextEditingController(text: notes['$i'] as String? ?? '');
    }
    _actions = jl(minutes['action_items'] is List ? minutes['action_items'] : null);
    _attendees = d.attendees.map((a) => <String, dynamic>{'user_id': a['user_id'], 'name': a['name'], 'party': a['party'], 'role_title': a['role_title']}).toList();
    _dirty = false;
  }

  List<String> _agenda(_Data d) => (d.m['agenda'] is List ? d.m['agenda'] as List : const []).map((e) => e is Map ? str(e['title'] ?? e['item']) : e.toString()).toList();

  void _reload() => setState(() => _future = _load());
  void _touch() => setState(() => _dirty = true);

  J _minutesPayload() => {
        'summary': _summary.text.trim(),
        'agenda_notes': {
          for (final e in _notes.entries)
            if (e.value.text.trim().isNotEmpty) '${e.key}': e.value.text.trim(),
        },
        'action_items': _actions,
      };

  Future<bool> _save({bool silent = false}) async {
    setState(() => _busy = true);
    final ok = await runOk(
      context,
      ref,
      () => ref.read(apiProvider).rpc('update_meeting', {'p_meeting': widget.meetingId, 'p_minutes': _minutesPayload(), 'p_attendees': _attendees}),
      success: silent ? null : 'Notulen disimpan',
    );
    if (!mounted) return ok;
    setState(() {
      _busy = false;
      if (ok) _dirty = false;
    });
    return ok;
  }

  Future<void> _finalize(_Data d) async {
    if (_attendees.where((a) => a['party'] == 'contractor').isEmpty || _attendees.where((a) => a['party'] == 'wfrd').isEmpty) {
      showSnack(context, 'Tambahkan minimal satu peserta WFRD dan satu peserta kontraktor sebelum finalisasi.');
      return;
    }
    final go = await showConfirm(
      context,
      title: 'Finalisasi ${d.momNo}?',
      message: 'Notulen & peserta tidak bisa diubah setelah final. Kontraktor akan diberi notifikasi untuk menandatangani MoM.',
      confirmLabel: 'Finalisasi',
    );
    if (!go || !mounted) return;
    if (_dirty && !await _save(silent: true)) return;
    if (!mounted) return;
    final ok = await runOk(context, ref, () => ref.read(apiProvider).rpc('finalize_meeting', {'p_meeting': widget.meetingId}), success: 'MoM final — menunggu tanda tangan');
    if (ok) _reload();
  }

  Future<void> _sign(_Data d) async {
    final s = readSession(ref);
    final expected = (s?.fullName ?? '').trim();
    final ctl = TextEditingController();
    var agree = false;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
        final nameOk = ctl.text.trim().isNotEmpty && (expected.isEmpty || ctl.text.trim().toLowerCase() == expected.toLowerCase());
        return AlertDialog(
          icon: const Icon(Icons.draw_rounded, color: Brand.blue, size: 38),
          title: Text('Tanda tangani ${d.momNo}'),
          content: SizedBox(
            width: 460,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Text('Tanda tangan elektronik (typed name). Hash isi MoM saat ini dicatat bersama identitas & waktu Anda.'),
              const SizedBox(height: 16),
              TextField(
                controller: ctl,
                autofocus: true,
                onChanged: (_) => set(() {}),
                style: const TextStyle(fontFamily: 'serif', fontStyle: FontStyle.italic, fontSize: 22),
                decoration: InputDecoration(
                  labelText: 'Ketik nama lengkap Anda',
                  helperText: expected.isEmpty ? null : 'Harus sama dengan nama profil: $expected',
                ),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: agree,
                onChanged: (v) => set(() => agree = v ?? false),
                title: const Text('Saya telah membaca MoM ini dan menyetujui isinya.'),
                controlAffinity: ListTileControlAffinity.leading,
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal')),
            FilledButton.icon(
              onPressed: nameOk && agree ? () => Navigator.pop(ctx, true) : null,
              icon: const Icon(Icons.verified_rounded),
              label: const Text('Tanda tangani'),
            ),
          ],
        );
      }),
    );
    if (go != true || !mounted) return;
    final ok = await runOk(
      context,
      ref,
      () => ref.read(apiProvider).rpc('sign_entity', {'p_entity': 'meeting', 'p_entity_id': widget.meetingId, 'p_method': 'typed_name'}),
      success: 'MoM ditandatangani',
    );
    if (ok) _reload();
  }

  Future<void> _addAttendee({J? existing, int? index}) async {
    final r = await showDialog<J>(context: context, builder: (_) => _AttendeeDialog(existing: existing));
    if (r == null) return;
    setState(() {
      if (index != null) {
        _attendees[index] = r;
      } else {
        _attendees.add(r);
      }
      _dirty = true;
    });
  }

  Future<void> _editAction({J? existing, int? index}) async {
    final r = await showDialog<J>(context: context, builder: (_) => _ActionItemDialog(existing: existing));
    if (r == null) return;
    setState(() {
      if (index != null) {
        _actions[index] = r;
      } else {
        _actions.add(r);
      }
      _dirty = true;
    });
  }

  Future<void> _generateTask(_Data d, J item) async {
    final r = await showAdhocTaskDialog(
      context,
      contractId: widget.contractId,
      contractorId: d.k['contractor_id'] as String?,
      docType: 'ACTITM',
      title: item['title'] as String?,
      sourceRef: d.momNo,
      description: [
        'Action item dari ${d.momNo} (${meetingTypeLabel[d.m['meeting_type']] ?? 'Meeting'}, ${fmtDate(d.m['scheduled_at'])}).',
        if (item['owner'] != null) 'PIC: ${item['owner']}',
      ].join('\n'),
      due: parseDate(item['due']),
    );
    if (r != null) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final s = watchSession(ref);
    return AsyncView<_Data>(
      future: _future,
      onRetry: _reload,
      builder: (context, d) {
        final draft = d.status == 'draft';
        final manage = (s?.can('meeting.manage') ?? false) && draft;
        final signedByMe = d.signatures.any((x) => x['signer_id'] == s?.userId);
        final canSign = (s?.can('meeting.sign') ?? false) && d.status == 'final' && !signedByMe;
        final canGen = (s?.isWfrd ?? false) && (s?.can('task.generate') ?? false);
        return PageScaffold(
          title: '${meetingTypeLabel[d.m['meeting_type']] ?? 'Meeting'} · ${d.momNo}',
          subtitle: '${str(d.k['contract_no'])} · ${str(d.k['title'])}',
          leading: IconButton(
            tooltip: 'Kembali ke kontrak',
            onPressed: () => context.go('/contracts/${widget.contractId}?tab=meetings'),
            icon: const Icon(Icons.arrow_back_rounded),
          ),
          actions: [
            if (manage && _dirty)
              OutlinedButton.icon(
                onPressed: _busy ? null : () => _save(),
                icon: const Icon(Icons.save_rounded),
                label: const Text('Simpan draft'),
              ),
            if (manage)
              FilledButton.icon(
                onPressed: _busy ? null : () => _finalize(d),
                icon: const Icon(Icons.lock_rounded),
                label: const Text('Finalisasi MoM'),
              ),
            if (canSign)
              FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: Brand.green),
                onPressed: () => _sign(d),
                icon: const Icon(Icons.draw_rounded),
                label: const Text('Tanda tangani'),
              ),
            IconButton(tooltip: 'Muat ulang', onPressed: _dirty ? null : _reload, icon: const Icon(Icons.refresh_rounded)),
          ],
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _hero(d),
            const SizedBox(height: 16),
            if (manage && _dirty)
              const Padding(
                padding: EdgeInsets.only(bottom: 16),
                child: InfoBanner(message: 'Ada perubahan yang belum disimpan.', color: Brand.amber, icon: Icons.edit_note_rounded),
              ),
            if (d.status == 'final')
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: InfoBanner(
                  color: Brand.blue,
                  icon: Icons.draw_rounded,
                  message: signedByMe
                      ? 'Anda sudah menandatangani. Menunggu tanda tangan pihak ${d.signatures.any((x) => x['party'] == 'wfrd') ? 'kontraktor' : 'WFRD'}.'
                      : 'MoM final — menunggu tanda tangan WFRD & kontraktor.',
                ),
              ),
            LayoutBuilder(builder: (context, c) {
              final wide = c.maxWidth >= 1050;
              final left = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                _agendaCard(d, manage),
                const SizedBox(height: 16),
                _summaryCard(manage),
                const SizedBox(height: 16),
                _actionsCard(d, manage, canGen),
              ]);
              final right = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                _signCard(d),
                const SizedBox(height: 16),
                _attendeesCard(d, manage),
                const SizedBox(height: 16),
                _tasksCard(d),
              ]);
              if (!wide) return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [left, const SizedBox(height: 16), right]);
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

  Widget _hero(_Data d) {
    const steps = ['draft', 'final', 'signed'];
    const labels = {'draft': 'Draft', 'final': 'Final', 'signed': 'Ditandatangani'};
    final idx = steps.indexOf(d.status);
    return HeroHeader(
      title: d.momNo,
      icon: Icons.groups_rounded,
      lines: [
        '${meetingTypeLabel[d.m['meeting_type']] ?? 'Meeting'} · ${str(d.contractor['legal_name'])}',
        'Dibuat ${fmtDateTime(d.m['created_at'])} oleh ${str(d.cards[d.m['created_by']]?['full_name'])}',
      ],
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        for (var i = 0; i < steps.length; i++) ...[
          if (i > 0) Container(width: 18, height: 2, color: i <= idx ? Colors.white : Colors.white30),
          Tooltip(
            message: labels[steps[i]]!,
            child: CircleAvatar(
              radius: 14,
              backgroundColor: i <= idx ? Colors.white : Colors.white24,
              child: Icon(
                i < idx || (i == idx && i == steps.length - 1) ? Icons.check_rounded : [Icons.edit_rounded, Icons.lock_rounded, Icons.verified_rounded][i],
                size: 15,
                color: i <= idx ? Brand.blue : Colors.white70,
              ),
            ),
          ),
        ],
      ]),
      chips: [
        HeroChip(labels[d.status] ?? d.status, icon: Icons.flag_rounded),
        HeroChip(fmtDateTime(d.m['scheduled_at']), icon: Icons.event_rounded),
        if (d.m['location'] != null) HeroChip(str(d.m['location']), icon: Icons.place_rounded),
        HeroChip('${d.attendees.length} peserta', icon: Icons.people_alt_rounded),
        if (d.m['finalized_at'] != null) HeroChip('Final ${fmtDate(d.m['finalized_at'])}', icon: Icons.lock_rounded),
        if (d.m['signed_at'] != null) HeroChip('Signed ${fmtDate(d.m['signed_at'])}', icon: Icons.verified_rounded),
      ],
    );
  }

  Widget _agendaCard(_Data d, bool manage) {
    final agenda = _agenda(d);
    return SectionCard(
      title: 'Agenda & catatan',
      subtitle: manage ? 'Tambahkan catatan pembahasan per butir agenda' : null,
      icon: Icons.format_list_numbered_rounded,
      child: agenda.isEmpty
          ? const EmptyState(icon: Icons.list_alt_rounded, title: 'Tidak ada agenda', message: 'Agenda ditentukan saat meeting dibuat.')
          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (var i = 0; i < agenda.length; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Container(
                      width: 28,
                      height: 28,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(color: Brand.blue.withValues(alpha: 0.1), shape: BoxShape.circle),
                      child: Text('${i + 1}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12, color: Brand.blue)),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        Padding(padding: const EdgeInsets.only(top: 4), child: Text(agenda[i], style: const TextStyle(fontWeight: FontWeight.w700))),
                        if (manage)
                          TextField(
                            controller: _notes[i],
                            minLines: 1,
                            maxLines: 4,
                            onChanged: (_) => _touch(),
                            decoration: const InputDecoration(isDense: true, hintText: 'Catatan…', border: InputBorder.none),
                          )
                        else if ((_notes[i]?.text ?? '').isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(_notes[i]!.text, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                          ),
                      ]),
                    ),
                  ]),
                ),
            ]),
    );
  }

  Widget _summaryCard(bool manage) => SectionCard(
        title: 'Ringkasan / notulen',
        icon: Icons.notes_rounded,
        child: manage
            ? TextField(
                controller: _summary,
                minLines: 4,
                maxLines: 14,
                maxLength: 8000,
                onChanged: (_) => _touch(),
                decoration: const InputDecoration(hintText: 'Kesimpulan, keputusan, dan poin penting meeting…'),
              )
            : _summary.text.isEmpty
                ? Text('Belum ada ringkasan.', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant))
                : SelectableText(_summary.text),
      );

  Widget _actionsCard(_Data d, bool manage, bool canGen) {
    bool linked(J a) => d.tasks.any((t) => (t['title'] as String?)?.trim().toLowerCase() == (a['title'] as String?)?.trim().toLowerCase());
    return SectionCard(
      title: 'Action items',
      subtitle: canGen ? 'Ubah action item menjadi task COMEN (ACTITM) dengan referensi ${d.momNo}' : null,
      icon: Icons.checklist_rounded,
      trailing: manage
          ? FilledButton.tonalIcon(onPressed: () => _editAction(), icon: const Icon(Icons.add_rounded, size: 18), label: const Text('Tambah'))
          : null,
      child: _actions.isEmpty
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(manage ? 'Belum ada action item. Tambahkan dari hasil pembahasan.' : 'Tidak ada action item.',
                  style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
            )
          : Column(children: [
              for (var i = 0; i < _actions.length; i++)
                Builder(builder: (_) {
                  final a = _actions[i];
                  final done = linked(a);
                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                    leading: Icon(done ? Icons.task_alt_rounded : Icons.radio_button_unchecked_rounded, color: done ? Brand.green : Brand.grey),
                    title: Text(str(a['title']), style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Text(['PIC: ${str(a['owner'])}', if (a['due'] != null) 'Due ${fmtDate(a['due'])}'].join(' · ')),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      if (done) const StatusBadge(Brand.green, 'Task dibuat'),
                      if (!done && canGen)
                        TextButton.icon(onPressed: () => _generateTask(d, a), icon: const Icon(Icons.add_task_rounded, size: 18), label: const Text('Jadikan task')),
                      if (manage) ...[
                        IconButton(tooltip: 'Ubah', onPressed: () => _editAction(existing: a, index: i), icon: const Icon(Icons.edit_rounded, size: 18)),
                        IconButton(
                          tooltip: 'Hapus',
                          onPressed: () => setState(() {
                            _actions.removeAt(i);
                            _dirty = true;
                          }),
                          icon: const Icon(Icons.delete_outline_rounded, size: 18, color: Brand.red),
                        ),
                      ],
                    ]),
                  );
                }),
            ]),
    );
  }

  Widget _signCard(_Data d) {
    Widget slot(String party, String label) {
      final sigs = d.signatures.where((x) => x['party'] == party).toList();
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: (sigs.isEmpty ? Brand.grey : Brand.green).withValues(alpha: 0.35)),
          color: (sigs.isEmpty ? Brand.grey : Brand.green).withValues(alpha: 0.05),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(sigs.isEmpty ? Icons.pending_outlined : Icons.verified_rounded, color: sigs.isEmpty ? Brand.grey : Brand.green, size: 20),
            const SizedBox(width: 8),
            Text(label, style: const TextStyle(fontWeight: FontWeight.w800)),
          ]),
          const SizedBox(height: 6),
          if (sigs.isEmpty)
            Text(d.status == 'draft' ? 'Tersedia setelah MoM final' : 'Belum ditandatangani', style: const TextStyle(color: Brand.grey, fontSize: 12))
          else
            for (final x in sigs)
              UserCardTile(
                card: d.cards[x['signer_id']],
                fallbackId: x['signer_id'] as String?,
                dense: true,
                caption: '${fmtDateTime(x['signed_at'])} · ${x['method'] == 'drawn' ? 'gambar' : 'typed name'}',
                trailing: Tooltip(
                  message: 'SHA-256: ${str(x['sig_hash'])}',
                  child: const Icon(Icons.fingerprint_rounded, color: Brand.green),
                ),
              ),
        ]),
      );
    }

    return SectionCard(
      title: 'Tanda tangan',
      subtitle: 'MoM sah setelah ditandatangani WFRD & kontraktor',
      icon: Icons.draw_rounded,
      trailing: d.status == 'signed' ? const StatusBadge(Brand.green, 'Lengkap', icon: Icons.verified_rounded) : null,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        slot('wfrd', 'Weatherford'),
        const SizedBox(height: 10),
        slot('contractor', str(d.contractor['legal_name'], 'Kontraktor')),
      ]),
    );
  }

  Widget _attendeesCard(_Data d, bool manage) {
    Widget group(String party, String label) {
      final rows = [for (var i = 0; i < _attendees.length; i++) if (_attendees[i]['party'] == party) i];
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 2),
          child: Text('$label (${rows.length})', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12, color: Brand.grey, letterSpacing: 0.4)),
        ),
        if (rows.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 6), child: Text('—', style: TextStyle(color: Brand.grey))),
        for (final i in rows)
          UserCardTile(
            dense: true,
            card: {
              ...?d.cards[_attendees[i]['user_id']],
              'full_name': _attendees[i]['name'],
              if (_attendees[i]['role_title'] != null) 'job_title': _attendees[i]['role_title'],
            },
            trailing: manage
                ? Row(mainAxisSize: MainAxisSize.min, children: [
                    IconButton(tooltip: 'Ubah', onPressed: () => _addAttendee(existing: _attendees[i], index: i), icon: const Icon(Icons.edit_rounded, size: 18)),
                    IconButton(
                      tooltip: 'Hapus',
                      onPressed: () => setState(() {
                        _attendees.removeAt(i);
                        _dirty = true;
                      }),
                      icon: const Icon(Icons.close_rounded, size: 18, color: Brand.red),
                    ),
                  ])
                : (_attendees[i]['user_id'] != null ? const Icon(Icons.verified_user_rounded, size: 18, color: Brand.blue) : null),
          ),
      ]);
    }

    return SectionCard(
      title: 'Peserta',
      icon: Icons.people_alt_rounded,
      trailing: manage ? IconButton.filledTonal(tooltip: 'Tambah peserta', onPressed: () => _addAttendee(), icon: const Icon(Icons.person_add_alt_1_rounded)) : null,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        group('wfrd', 'WEATHERFORD'),
        const Divider(height: 20),
        group('contractor', 'KONTRAKTOR'),
      ]),
    );
  }

  Widget _tasksCard(_Data d) => SectionCard(
        title: 'Task dari MoM ini',
        subtitle: 'source_ref = ${d.momNo}',
        icon: Icons.task_rounded,
        child: d.tasks.isEmpty
            ? Text('Belum ada task.', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant))
            : Column(children: [for (final t in d.tasks) TaskRow(t: t, onTap: () => context.go('/tasks/${t['id']}'))]),
      );
}

// ─────────────────────────── Dialog peserta ───────────────────────────
class _AttendeeDialog extends StatefulWidget {
  const _AttendeeDialog({this.existing});
  final J? existing;
  @override
  State<_AttendeeDialog> createState() => _AttendeeDialogState();
}

class _AttendeeDialogState extends State<_AttendeeDialog> {
  late final _name = TextEditingController(text: widget.existing?['name'] as String?);
  late final _role = TextEditingController(text: widget.existing?['role_title'] as String?);
  late String _party = widget.existing?['party'] as String? ?? 'wfrd';
  late String? _userId = widget.existing?['user_id'] as String?;

  Future<void> _pick() async {
    final u = await pickWfrdUser(context, title: 'Pilih peserta WFRD', roleKeys: const {'hse_admin', 'hse_reviewer', 'process_owner', 'procurement', 'hse_director'});
    if (u == null) return;
    setState(() {
      _userId = u['id'] as String?;
      _name.text = str(u['full_name'], '');
      if (_role.text.trim().isEmpty && u['job_title'] != null && !(u['job_title'] as String).contains('@')) _role.text = u['job_title'] as String;
      _party = 'wfrd';
    });
  }

  @override
  Widget build(BuildContext context) {
    final ok = _name.text.trim().length >= 2;
    return AlertDialog(
      title: Text(widget.existing == null ? 'Tambah peserta' : 'Ubah peserta'),
      content: SizedBox(
        width: 460,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'wfrd', icon: Icon(Icons.business_rounded), label: Text('Weatherford')),
              ButtonSegment(value: 'contractor', icon: Icon(Icons.engineering_rounded), label: Text('Kontraktor')),
            ],
            selected: {_party},
            onSelectionChanged: (v) => setState(() {
              _party = v.first;
              if (_party == 'contractor') _userId = null;
            }),
          ),
          const SizedBox(height: 14),
          if (_party == 'wfrd')
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(onPressed: _pick, icon: const Icon(Icons.person_search_rounded), label: Text(_userId == null ? 'Pilih user COMEN (opsional)' : 'User tertaut — ganti')),
            ),
          TextField(
            controller: _name,
            maxLength: 120,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(labelText: 'Nama *', prefixIcon: Icon(Icons.person_outline_rounded)),
          ),
          TextField(controller: _role, maxLength: 120, decoration: const InputDecoration(labelText: 'Jabatan / peran', prefixIcon: Icon(Icons.badge_outlined))),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
        FilledButton(
          onPressed: ok
              ? () => Navigator.pop(context, <String, dynamic>{
                    'user_id': _userId,
                    'name': _name.text.trim(),
                    'party': _party,
                    'role_title': trimOrNull(_role),
                  })
              : null,
          child: const Text('Simpan'),
        ),
      ],
    );
  }
}

// ─────────────────────────── Dialog action item ───────────────────────────
class _ActionItemDialog extends StatefulWidget {
  const _ActionItemDialog({this.existing});
  final J? existing;
  @override
  State<_ActionItemDialog> createState() => _ActionItemDialogState();
}

class _ActionItemDialogState extends State<_ActionItemDialog> {
  late final _title = TextEditingController(text: widget.existing?['title'] as String?);
  late final _owner = TextEditingController(text: widget.existing?['owner'] as String?);
  late DateTime? _due = parseDate(widget.existing?['due']);

  @override
  Widget build(BuildContext context) {
    final ok = _title.text.trim().length >= 3;
    return AlertDialog(
      title: Text(widget.existing == null ? 'Tambah action item' : 'Ubah action item'),
      content: SizedBox(
        width: 460,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextField(controller: _title, autofocus: true, maxLength: 200, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'Action item *')),
          TextField(controller: _owner, maxLength: 120, decoration: const InputDecoration(labelText: 'PIC')),
          DateField(
            label: 'Target selesai',
            value: _due,
            onTap: () async {
              final d = await pickDate(context, initial: _due ?? DateTime.now().add(const Duration(days: 7)), first: DateTime.now().subtract(const Duration(days: 30)));
              if (d != null) setState(() => _due = d);
            },
            onClear: () => setState(() => _due = null),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
        FilledButton(
          onPressed: ok
              ? () => Navigator.pop(context, <String, dynamic>{
                    'title': _title.text.trim(),
                    'owner': trimOrNull(_owner),
                    'due': _due == null ? null : isoDate(_due!),
                  })
              : null,
          child: const Text('Simpan'),
        ),
      ],
    );
  }
}
