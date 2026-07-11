import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:iroh_flutter/iroh_flutter.dart';

import 'identity.dart';
import 'model.dart';
import 'pairing_code.dart';
import 'session_state.dart';
import 'ticket.dart';
import 'transport.dart';
import 'wire.dart';

Future<ClientTransport> createClientTransport(Uint8List clientKey) async {
  await Iroh.init();
  return _NativeTransport(clientKey);
}

final class _NativeTransport implements ClientTransport {
  _NativeTransport(Uint8List clientKey)
    : _clientKey = Uint8List.fromList(clientKey),
      _secretKey = SecretKey.fromBytes(clientKey);

  final Uint8List _clientKey;
  final SecretKey _secretKey;
  Endpoint? _endpoint;

  Future<Endpoint> _ready() async =>
      _endpoint ??= await Endpoint.bind(secretKey: _secretKey);

  @override
  Future<ClaimResult> claim(String rawCode, String clientLabel) async {
    final code = PairingCode.parse(rawCode);
    if (code == null) {
      throw const FormatException(
        'Enter the two-word code shown by zuko share.',
      );
    }
    final endpoint = await _ready();
    final seed = deriveHandoffKey(code);
    final address = EndpointAddr(SecretKey.fromBytes(seed).publicKey);
    Connection? connection;
    Object? lastError;
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    while (DateTime.now().isBefore(deadline)) {
      try {
        connection = await endpoint.connect(address, handoffAlpn);
        break;
      } catch (error) {
        lastError = error;
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
    if (connection == null) throw StateError('Pairing timed out: $lastError');

    try {
      final receive = await connection.acceptUni();
      final payload = utf8.decode(
        await receive.readToEnd(8 * 1024),
        allowMalformed: false,
      );
      final newline = payload.indexOf('\n');
      final label = (newline < 0
          ? 'host'
          : payload.substring(0, newline).trim());
      final ticketText =
          (newline < 0 ? payload : payload.substring(newline + 1)).trim();
      final ticket = EndpointTicket.parse(ticketText);
      final nodeId = ticket.address.id.toHex();
      final token = deriveSessionToken(_clientKey, ticket.address.id.asBytes());
      final send = await connection.openUni();
      await send.writeAll(encodeAuthorize(token, clientLabel));
      await send.finish();
      await Future.any<void>([
        connection.closed().then((_) {}),
        Future<void>.delayed(const Duration(seconds: 2)),
      ]);
      return ClaimResult(
        label: label.isEmpty ? 'host' : label,
        ticket: ticketText,
        nodeId: nodeId,
      );
    } finally {
      connection.close(reason: utf8.encode('claimed'));
    }
  }

  @override
  TerminalSession connect(SavedHost host, TerminalGeometry geometry) =>
      _NativeSession(_ready, _clientKey, host, geometry)..start();

  @override
  Future<void> close() async {
    final endpoint = _endpoint;
    _endpoint = null;
    await endpoint?.close();
  }
}

final class _NativeSession implements TerminalSession {
  _NativeSession(this._endpoint, this._clientKey, this._host, this._geometry);

  final Future<Endpoint> Function() _endpoint;
  final Uint8List _clientKey;
  final SavedHost _host;
  TerminalGeometry _geometry;
  final _output = StreamController<Uint8List>.broadcast(sync: true);
  final _states = StreamController<SessionState>.broadcast(sync: true);
  final _tunnels = StreamController<TunnelEndpoint>.broadcast(sync: true);
  final Map<String, _NativeTunnel> _activeTunnels = {};
  SendStream? _send;
  Connection? _connection;
  Future<void> _writeTail = Future.value();
  bool _attached = false;
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
      try {
        await _runOnce(onAttached: () => attempt = 0);
        if (!_closed) {
          await _closeAllTunnels();
          _states.add(const SessionState.ended());
        }
        return;
      } on _SessionFailure catch (error) {
        await _closeAllTunnels();
        _states.add(error.state);
        return;
      } catch (error) {
        if (_closed) return;
        final delay = sessionRetryDelay(attempt);
        _states.add(
          SessionState.retrying(
            'Connection lost. Retrying in ${delay.inSeconds}s...',
          ),
        );
        attempt++;
        await Future.any<void>([
          Future<void>.delayed(delay),
          _closedSignal.future,
        ]);
      }
    }
  }

