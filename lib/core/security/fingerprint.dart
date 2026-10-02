// Pilih file lokal → SHA-256 di browser (file TIDAK diupload)
import 'dart:async';
import 'dart:js_interop';
import 'package:web/web.dart' as web;
import 'secure_store.dart';

final taskIdRe = RegExp(r'^CMN-(V\d{5}|\d{5}(S\d{2})?)-[A-Z0-9]{6}-\d{3}(-R\d{1,2})?$');

/// Nama file wajib diawali Task ID tepat, lalu spasi / titik / akhir nama (7.1). Server memeriksa ulang.
bool fileNameMatchesTask(String fileName, String taskId) =>
    fileName == taskId || fileName.startsWith('$taskId ') || fileName.startsWith('$taskId.');

Future<({String name, int size, String sha256})?> pickAndHash(SecureStore store) async {
  final input = web.HTMLInputElement()..type = 'file';
  final c = Completer<web.File?>();
  input.addEventListener('change', ((web.Event _) => c.complete(input.files?.item(0))).toJS);
  input.addEventListener('cancel', ((web.Event _) => c.complete(null)).toJS);          // C10: batal → tidak hang
  input.click();
  final f = await c.future;
  if (f == null) return null;
  return (name: f.name, size: f.size, sha256: await store.sha256File(f));
}

Uri mailtoFrom(Map<String, dynamic> ctx) {
  String q(String k, String v) => '$k=${Uri.encodeComponent(v)}';
  final parts = [q('subject', ctx['subject'] as String), q('body', ctx['body'] as String),
                 if (ctx['cc'] != null) q('cc', ctx['cc'] as String)];
  return Uri.parse('mailto:${Uri.encodeComponent(ctx['to'] as String)}?${parts.join('&')}');
}
