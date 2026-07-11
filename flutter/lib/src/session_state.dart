enum SessionPhase { connecting, attached, retrying, ended, rejected, failed }

enum SessionRecovery { none, reconnect, rePair }

final class SessionState {
  const SessionState({
    required this.phase,
    required this.message,
    this.recovery = SessionRecovery.none,
  });

  const SessionState.connecting([this.message = 'Connecting to host...'])
    : phase = SessionPhase.connecting,
      recovery = SessionRecovery.none;

  const SessionState.attached([this.message = 'Attached'])
    : phase = SessionPhase.attached,
      recovery = SessionRecovery.none;

  const SessionState.retrying(this.message)
    : phase = SessionPhase.retrying,
      recovery = SessionRecovery.reconnect;

  const SessionState.ended([this.message = 'Session ended.'])
    : phase = SessionPhase.ended,
      recovery = SessionRecovery.reconnect;

  const SessionState.rejected([
    this.message = 'This client is no longer authorized. Pair it again.',
  ]) : phase = SessionPhase.rejected,
       recovery = SessionRecovery.rePair;

  const SessionState.failed(this.message)
    : phase = SessionPhase.failed,
      recovery = SessionRecovery.reconnect;

  final SessionPhase phase;
  final String message;
  final SessionRecovery recovery;

  bool get isAttached => phase == SessionPhase.attached;
}

const sessionRetryDelays = <Duration>[
  Duration(seconds: 1),
  Duration(seconds: 2),
  Duration(seconds: 4),
  Duration(seconds: 8),
  Duration(seconds: 15),
];

Duration sessionRetryDelay(int attempt) =>
    sessionRetryDelays[attempt.clamp(0, sessionRetryDelays.length - 1)];

SessionState sessionFailureState(int code, String? message) {
  if (code == 0x01) {
    return SessionState.rejected(
      message?.isNotEmpty == true
          ? message!
          : 'This client is not authorized. Pair it again.',
    );
  }
  return SessionState.failed(
    message?.isNotEmpty == true
        ? 'Protocol error: $message'
        : 'The host reported a protocol error.',
  );
}