  Future<void> _runOnce({required void Function() onAttached}) async {
    late final EndpointTicket ticket;
    try {
      ticket = EndpointTicket.parse(_host.ticket);
    } catch (_) {
      throw const _SessionFailure(
        SessionState.failed('The saved host ticket is invalid. Pair again.'),
      );
    }
    if (ticket.address.id.toHex() != _host.nodeId) {
      throw const _SessionFailure(
        SessionState.failed(
          'The saved host identity does not match its ticket. Pair again.',
        ),
      );
    }
    final token = deriveSessionToken(_clientKey, ticket.address.id.asBytes());
    final endpoint = await _endpoint();
    final connection = await endpoint.connect(ticket.address, sessionAlpn);
    _connection = connection;
    final (send, receive) = await connection.openBi();
    _send = send;
    _attached = false;
    await send.writeAll(encodeAttach(token, _geometry));
    final decoder = WireDecoder();
    try {
      while (!_closed) {
        final bytes = await receive.read(8192);
        if (bytes == null) return;
        for (final frame in decoder.add(bytes)) {
          switch (frame.type) {
            case WireType.data:
              if (!_attached) {
                throw const _SessionFailure(
                  SessionState.failed(
                    'Protocol error: host sent data before attachment.',
                  ),
                );
              }
              _output.add(frame.payload);
            case WireType.attached:
              if (frame.payload.length != 16 || !_equal(frame.payload, token)) {
                throw const _SessionFailure(
                  SessionState.failed(
                    'Protocol error: host confirmed a different identity.',
                  ),
                );
              }
              _attached = true;
              onAttached();
              _states.add(const SessionState.attached());
            case WireType.ping:
              await _write(encodePong(frame.payload));
            case WireType.error:
              final code = frame.payload.isEmpty ? 0 : frame.payload.first;
              final message = frame.payload.length <= 1
                  ? null
                  : utf8.decode(frame.payload.sublist(1), allowMalformed: true);
              throw _SessionFailure(sessionFailureState(code, message));
            case WireType.tunnelOffer:
              final offer = decodeTunnelOffer(frame.payload);
              if (_attached && offer != null) {
                unawaited(_openTunnel(endpoint, ticket.address, token, offer));
              }
            case WireType.tunnelClose:
              if (frame.payload.length == 16) {
                unawaited(_closeTunnel(_hex(frame.payload)));
              }
          }
        }
      }
    } finally {
      _attached = false;
      _send = null;
      _connection = null;
      connection.close(reason: utf8.encode('session ended'));
    }
  }

  Future<void> _write(List<int> bytes) {
    _writeTail = _writeTail.catchError((_) {}).then((_) async {
      final send = _send;
      if (!_closed && send != null) await send.writeAll(bytes);
    });
    return _writeTail;
  }

  Future<void> _openTunnel(
    Endpoint endpoint,
    EndpointAddr address,
    Uint8List token,
    ({Uint8List id, int port}) offer,
  ) async {
    final key = _hex(offer.id);
    final existing = _activeTunnels[key];
    if (existing != null && !existing.closed) return;
    await existing?.close();
    final tunnel = _NativeTunnel(
      endpoint: endpoint,
      address: address,
      token: token,
      id: offer.id,
      hostPort: offer.port,
    );
    _activeTunnels[key] = tunnel;
    try {
      final endpoint = await tunnel.start();
      if (!_closed && identical(_activeTunnels[key], tunnel)) {
        _tunnels.add(endpoint);
      } else {
        await tunnel.close();
      }
    } catch (_) {
      if (identical(_activeTunnels[key], tunnel)) {
        _activeTunnels.remove(key);
      }
      await tunnel.close();
    }
  }

  Future<void> _closeTunnel(String key) async {
    await _activeTunnels.remove(key)?.close();
  }

  Future<void> _closeAllTunnels() async {
    final tunnels = _activeTunnels.values.toList();
    _activeTunnels.clear();
    await Future.wait(tunnels.map((tunnel) => tunnel.close()));
  }

  @override
  Future<void> send(List<int> bytes) async {
    if (!_attached) return;
    try {
      for (final frame in encodeData(bytes)) {
        await _write(frame);
      }
    } catch (_) {
      _connection?.close(reason: utf8.encode('write failed'));
    }
  }

