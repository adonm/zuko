import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zuko/src/model.dart';
import 'package:zuko/src/pairing_screen.dart';
import 'package:zuko/src/pairing_scanner.dart';

const _host = SavedHost(
  name: 'workstation',
  label: 'workstation',
  ticket: 'ticket',
  nodeId: 'node',
);

void main() {
  test('pairing errors are actionable and do not expose raw details', () {
    expect(
      pairingClaimErrorMessage(StateError('Pairing timed out: relay secret')),
      'Could not reach the host. Check that zuko share is still running.',
    );
    expect(
      pairingClaimErrorMessage(const FormatException('broken ticket bytes')),
      'The host returned invalid pairing information.',
    );
    expect(
      pairingClaimErrorMessage(StateError('socket contained secret detail')),
      'Could not pair with that host. Check the code and try again.',
    );
  });

  test('scanner failures always direct users to typed fallback', () {
    expect(
      scannerErrorMessage(PairingScannerError.permissionDenied),
      contains('Enter the share code instead'),
    );
    expect(
      scannerErrorMessage(PairingScannerError.unsupported),
      contains('Enter the share code instead'),
    );
  });

  test('QR scanning is native-only on supported camera platforms', () {
    expect(
      supportsQrScanning(platform: TargetPlatform.android, isWeb: false),
      isTrue,
    );
    expect(
      supportsQrScanning(platform: TargetPlatform.iOS, isWeb: false),
      isTrue,
    );
    expect(
      supportsQrScanning(platform: TargetPlatform.macOS, isWeb: false),
      isTrue,
    );
    expect(
      supportsQrScanning(platform: TargetPlatform.linux, isWeb: false),
      isFalse,
    );
    expect(
      supportsQrScanning(platform: TargetPlatform.windows, isWeb: false),
      isFalse,
    );
    expect(
      supportsQrScanning(platform: TargetPlatform.linux, isWeb: true),
      isFalse,
    );
  });

  testWidgets('manual pairing asks only for a valid share code', (
    tester,
  ) async {
    String? claimedCode;
    await tester.pumpWidget(
      _PairingLauncher(
        screen: PairingScreen(
          scannerAvailable: false,
          onClaim: (code) async {
            claimedCode = code;
            return _host;
          },
        ),
      ),
    );

    await tester.tap(find.text('Open pairing'));
    await tester.pumpAndSettle();

    expect(find.text('Save as'), findsNothing);
    expect(find.text('Scan QR code'), findsNothing);
    expect(find.text('Share code'), findsOneWidget);

    await tester.enterText(find.byType(TextFormField), 'single');
    await tester.pump();
    var pair = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Pair'),
    );
    expect(pair.onPressed, isNull);

    await tester.enterText(find.byType(TextFormField), 'IRIDESCENT_hilton');
    await tester.pump();
    pair = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Pair'),
    );
    expect(pair.onPressed, isNotNull);

    await tester.tap(find.widgetWithText(FilledButton, 'Pair'));
    await tester.pumpAndSettle();

    expect(claimedCode, 'iridescent-hilton');
    expect(find.text('Paired workstation'), findsOneWidget);
  });

  testWidgets(
    'scanner ignores invalid QR values and claims the first valid one',
    (tester) async {
      var scannedValue = 'https://example.com/not-zuko';
      var claims = 0;
      await tester.pumpWidget(
        _PairingLauncher(
          screen: PairingScreen(
            scannerAvailable: true,
            scannerBuilder: (context, onDetect) => Center(
              child: FilledButton(
                onPressed: () => onDetect(scannedValue),
                child: const Text('Emit scan'),
              ),
            ),
            onClaim: (code) async {
              claims++;
              expect(code, 'iridescent-hilton');
              return _host;
            },
          ),
        ),
      );

      await tester.tap(find.text('Open pairing'));
      await tester.pumpAndSettle();
      expect(find.text('Enter code instead'), findsOneWidget);

      await tester.tap(find.text('Emit scan'));
      await tester.pump();
      expect(
        find.text('Not a Zuko pairing code. Keep scanning.'),
        findsOneWidget,
      );
      expect(claims, 0);

      scannedValue = 'iridescent-hilton';
      await tester.tap(find.text('Emit scan'));
      await tester.pumpAndSettle();

      expect(claims, 1);
      expect(find.text('Paired workstation'), findsOneWidget);
    },
  );

  testWidgets('failed scanned claim offers retry and typed fallback', (
    tester,
  ) async {
    await tester.pumpWidget(
      _PairingLauncher(
        screen: PairingScreen(
          scannerAvailable: true,
          scannerBuilder: (context, onDetect) => Center(
            child: FilledButton(
              onPressed: () => onDetect('iridescent-hilton'),
              child: const Text('Emit scan'),
            ),
          ),
          claimErrorMessage: (_) => 'That share code expired.',
          onClaim: (_) async => throw StateError('expired'),
        ),
      ),
    );

    await tester.tap(find.text('Open pairing'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Emit scan'));
    await tester.pump();

    expect(find.text('That share code expired.'), findsOneWidget);
    expect(find.text('Scan again'), findsOneWidget);
    expect(find.text('Enter code instead'), findsOneWidget);
  });

  testWidgets('pairing failures are exposed as live-region status', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        home: PairingScreen(
          startInManual: true,
          onClaim: (_) async => throw StateError('timed out'),
        ),
      ),
    );
    await tester.enterText(find.byType(TextFormField), 'iridescent-hilton');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Pair'));
    await tester.pump();
    await tester.pump();

    final node = tester.getSemantics(
      find.bySemanticsLabel(
        RegExp(
          'Could not reach the host. Check that zuko share is still running.',
        ),
      ),
    );
    expect(node.getSemanticsData().flagsCollection.isLiveRegion, isTrue);
    expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isFalse);
    semantics.dispose();
  });
}

class _PairingLauncher extends StatefulWidget {
  const _PairingLauncher({required this.screen});

  final PairingScreen screen;

  @override
  State<_PairingLauncher> createState() => _PairingLauncherState();
}

class _PairingLauncherState extends State<_PairingLauncher> {
  SavedHost? result;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => Column(
          children: [
            FilledButton(
              onPressed: () async {
                final host = await Navigator.of(context).push<SavedHost>(
                  MaterialPageRoute(builder: (context) => widget.screen),
                );
                if (mounted) setState(() => result = host);
              },
              child: const Text('Open pairing'),
            ),
            Text(result == null ? 'Not paired' : 'Paired ${result!.name}'),
          ],
        ),
      ),
    ),
  );
}
