// lib/core/security/device_identity.dart
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'secure_store.dart';

/// 32 byte acak per perangkat (terenkripsi di IndexedDB). Server hanya menerima SHA-256-nya (header x-device-id).
class DeviceIdentity {
  DeviceIdentity._(this.hash);
  final String hash;                                    // 64 hex
  static const _key = 'device_id_v1';

  static Future<DeviceIdentity> load(SecureStore store) async {
    Uint8List? raw;
    final stored = await store.read(_key);
    if (stored != null) {
      try { raw = base64Url.decode(stored); } catch (_) { raw = null; }
    }
    if (raw == null || raw.length != 32) {
      final rnd = Random.secure();
      raw = Uint8List.fromList(List<int>.generate(32, (_) => rnd.nextInt(256)));
      await store.put(_key, base64Url.encode(raw));
    }
    return DeviceIdentity._(sha256.convert(raw).toString());
  }

  /// Dipakai halaman /device-revoked: identitas baru → wajib login ulang (register_device menolak sesi lama > 15 menit)
  static Future<void> reset(SecureStore store) => store.del(_key);
}