  @override
  Future<void> resize(TerminalGeometry geometry) async {
    _geometry = geometry;
    if (!_attached) return;
    try {
      await _write(encodeResize(geometry));
    } catch (_) {
      _connection?.close(reason: utf8.encode('resize failed'));
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _closedSignal.complete();
    _attached = false;
    _connection?.close(reason: utf8.encode('client disconnected'));
    await _writeTail.catchError((_) {});
    await _runner?.catchError((_) {});
    await _closeAllTunnels();
    await _output.close();
    await _states.close();
    await _tunnels.close();
  }
}

final class _NativeTunnel {
  _NativeTunnel({
    required this.endpoint,
    required this.address,
    required this.token,
    required this.id,
    required this.hostPort,
  });

  final Endpoint endpoint;
  final EndpointAddr address;
  final Uint8List token;
  final Uint8List id;
  final int hostPort;
  Connection? _connection;
  ServerSocket? _listener;
  final Set<Socket> _sockets = {};
  final Set<Future<void>> _proxies = {};
  Future<void>? _closing;
  bool closed = false;

  Future<TunnelEndpoint> start() async {
    final connection = await endpoint.connect(address, tunnelAlpn);
    if (closed) {
      connection.close(reason: utf8.encode('tunnel cancelled'));
      throw StateError('Tunnel was cancelled during setup.');
    }
    _connection = connection;
    final (send, receive) = await connection.openBi();
    await send.writeAll(encodeTunnelAttach(token, id));
    await send.finish();

    final decoder = WireDecoder();
    while (true) {
      final bytes = await receive.read(1024);
      if (bytes == null) throw StateError('Tunnel closed during setup.');
      for (final frame in decoder.add(bytes)) {
        if (frame.type == WireType.tunnelAttached &&
            frame.payload.length == 16 &&
            _equal(frame.payload, id)) {
          if (closed) throw StateError('Tunnel was cancelled during setup.');
          final listener = await ServerSocket.bind(
            InternetAddress.loopbackIPv4,
            0,
            shared: false,
          );
          if (closed) {
            await listener.close();
            throw StateError('Tunnel was cancelled during setup.');
          }
          _listener = listener;
          unawaited(_accept(listener, connection));
          unawaited(connection.closed().then((_) => close()));
          return TunnelEndpoint(
            id: _hex(id),
            hostPort: hostPort,
            localPort: listener.port,
          );
        }
        if (frame.type == WireType.error) {
          final message = frame.payload.length <= 1
              ? 'Tunnel rejected.'
              : utf8.decode(frame.payload.sublist(1), allowMalformed: true);
          throw StateError(message);
        }
      }
    }
  }

  Future<void> _accept(ServerSocket listener, Connection connection) async {
    try {
      await for (final socket in listener) {
        if (closed) {
          socket.destroy();
          break;
        }
        _sockets.add(socket);
        late final Future<void> proxy;
        proxy = _proxy(socket, connection).whenComplete(() {
          _sockets.remove(socket);
          _proxies.remove(proxy);
        });
        _proxies.add(proxy);
        unawaited(proxy);
      }
    } catch (_) {
      if (!closed) await close();
    }
  }

  Future<void> _proxy(Socket socket, Connection connection) async {
    try {
      final (send, receive) = await connection.openBi();
      Future<void> upload() async {
        await for (final bytes in socket) {
          await send.writeAll(bytes);
        }
        await send.finish();
      }

      Future<void> download() async {
        while (true) {
          final bytes = await receive.read(16 * 1024);
          if (bytes == null) break;
          socket.add(bytes);
          await socket.flush();
        }
        // Dart Socket.close() closes the IOSink/send half; the input stream
        // remains readable until upload completes, preserving TCP half-close.
        await socket.close();
      }

      await Future.wait([upload(), download()]);
    } catch (_) {
      socket.destroy();
    } finally {
      socket.destroy();
    }
  }

  Future<void> close() {
    closed = true;
    return _closing ??= _close();
  }

  Future<void> _close() async {
    await _listener?.close();
    _listener = null;
    final sockets = _sockets.toList();
    _sockets.clear();
    for (final socket in sockets) {
      socket.destroy();
    }
    _connection?.close(reason: utf8.encode('tunnel stopped'));
    _connection = null;
    final proxies = _proxies.toList();
    if (proxies.isNotEmpty) {
      await Future.wait(
        proxies,
      ).timeout(const Duration(seconds: 2), onTimeout: () => const <void>[]);
    }
  }
}

bool _equal(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  var difference = 0;
  for (var index = 0; index < left.length; index++) {
    difference |= left[index] ^ right[index];
  }
  return difference == 0;
}

String _hex(List<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

final class _SessionFailure implements Exception {
  const _SessionFailure(this.state);
  final SessionState state;
}
