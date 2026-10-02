import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../core/errors/app_failure.dart';
import '../core/session/act_as.dart';

final apiProvider = Provider<Api>((_) => Api(Supabase.instance.client));

/// Akses data tunggal: tulis HANYA via RPC, baca via SELECT (RLS) dengan kolom eksplisit (16.13).
/// Semua pemanggilan dibungkus [guard] → [AppFailure] dengan hint terstruktur.
class Api {
  Api(this.sb);
  final SupabaseClient sb;

  /// Identitas efektif (target saat Act As mode user) — dipakai untuk "milik saya" (chat, filter task).
  String? get uid => ActAsRuntime.effectiveUserId ?? sb.auth.currentUser?.id;

  Future<dynamic> rpc(String fn, [Map<String, dynamic>? params]) =>
      guard(() async => await sb.rpc(fn, params: params ?? const {}));

  Future<Map<String, dynamic>> rpcMap(String fn, [Map<String, dynamic>? params]) async {
    final r = await rpc(fn, params);
    return r == null ? <String, dynamic>{} : Map<String, dynamic>.from(r as Map);
  }

  Future<List<Map<String, dynamic>>> rpcList(String fn, [Map<String, dynamic>? params]) async {
    final r = await rpc(fn, params);
    if (r == null) return const [];
    return (r as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  /// SELECT dengan daftar kolom eksplisit. [build] menambahkan filter/order/range.
  Future<List<Map<String, dynamic>>> select(
    String table,
    String columns, {
    PostgrestTransformBuilder<List<Map<String, dynamic>>> Function(PostgrestFilterBuilder<List<Map<String, dynamic>>> q)? build,
  }) =>
      guard(() async {
        final q = sb.from(table).select(columns);
        final res = build == null ? await q : await build(q);
        return List<Map<String, dynamic>>.from(res);
      });

  Future<Map<String, dynamic>?> selectOne(String table, String columns, String idCol, Object id) => guard(() async {
        final r = await sb.from(table).select(columns).eq(idCol, id).maybeSingle();
        return r == null ? null : Map<String, dynamic>.from(r);
      });

  /// Edge Function atas nama user (header x-device-id ikut otomatis dari Supabase.initialize).
  Future<Map<String, dynamic>> edge(String fn, Map<String, dynamic> body) => guard(() async {
        final r = await sb.functions.invoke(fn, body: body);
        return r.data is Map ? Map<String, dynamic>.from(r.data as Map) : <String, dynamic>{};
      });
}
