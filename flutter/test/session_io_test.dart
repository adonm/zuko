import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zuko/src/session_io.dart';

void main() {
  test('attachment gate rejects early data and mismatched identities', () {
    final gate = SessionAttachmentGate();

    expect(gate.acceptData()!.message, contains('before attachment'));
    expect(gate.attached, isFalse);
    expect(
      gate
          .confirm(
            echoedIdentity: List.filled(16, 1),
            expectedIdentity: List.filled(16, 2),
          )!
          .message,
      contains('different identity'),
    );
    expect(gate.attached, isFalse);

    expect(
      gate.confirm(
        echoedIdentity: List.filled(16, 3),
        expectedIdentity: List.filled(16, 3),
      ),
      isNull,
    );
    expect(gate.attached, isTrue);
    expect(gate.acceptData(), isNull);
    expect(
      gate.confirm(
        echoedIdentity: List.filled(16, 4),
        expectedIdentity: List.filled(16, 5),
      ),
      isNotNull,
    );
    expect(gate.attached, isFalse);

    gate.reset();
    expect(gate.attached, isFalse);
    expect(gate.acceptData(), isNotNull);
  });

  test(
    'bounded writer serializes operations and enforces both limits',
    () async {
      final writer = BoundedSessionWriter(
        maxPendingWrites: 2,
        maxPendingBytes: 6,
      );
      final release = Completer<void>();
      final order = <String>[];

      final first = writer.enqueue(3, () async {
        order.add('first-start');
        await release.future;
        order.add('first-end');
      });
      final second = writer.enqueue(3, () async => order.add('second'));

      expect(first, isNotNull);
      expect(second, isNotNull);
      expect(writer.pendingWrites, 2);
      expect(writer.pendingBytes, 6);
      expect(writer.enqueue(0, () async {}), isNull);
      expect(writer.enqueue(1, () async {}), isNull);

      await Future<void>.delayed(Duration.zero);
      expect(order, ['first-start']);
      release.complete();

      expect(await first!, isTrue);
      expect(await second!, isTrue);
      await writer.drain();
      expect(order, ['first-start', 'first-end', 'second']);
      expect(writer.pendingWrites, 0);
      expect(writer.pendingBytes, 0);
    },
  );

  test(
    'bounded writer survives a long ordered session without retaining work',
    () async {
      final writer = BoundedSessionWriter();
      var completed = 0;

      for (var index = 0; index < 10000; index++) {
        final write = writer.enqueue(32, () async {
          expect(index, completed);
          completed++;
        });
        expect(write, isNotNull);
        expect(await write!, isTrue);
      }

      await writer.drain();
      expect(completed, 10000);
      expect(writer.pendingWrites, 0);
      expect(writer.pendingBytes, 0);
    },
  );

  test(
    'closing a writer cancels queued operations and rejects new work',
    () async {
      final writer = BoundedSessionWriter();
      final release = Completer<void>();
      var lateRuns = 0;
      final active = writer.enqueue(1, () => release.future);
      final queued = writer.enqueue(1, () async => lateRuns++);

      await Future<void>.delayed(Duration.zero);
      writer.close();
      expect(writer.enqueue(1, () async {}), isNull);
      release.complete();

      expect(await active!, isTrue);
      expect(await queued!, isFalse);
      await writer.drain();
      expect(lateRuns, 0);
    },
  );
}
