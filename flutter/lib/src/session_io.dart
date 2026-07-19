import 'dart:async';

import 'session_state.dart';

const maxPendingSessionWrites = 128;
const maxPendingSessionWriteBytes = 1024 * 1024;

final class SessionAttachmentGate {
  bool _attached = false;

  bool get attached => _attached;

  SessionState? confirm({
    List<int>? echoedIdentity,
    List<int>? expectedIdentity,
  }) {
    if ((echoedIdentity == null) != (expectedIdentity == null) ||
        (echoedIdentity != null &&
            !_sameBytes(echoedIdentity, expectedIdentity!))) {
      _attached = false;
      return const SessionState.failed(
        'Protocol error: host confirmed a different identity.',
      );
    }
    _attached = true;
    return null;
  }

  SessionState? acceptData() => _attached
      ? null
      : const SessionState.failed(
          'Protocol error: host sent data before attachment.',
        );

  void reset() {
    _attached = false;
  }
}

final class BoundedSessionWriter {
  BoundedSessionWriter({
    this.maxPendingWrites = maxPendingSessionWrites,
    this.maxPendingBytes = maxPendingSessionWriteBytes,
  }) : assert(maxPendingWrites > 0),
       assert(maxPendingBytes > 0);

  final int maxPendingWrites;
  final int maxPendingBytes;
  Future<void> _tail = Future<void>.value();
  int _pendingWrites = 0;
  int _pendingBytes = 0;
  bool _closed = false;

  int get pendingWrites => _pendingWrites;
  int get pendingBytes => _pendingBytes;

  Future<bool>? enqueue(int byteCount, Future<void> Function() operation) {
    if (_closed ||
        byteCount < 0 ||
        byteCount > maxPendingBytes ||
        _pendingWrites >= maxPendingWrites ||
        _pendingBytes > maxPendingBytes - byteCount) {
      return null;
    }

    _pendingWrites++;
    _pendingBytes += byteCount;
    final result = Completer<bool>();
    _tail = _tail
        .then((_) async {
          if (_closed) {
            result.complete(false);
            return;
          }
          try {
            await operation();
            result.complete(true);
          } on Object {
            result.complete(false);
          }
        })
        .whenComplete(() {
          _pendingWrites--;
          _pendingBytes -= byteCount;
        });
    return result.future;
  }

  void close() {
    _closed = true;
  }

  Future<void> drain() => _tail;
}

bool _sameBytes(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  var difference = 0;
  for (var index = 0; index < left.length; index++) {
    difference |= left[index] ^ right[index];
  }
  return difference == 0;
}
