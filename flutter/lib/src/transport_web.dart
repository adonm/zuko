import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'model.dart';
import 'session_io.dart';
import 'session_state.dart';
import 'transport.dart';
import 'wire.dart';

@JS('zukoBridge.ready')
external JSPromise<JSAny?> _ready();
@JS('zukoBridge.spawn')
external JSPromise<JSObject> _spawn(JSUint8Array clientKey);
@JS('zukoBridge.claim')
external JSPromise<JSString> _claim(
  JSObject client,
  JSString code,
  JSString label,
);
@JS('zukoBridge.connect')
external JSPromise<JSObject> _connect(
  JSObject client,
  JSString ticket,
  JSUint8Array clientKey,
  JSNumber cols,
  JSNumber rows,
  JSNumber pixelWidth,
  JSNumber pixelHeight,
  JSFunction onEvent,
);
@JS('zukoBridge.send')
external JSPromise<JSAny?> _send(JSObject session, JSUint8Array bytes);
@JS('zukoBridge.resize')
external JSPromise<JSAny?> _resize(
  JSObject session,
  JSNumber cols,
  JSNumber rows,
  JSNumber pixelWidth,
  JSNumber pixelHeight,
);
@JS('zukoBridge.close')
external void _close(JSObject session);

Future<ClientTransport> createClientTransport(Uint8List clientKey) async {
  await _ready().toDart;
  return _WebTransport(clientKey, await _spawn(clientKey.toJS).toDart);
}

final class _WebTransport implements ClientTransport {
  const _WebTransport(this._clientKey, this._client);
  final Uint8List _clientKey;
  final JSObject _client;

  @override
  Future<ClaimResult> claim(String code, String clientLabel) async {
    final raw = (await _claim(
      _client,
      code.toJS,
      clientLabel.toJS,
    ).toDart).toDart;
    final json = jsonDecode(raw) as Map<String, Object?>;
    return ClaimResult(
      label: json['label']! as String,
      ticket: json['ticket']! as String,
      nodeId: json['nodeId']! as String,
    );
  }

  @override
  TerminalSession connect(SavedHost host, TerminalGeometry geometry) =>
      _WebSession(_client, _clientKey, host, geometry)..start();

  @override
  Future<void> close() async {}
}

final class _WebSession implements TerminalSession {
  _WebSession(this._client, this._clientKey, this._host, this._geometry);
  final JSObject _client;
  final Uint8List _clientKey;
  final SavedHost _host;
  TerminalGeometry _geometry;
  final _output = StreamController<Uint8List>.broadcast(sync: true);
  final _states = StreamController<SessionState>.broadcast(sync: true);
  final _tunnels = StreamController<TunnelEndpoint>.broadcast(sync: true);
  JSObject? _session;
  final _attachment = SessionAttachmentGate();
  final _writer = BoundedSessionWriter();
  bool _closed = false;
  final _closedSignal = Completer<void>();
  Future<void>? _runner;

  @override
  Stream<Uint8List> get output => _output.stream;
  @override
  Stream<SessionState> get states => _states.stream;
  @override
  Stream<TunnelEndpoint> get tunnels => _tunnels.stream;

  void start() {
    _runner = Future<void>.microtask(_run);
    unawaited(_runner);
  }

  Future<void> _run() async {
    var attempt = 0;
    while (!_closed) {
      _states.add(
        SessionState.connecting(
          attempt == 0 ? 'Connecting to host...' : 'Reconnecting to host...',
        ),
      );
      final ended = Completer<SessionState?>();
      void onEvent(JSString raw) {
        if (_closed) return;
        try {
          final event = jsonDecode(raw.toDart) as Map<String, Object?>;
          switch (event['type']) {
            case 'attached':
              final failure = _attachment.confirm();
              if (failure != null) {
                if (!ended.isCompleted) ended.complete(failure);
                return;
              }
              attempt = 0;
              _states.add(const SessionState.attached());
            case 'data':
              final failure = _attachment.acceptData();
              if (failure != null) {
                if (!ended.isCompleted) ended.complete(failure);
                return;
              }
              _output.add(
                Uint8List.fromList(
                  (event['bytes']! as List<Object?>).cast<int>(),
                ),
              );
            case 'error':
              if (!ended.isCompleted) {
                final code = (event['code'] as num?)?.toInt() ?? 0;
                final message = event['message'] as String?;
                ended.complete(sessionFailureState(code, message));
              }
            case 'closed':
              if (!ended.isCompleted) {
                final error = event['error'] as String?;
                ended.complete(
                  error == null ? const SessionState.ended() : null,
                );
              }
          }
        } catch (_) {
          if (!ended.isCompleted) {
            ended.complete(
              const SessionState.failed(
                'Protocol error: received an invalid session event.',
              ),
            );
          }
        }
      }

      try {
        _session = await _connect(
          _client,
          _host.ticket.toJS,
          _clientKey.toJS,
          _geometry.cols.toJS,
          _geometry.rows.toJS,
          _geometry.pixelWidth.toJS,
          _geometry.pixelHeight.toJS,
          onEvent.toJS,
        ).toDart;
        final result = await Future.any<SessionState?>([
          ended.future,
          _closedSignal.future.then((_) => const SessionState.ended()),
        ]);
        if (_closed) return;
        if (result != null) {
          _states.add(result);
          return;
        }
      } catch (error) {
        if (_closed) return;
      } finally {
        final session = _session;
        _session = null;
        _attachment.reset();
        if (session != null) _close(session);
      }
      final delay = sessionRetryDelay(attempt);
      attempt++;
      _states.add(
        SessionState.retrying(
          'Connection lost. Retrying in ${delay.inSeconds}s...',
        ),
      );
      await Future.any<void>([
        Future<void>.delayed(delay),
        _closedSignal.future,
      ]);
    }
  }

  @override
  Future<void> send(List<int> bytes) async {
    final session = _session;
    if (!_attachment.attached || session == null) return;
    for (var offset = 0; offset < bytes.length; offset += 0xffff) {
      final end = (offset + 0xffff).clamp(0, bytes.length);
      final payload = Uint8List.fromList(bytes.sublist(offset, end));
      final completed = _writer.enqueue(payload.length, () async {
        if (!_closed && identical(_session, session) && _attachment.attached) {
          await _send(session, payload.toJS).toDart;
        }
      });
      if (completed == null || !await completed) {
        if (identical(_session, session)) _close(session);
        return;
      }
    }
  }

  @override
  Future<void> resize(TerminalGeometry geometry) async {
    _geometry = geometry;
    final session = _session;
    if (!_attachment.attached || session == null) return;
    final completed = _writer.enqueue(8, () async {
      if (!_closed && identical(_session, session) && _attachment.attached) {
        await _resize(
          session,
          geometry.cols.toJS,
          geometry.rows.toJS,
          geometry.pixelWidth.toJS,
          geometry.pixelHeight.toJS,
        ).toDart;
      }
    });
    if (completed == null || !await completed) {
      if (identical(_session, session)) _close(session);
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _closedSignal.complete();
    _attachment.reset();
    _writer.close();
    final session = _session;
    _session = null;
    if (session != null) _close(session);
    await _writer.drain();
    await _runner?.catchError((_) {});
    await _output.close();
    await _states.close();
    await _tunnels.close();
  }
}
