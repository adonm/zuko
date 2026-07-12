import 'package:flutter/material.dart';

import 'app.dart';
import 'app_controller.dart';
import 'storage.dart';
import 'theme.dart';

typedef AppControllerLoader = Future<AppController> Function();

class ZukoBootstrap extends StatefulWidget {
  const ZukoBootstrap({super.key}) : loader = AppController.create;

  @visibleForTesting
  const ZukoBootstrap.withLoader(this.loader, {super.key});

  final AppControllerLoader loader;

  @override
  State<ZukoBootstrap> createState() => _ZukoBootstrapState();
}

class _ZukoBootstrapState extends State<ZukoBootstrap> {
  late Future<AppController> _controller;

  @override
  void initState() {
    super.initState();
    _controller = _loadController();
  }

  Future<AppController> _loadController() {
    final controller = Future.sync(widget.loader);
    controller.ignore();
    return controller;
  }

  void _retry() {
    final controller = _loadController();
    setState(() {
      _controller = controller;
    });
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<AppController>(
    future: _controller,
    builder: (context, snapshot) {
      final controller = snapshot.data;
      if (controller != null) return ZukoApp(controller: controller);
      return MaterialApp(
        title: 'Zuko',
        debugShowCheckedModeBanner: false,
        theme: buildZukoTheme(Brightness.light),
        darkTheme: buildZukoTheme(Brightness.dark),
        home: Scaffold(
          body: Center(
            child: snapshot.hasError
                ? _StartupFailure(error: snapshot.error!, onRetry: _retry)
                : const CircularProgressIndicator(),
          ),
        ),
      );
    },
  );
}

class _StartupFailure extends StatelessWidget {
  const _StartupFailure({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final locked = error is KeyringLockedException;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lock_outline, size: 48),
            const SizedBox(height: 16),
            Text(
              locked
                  ? 'Unlock your desktop keyring'
                  : 'Secure storage unavailable',
              style: Theme.of(context).textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Text(
              locked
                  ? "Zuko's encrypted client identity and saved hosts are in "
                        'your login keyring. Unlock it, then retry. No data was changed.'
                  : 'Zuko could not open its encrypted client state. Check your '
                        'desktop Secret Service, then retry.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}
