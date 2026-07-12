import 'package:flutter_test/flutter_test.dart';
import 'package:zuko/src/app_controller.dart';
import 'package:zuko/src/bootstrap.dart';
import 'package:zuko/src/storage.dart';

void main() {
  testWidgets('locked keyring shows an actionable retry screen', (
    tester,
  ) async {
    var attempts = 0;
    Future<AppController> load() async {
      attempts++;
      throw const KeyringLockedException();
    }

    await tester.pumpWidget(ZukoBootstrap.withLoader(load));
    await tester.pump();

    expect(find.text('Unlock your desktop keyring'), findsOneWidget);
    expect(find.textContaining('No data was changed.'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(attempts, 1);

    await tester.tap(find.text('Retry'));
    await tester.pump();
    await tester.pump();

    expect(find.text('Unlock your desktop keyring'), findsOneWidget);
    expect(attempts, 2);
  });
}
