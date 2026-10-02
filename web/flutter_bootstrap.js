// web/flutter_bootstrap.js — template Flutter; dua token di bawah diganti saat build (jangan tulis token di komentar).
{{flutter_js}}
{{flutter_build_config}}

_flutter.loader.load({
  config: {
    renderer: 'canvaskit',
    canvasKitBaseUrl: '/canvaskit/',                   // di-bundle (--no-web-resources-cdn)
    // fontFallbackBaseUrl: '/fonts/fallback/',        // aktifkan bila font fallback di-self-host (5.4)
  },
  serviceWorkerSettings: null,                        // service worker cache Flutter TIDAK dipakai (versi selalu segar)
});
