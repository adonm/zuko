{{flutter_js}}
{{flutter_build_config}}

_flutter.loader.load({
  config: {
    renderer: 'skwasm',
    wasmAllowList: {
      gecko: true,
    },
  },
  serviceWorkerSettings: {
    serviceWorkerVersion: {{flutter_service_worker_version}},
  },
});
