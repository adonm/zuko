import 'package:flutter_test/flutter_test.dart';
import 'package:zuko/src/session_state.dart';

void main() {
  test('session phases expose the intended recovery action', () {
    expect(const SessionState.attached().isAttached, isTrue);
    expect(const SessionState.rejected().recovery, SessionRecovery.rePair);
    expect(
      const SessionState.failed('bad protocol').recovery,
      SessionRecovery.reconnect,
    );
    expect(const SessionState.ended().recovery, SessionRecovery.reconnect);
  });

  test('retry delay backs off and caps at fifteen seconds', () {
    expect(
      List.generate(7, (attempt) => sessionRetryDelay(attempt).inSeconds),
      [1, 2, 4, 8, 15, 15, 15],
    );
    expect(sessionRetryDelay(-1), const Duration(seconds: 1));
  });

  test('authorization and protocol errors have distinct recovery', () {
    final rejected = sessionFailureState(0x01, 'access revoked');
    expect(rejected.phase, SessionPhase.rejected);
    expect(rejected.message, 'access revoked');
    expect(rejected.recovery, SessionRecovery.rePair);

    final protocol = sessionFailureState(0x02, 'unexpected frame');
    expect(protocol.phase, SessionPhase.failed);
    expect(protocol.message, 'Protocol error: unexpected frame');
    expect(protocol.recovery, SessionRecovery.reconnect);
  });
}
