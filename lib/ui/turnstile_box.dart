import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:ui_web' as ui_web;
import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;
import '../core/env.dart';

@JS('turnstile')
external _Turnstile? get _turnstile;

extension type _Turnstile._(JSObject _) implements JSObject {
  external JSString? render(web.HTMLElement el, JSObject opts);
  external void reset(JSString id);
  external void remove(JSString id);
}

JSObject _opts(Map<String, JSAny> m) {
  final o = JSObject();
  m.forEach((k, v) => o.setProperty(k.toJS, v));
  return o;
}

/// Cloudflare Turnstile (render eksplisit, tanpa inline script — sesuai CSP 5.4).
class TurnstileBox extends StatefulWidget {
  const TurnstileBox({super.key, required this.action, required this.onToken});
  final String action;
  final ValueChanged<String?> onToken;

  @override
  State<TurnstileBox> createState() => TurnstileBoxState();
}

class TurnstileBoxState extends State<TurnstileBox> {
  static int _seq = 0;
  static Completer<void>? _loader;
  late final String _viewType = 'comen-turnstile-${_seq++}';
  late final web.HTMLDivElement _host;
  String? _widgetId;
  String? _error;

  static Future<void> _ensureScript() {
    if (_turnstile != null) return Future.value();
    if (_loader != null) return _loader!.future;
    final c = _loader = Completer<void>();
    final s = web.HTMLScriptElement()
      ..src = 'https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit'
      ..async = true
      ..defer = true;
    s.onload = ((web.Event _) => c.complete()).toJS;
    s.onerror = ((web.Event _) {
      _loader = null;
      c.completeError(StateError('Turnstile gagal dimuat'));
    }).toJS;
    web.document.head!.append(s);
    return c.future;
  }

  @override
  void initState() {
    super.initState();
    _host = web.HTMLDivElement()
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.display = 'flex'
      ..style.justifyContent = 'center';
    ui_web.platformViewRegistry.registerViewFactory(_viewType, (int _) => _host);
    _render();
  }

  Future<void> _render() async {
    try {
      await _ensureScript();
      for (var i = 0; i < 50 && _turnstile == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      final t = _turnstile;
      if (t == null || !mounted) return;
      _widgetId = t.render(
        _host,
        _opts({
          'sitekey': Env.turnstileSiteKey.toJS,
          'action': widget.action.toJS,
          'theme': 'auto'.toJS,
          'size': 'flexible'.toJS,
          'callback': ((JSString tok) => widget.onToken(tok.toDart)).toJS,
          'expired-callback': (() => widget.onToken(null)).toJS,
          'error-callback': (() {
            widget.onToken(null);
            if (mounted) setState(() => _error = 'Verifikasi keamanan gagal. Muat ulang halaman.');
          }).toJS,
        }),
      )?.toDart;
    } catch (_) {
      if (mounted) setState(() => _error = 'Tidak dapat memuat verifikasi keamanan (Turnstile).');
    }
  }

  void reset() {
    final id = _widgetId;
    if (id != null) _turnstile?.reset(id.toJS);
    widget.onToken(null);
  }

  @override
  void dispose() {
    final id = _widgetId;
    if (id != null) _turnstile?.remove(id.toJS);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error));
    }
    return SizedBox(height: 72, child: HtmlElementView(viewType: _viewType));
  }
}
