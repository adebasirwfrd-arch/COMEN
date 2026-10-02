// lib/core/security/secure_store.dart
import 'dart:js_interop';
import 'package:web/web.dart' as web;

@JS('comenSecure')
external _ComenSecure get _js;

extension type _ComenSecure._(JSObject _) implements JSObject {
  external JSPromise<JSBoolean> ready();
  external JSPromise<JSAny?> put(JSString name, JSString value);
  external JSPromise<JSString?> read(JSString name);
  external JSPromise<JSAny?> del(JSString name);
  external JSPromise<JSString> sha256File(web.File file);
  external void notifySession();
  external void onSession(JSFunction callback);
  external JSPromise<JSString?> subscribePush(JSString vapidKey);
  external JSPromise<JSString?> unsubscribePush();
}

class SecureStore {
  const SecureStore();
  Future<void> ready() async => (await _js.ready().toDart);
  Future<void> put(String k, String v) async => await _js.put(k.toJS, v.toJS).toDart;
  Future<String?> read(String k) async => (await _js.read(k.toJS).toDart)?.toDart;
  Future<void> del(String k) async => await _js.del(k.toJS).toDart;
  Future<String> sha256File(web.File f) async => (await _js.sha256File(f).toDart).toDart;
  void notifySession() => _js.notifySession();
  void onSession(void Function() f) => _js.onSession(f.toJS);
  Future<String?> subscribePush(String vapid) async => (await _js.subscribePush(vapid.toJS).toDart)?.toDart;
  Future<String?> unsubscribePush() async => (await _js.unsubscribePush().toDart)?.toDart;
}
