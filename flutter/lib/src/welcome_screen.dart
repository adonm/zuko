import 'package:flutter/material.dart';
import 'package:yaru/yaru.dart';

import 'package:flutter/services.dart'
    show Clipboard, ClipboardData, PlatformException;

const _installCommand =
    'distrobox enter zuko -- zsh -lc "curl -fsSL https://zuko.sh | sh"';
const _shareCommand = 'zuko install\nzuko share';

class NoOpenConnections extends StatelessWidget {
  const NoOpenConnections({super.key, required this.onPair});

  final VoidCallback onPair;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            YaruIcons.terminal,
            size: 48,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 12),
          Text(
            'No open connections',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 6),
          const Text(
            'Choose a saved host to open a terminal. Open hosts stay connected in separate tabs.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: onPair,
            icon: const Icon(Icons.add_link),
            label: const Text('Pair another host'),
          ),
        ],
      ),
    ),
  );
}

class Welcome extends StatelessWidget {
  const Welcome({super.key, required this.onScan, required this.onEnterCode});

  final VoidCallback? onScan;
  final VoidCallback onEnterCode;

  Future<void> _copy(BuildContext context, String value) async {
    try {
      await Clipboard.setData(ClipboardData(text: value));
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Copied command')));
    } on PlatformException {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: Text('Clipboard access was denied')),
        );
    }
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.all(24),
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: Column(
          children: [
            Image.asset('assets/zuko-logo.png', width: 64, height: 64),
            const SizedBox(height: 16),
            Text(
              'Connect to your host',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Set up Zuko on the computer you want to reach, then pair it once.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 24),
            _WelcomeStep(
              number: 1,
              title: 'Install Zuko on the host',
              command: _installCommand,
              onCopy: (value) => _copy(context, value),
            ),
            const SizedBox(height: 12),
            _WelcomeStep(
              number: 2,
              title: 'Start it and create a one-time share code',
              command: _shareCommand,
              onCopy: (value) => _copy(context, value),
            ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                if (onScan != null)
                  FilledButton.icon(
                    onPressed: onScan,
                    icon: const Icon(Icons.qr_code_scanner),
                    label: const Text('Scan QR code'),
                  )
                else
                  FilledButton.icon(
                    onPressed: onEnterCode,
                    icon: const Icon(Icons.keyboard_outlined),
                    label: const Text('Enter pairing code'),
                  ),
                if (onScan != null)
                  OutlinedButton.icon(
                    onPressed: onEnterCode,
                    icon: const Icon(Icons.keyboard_outlined),
                    label: const Text('Enter code instead'),
                  ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

class _WelcomeStep extends StatelessWidget {
  const _WelcomeStep({
    required this.number,
    required this.title,
    required this.command,
    required this.onCopy,
  });

  final int number;
  final String title;
  final String command;
  final ValueChanged<String> onCopy;

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 14,
            backgroundColor: Theme.of(context).colorScheme.primaryContainer,
            foregroundColor: Theme.of(context).colorScheme.onPrimaryContainer,
            child: Text('$number'),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 6),
                _Command(command: command, onCopy: onCopy),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _Command extends StatelessWidget {
  const _Command({required this.command, required this.onCopy});
  final String command;
  final ValueChanged<String> onCopy;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        child: Text(
          command,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
        ),
      ),
      IconButton(
        visualDensity: VisualDensity.compact,
        tooltip: 'Copy command',
        onPressed: () => onCopy(command),
        icon: Icon(YaruFreedesktopIcons.edit_copy.icon, size: 18),
      ),
    ],
  );
}
