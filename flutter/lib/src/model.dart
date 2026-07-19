import 'dart:convert';
import 'dart:typed_data';

final class SavedHost {
  const SavedHost({
    required this.name,
    required this.label,
    required this.ticket,
    required this.nodeId,
    this.authorizedClientLabel,
  });

  final String name;
  final String label;
  final String ticket;
  final String nodeId;
  final String? authorizedClientLabel;

  factory SavedHost.fromJson(Map<String, Object?> json) {
    final authorizedClientLabel = json['authorizedClientLabel'];
    if (authorizedClientLabel != null && authorizedClientLabel is! String) {
      throw const FormatException('invalid authorized client label');
    }
    return SavedHost(
      name: _requiredString(json, 'name', maxLength: 64),
      label: _requiredString(json, 'label', maxLength: 256),
      ticket: _requiredString(json, 'ticket', maxLength: 16384),
      nodeId: _requiredString(json, 'nodeId', maxLength: 256),
      authorizedClientLabel: authorizedClientLabel as String?,
    );
  }

  SavedHost copyWith({String? name}) => SavedHost(
    name: name ?? this.name,
    label: label,
    ticket: ticket,
    nodeId: nodeId,
    authorizedClientLabel: authorizedClientLabel,
  );

  Map<String, Object?> toJson() => {
    'name': name,
    'label': label,
    'ticket': ticket,
    'nodeId': nodeId,
    if (authorizedClientLabel != null)
      'authorizedClientLabel': authorizedClientLabel,
  };
}

enum AppThemePreference { system, dark, light }

enum AppInterfaceSize { compact, standard, comfortable }

final class ClientState {
  static const currentVersion = 6;

  ClientState({
    required Uint8List clientKey,
    required List<SavedHost> hosts,
    this.clientName,
    this.theme = AppThemePreference.system,
    this.interfaceSize = AppInterfaceSize.standard,
    double terminalFontSize = 10,
    this.terminalFontSizeCustomized = false,
    this.showAdditionalKeys = true,
  }) : clientKey = Uint8List.fromList(clientKey),
       hosts = List.unmodifiable(hosts),
       terminalFontSize = normalizeTerminalFontSize(terminalFontSize);

  final Uint8List clientKey;
  final List<SavedHost> hosts;
  final String? clientName;
  final AppThemePreference theme;
  final AppInterfaceSize interfaceSize;
  final double terminalFontSize;
  final bool terminalFontSizeCustomized;
  final bool showAdditionalKeys;

  factory ClientState.decode(String value) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is! Map<String, Object?>) {
        throw const FormatException('state must be an object');
      }
      final version = decoded['version'];
      if (version is! int || version < 1 || version > currentVersion) {
        throw const FormatException('unsupported state version');
      }
      final key = base64Decode(_requiredString(decoded, 'clientKey'));
      if (key.length != 32) {
        throw const FormatException('invalid client identity');
      }
      final hostValues = decoded['hosts'];
      if (hostValues is! List<Object?> || hostValues.length > 12) {
        throw const FormatException('invalid saved hosts');
      }
      final hosts = hostValues.map((item) {
        if (item is! Map<String, Object?>) {
          throw const FormatException('invalid saved host');
        }
        return SavedHost.fromJson(item);
      }).toList();
      final themeName = version >= 2 ? decoded['theme'] : null;
      if (themeName != null && themeName is! String) {
        throw const FormatException('invalid theme');
      }
      final theme = AppThemePreference.values
          .where((item) => item.name == themeName)
          .firstOrNull;
      final interfaceSizeName = version >= 6 ? decoded['interfaceSize'] : null;
      if (interfaceSizeName != null && interfaceSizeName is! String) {
        throw const FormatException('invalid interface size');
      }
      final interfaceSize = AppInterfaceSize.values
          .where((item) => item.name == interfaceSizeName)
          .firstOrNull;
      if (interfaceSizeName != null && interfaceSize == null) {
        throw const FormatException('invalid interface size');
      }
      final fontSize = version >= 2 ? decoded['terminalFontSize'] : null;
      if (fontSize != null && fontSize is! num) {
        throw const FormatException('invalid terminal font size');
      }
      final fontSizeCustomized = version >= 4
          ? decoded['terminalFontSizeCustomized']
          : fontSize != null && fontSize != 14;
      if (fontSizeCustomized is! bool) {
        throw const FormatException('invalid terminal font size preference');
      }
      final showAdditionalKeys = version >= 3
          ? decoded['showAdditionalKeys']
          : true;
      if (showAdditionalKeys is! bool) {
        throw const FormatException('invalid additional keys preference');
      }
      final clientName = version >= 5 ? decoded['clientName'] : null;
      if (clientName != null &&
          (clientName is! String ||
              clientName.isEmpty ||
              clientName.length > 64)) {
        throw const FormatException('invalid client name');
      }
      return ClientState(
        clientKey: key,
        hosts: hosts,
        clientName: clientName as String?,
        theme: theme ?? AppThemePreference.system,
        interfaceSize: interfaceSize ?? AppInterfaceSize.standard,
        terminalFontSize: (fontSize as num?)?.toDouble() ?? 10,
        terminalFontSizeCustomized: fontSizeCustomized,
        showAdditionalKeys: showAdditionalKeys,
      );
    } on FormatException {
      rethrow;
    } on Object {
      throw const FormatException('malformed client state');
    }
  }

  ClientState copyWith({
    List<SavedHost>? hosts,
    String? clientName,
    AppThemePreference? theme,
    AppInterfaceSize? interfaceSize,
    double? terminalFontSize,
    bool? terminalFontSizeCustomized,
    bool? showAdditionalKeys,
  }) => ClientState(
    clientKey: clientKey,
    hosts: hosts ?? this.hosts,
    clientName: clientName ?? this.clientName,
    theme: theme ?? this.theme,
    interfaceSize: interfaceSize ?? this.interfaceSize,
    terminalFontSize: terminalFontSize ?? this.terminalFontSize,
    terminalFontSizeCustomized:
        terminalFontSizeCustomized ?? this.terminalFontSizeCustomized,
    showAdditionalKeys: showAdditionalKeys ?? this.showAdditionalKeys,
  );

  String encode() => jsonEncode({
    'version': currentVersion,
    'clientKey': base64Encode(clientKey),
    'hosts': hosts.map((host) => host.toJson()).toList(),
    if (clientName != null) 'clientName': clientName,
    'theme': theme.name,
    'interfaceSize': interfaceSize.name,
    'terminalFontSize': terminalFontSize,
    'terminalFontSizeCustomized': terminalFontSizeCustomized,
    'showAdditionalKeys': showAdditionalKeys,
  });
}

String _requiredString(
  Map<String, Object?> json,
  String key, {
  int maxLength = 32768,
}) {
  final value = json[key];
  if (value is! String || value.isEmpty || value.length > maxLength) {
    throw FormatException('invalid $key');
  }
  return value;
}

double normalizeTerminalFontSize(double value) {
  if (!value.isFinite) return 10;
  return value.clamp(5, 20).toDouble();
}
