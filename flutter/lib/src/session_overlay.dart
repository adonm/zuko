import 'package:flutter/material.dart';
import 'package:zuko/src/session_state.dart';

class SessionOverlay extends StatefulWidget {
  const SessionOverlay({
    super.key,
    required this.state,
    required this.hasHost,
    required this.onReconnect,
    required this.onPair,
    required this.onDisconnect,
  });

  final SessionState state;
  final bool hasHost;
  final VoidCallback? onReconnect;
  final VoidCallback onPair;
  final VoidCallback? onDisconnect;

  @override
  State<SessionOverlay> createState() => _SessionOverlayState();
}

class _SessionOverlayState extends State<SessionOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _countdown = AnimationController(vsync: this);
  bool _countingDown = false;

  @override
  void initState() {
    super.initState();
    _syncCountdown();
  }

  @override
  void didUpdateWidget(SessionOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state.retryAfter != widget.state.retryAfter ||
        oldWidget.state.phase != widget.state.phase) {
      _syncCountdown();
    }
  }

  void _syncCountdown() {
    final retrying = widget.state.phase == SessionPhase.retrying;
    final after = retrying ? widget.state.retryAfter : null;
    _countdown.stop();
    _countdown.removeStatusListener(_onCountdownStatus);
    _countdown.removeListener(_onCountdownTick);
    _countingDown = false;
    if (after == null || after <= Duration.zero) return;
    _countdown
      ..duration = after
      ..value = 1.0;
    _countingDown = true;
    _countdown
      ..addListener(_onCountdownTick)
      ..addStatusListener(_onCountdownStatus)
      ..reverse();
  }

  void _onCountdownTick() {
    if (mounted) setState(() {});
  }

  void _onCountdownStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && mounted) {
      setState(() => _countingDown = false);
    }
  }

  @override
  void dispose() {
    _countdown.removeStatusListener(_onCountdownStatus);
    _countdown.removeListener(_onCountdownTick);
    _countdown.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final after = state.retryAfter;
    final secondsRemaining = _countingDown && after != null
        ? ((_countdown.value * after.inMilliseconds) / 1000).ceil().clamp(
            1,
            after.inSeconds,
          )
        : null;
    return FocusTraversalGroup(
      child: ColoredBox(
        color: Theme.of(context).colorScheme.scrim.withValues(alpha: 0.62),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Card(
              margin: const EdgeInsets.all(24),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // The retry countdown ring is the only animated progress
                    // indicator: an indeterminate spinner would keep the
                    // frame pipeline scheduled forever, which stalls widget
                    // tests and burns a frame every vsync on device.
                    if (_countingDown && secondsRemaining != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        // The countdown is visual feedback only; excluding it
                        // keeps the live region message announced verbatim.
                        child: ExcludeSemantics(
                          child: _RetryRing(
                            progress: 1.0 - _countdown.value,
                            seconds: secondsRemaining,
                          ),
                        ),
                      ),
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        state.message,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      alignment: WrapAlignment.center,
                      children: [
                        if (state.recovery == SessionRecovery.reconnect &&
                            widget.onReconnect != null)
                          _RecoveryAction(
                            key: ValueKey(state.recovery),
                            onPressed: widget.onReconnect!,
                            icon: const Icon(Icons.refresh),
                            child: Text(
                              state.phase == SessionPhase.retrying
                                  ? 'Retry now'
                                  : 'Reconnect',
                            ),
                          ),
                        if (state.recovery == SessionRecovery.rePair ||
                            !widget.hasHost)
                          _RecoveryAction(
                            key: ValueKey(state.recovery),
                            onPressed: widget.onPair,
                            icon: const Icon(Icons.add_link),
                            child: Text(
                              widget.hasHost ? 'Pair again' : 'Pair host',
                            ),
                          ),
                        if (widget.onDisconnect != null)
                          OutlinedButton.icon(
                            onPressed: widget.onDisconnect,
                            icon: const Icon(Icons.link_off),
                            label: const Text('Disconnect'),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Connection progress: an indeterminate spinner while connecting, or a
/// determinate countdown ring while waiting for an automatic retry.
class _RetryRing extends StatelessWidget {
  const _RetryRing({required this.progress, required this.seconds});

  final double progress;
  final int seconds;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 64,
    height: 64,
    child: Stack(
      alignment: Alignment.center,
      children: [
        CircularProgressIndicator(value: progress, strokeWidth: 4),
        Text('${seconds}s', style: Theme.of(context).textTheme.labelLarge),
      ],
    ),
  );
}

class _RecoveryAction extends StatefulWidget {
  const _RecoveryAction({
    super.key,
    required this.onPressed,
    required this.icon,
    required this.child,
  });

  final VoidCallback onPressed;
  final Widget icon;
  final Widget child;

  @override
  State<_RecoveryAction> createState() => _RecoveryActionState();
}

class _RecoveryActionState extends State<_RecoveryAction> {
  final _focusNode = FocusNode(debugLabel: 'Session recovery action');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) => FilledButton.icon(
    focusNode: _focusNode,
    onPressed: widget.onPressed,
    icon: widget.icon,
    label: widget.child,
  );

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }
}
