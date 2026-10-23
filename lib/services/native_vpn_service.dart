import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../models/vpn_profile.dart';
import 'advanced_settings_service.dart';

class NativeVpnService {
  NativeVpnService({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('com.swock.vpn/channel');

  final MethodChannel _channel;

  bool get _isWindows => Platform.isWindows;

  String get _windowsCorePath =>
      '${File(Platform.resolvedExecutable).parent.path}\\swock_core.exe';

  Process? _windowsCoreServer;

  Future<void> _startWindowsCore() async {
    if (_windowsCoreServer != null) return;
    final core = File(_windowsCorePath);
    if (!await core.exists()) {
      throw PlatformException(
        code: 'windows_core_missing',
        message: 'The Swock VPN service is missing. Repair or reinstall Swock.',
      );
    }
    // Keep the Flutter UI unprivileged; elevate only the VPN service that
    // needs to create the Wintun adapter and configure system routes.
    final corePathBase64 = base64.encode(utf8.encode(_windowsCorePath));
    final powershellCommand =
        "Start-Process -FilePath ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$corePathBase64'))) "
        "-ArgumentList @('serve','$pid') -Verb RunAs -WindowStyle Hidden";
    final windir = Platform.environment['WINDIR'];
    final powershell = windir == null
        ? 'powershell.exe'
        : '$windir\\System32\\WindowsPowerShell\\v1.0\\powershell.exe';
    _windowsCoreServer = await Process.start(
      powershell,
      <String>['-NoProfile', '-NonInteractive', '-Command', powershellCommand],
      mode: ProcessStartMode.detached,
      runInShell: false,
    );
    for (var attempt = 0; attempt < 300; attempt++) {
      try {
        await _windowsRequest('status');
        return;
      } on PlatformException {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    _windowsCoreServer = null;
    throw PlatformException(
      code: 'windows_core_start_failed',
      message: 'The Swock VPN service did not start.',
    );
  }

  Future<dynamic> _windowsRequest(
    String command, {
    Object? profile,
  }) async {
    final request = <String, dynamic>{'command': command};
    if (profile != null) request['profile'] = profile;
    final process = await Process.start(
      _windowsCorePath,
      <String>['control'],
      runInShell: false,
    );
    process.stdin.encoding = utf8;
    process.stdin.write(jsonEncode(request));
    await process.stdin.close();
    final outputs = await Future.wait<String>(<Future<String>>[
      process.stdout.transform(utf8.decoder).join(),
      process.stderr.transform(utf8.decoder).join(),
    ]);
    final exitCode = await process.exitCode;
    if (exitCode != 0) {
      throw PlatformException(
        code: 'windows_vpn_core_error',
        message: outputs[1].trim().isNotEmpty
            ? outputs[1].trim()
            : 'The Swock VPN service is not available.',
      );
    }
    final response = jsonDecode(outputs[0]) as Map<String, dynamic>;
    if (response['ok'] != true) {
      throw PlatformException(
        code: 'windows_vpn_error',
        message: response['error'] as String? ?? 'The VPN command failed.',
      );
    }
    return response['value'];
  }

  Future<bool> connect(VpnProfile profile) async {
    final advanced = await AdvancedSettingsService().load();
    final payload = <String, dynamic>{
          'profile': jsonEncode({
            ...profile.toJson(),
            'advanced': advanced.toJson(),
          }),
        };
    if (_isWindows) {
      await _startWindowsCore();
      await _windowsRequest('connect', profile: payload['profile']);
      return true;
    }
    return await _channel.invokeMethod<bool>('connect', payload) ?? false;
  }

  Future<void> disconnect() async {
    if (_isWindows) {
      try {
        await _windowsRequest('disconnect');
      } on PlatformException {
        // The VPN service may already have stopped with the app.
      }
      return;
    }
    await _channel.invokeMethod<void>('disconnect');
  }

  Future<Map<String, dynamic>> getStatus() async {
    if (_isWindows) {
      try {
        return Map<String, dynamic>.from(
          await _windowsRequest('status') as Map,
        );
      } on PlatformException {
        return <String, dynamic>{
          'state': 'disconnected',
          'connected': false,
          'message': 'Disconnected',
        };
      }
    }
    final result = await _channel.invokeMapMethod<String, dynamic>('getStatus');
    return result ??
        <String, dynamic>{'state': 'disconnected', 'connected': false};
  }

  Future<Map<String, dynamic>> getStatistics() async {
    if (_isWindows) {
      try {
        return Map<String, dynamic>.from(
          await _windowsRequest('statistics') as Map,
        );
      } on PlatformException {
        return <String, dynamic>{};
      }
    }
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'getStatistics',
    );
    return result ?? <String, dynamic>{};
  }

  Future<List<Map<String, dynamic>>> drainVpnLogs() async {
    if (_isWindows) {
      try {
        final events = await _windowsRequest('drainLogs') as List? ?? const [];
        return events.map((event) => Map<String, dynamic>.from(event as Map)).toList();
      } on PlatformException {
        return <Map<String, dynamic>>[];
      }
    }
    final events = await _channel.invokeListMethod<dynamic>('drainVpnLogs');
    return (events ?? const <dynamic>[])
        .map((event) => Map<String, dynamic>.from(event as Map))
        .toList();
  }

  Future<void> clearVpnLogs() async {
    if (_isWindows) {
      try {
        await _windowsRequest('clearLogs');
      } on PlatformException {
        // No logs to clear if the core has not started.
      }
      return;
    }
    await _channel.invokeMethod<void>('clearVpnLogs');
  }

  Future<String?> getImportUri() => _isWindows
      ? Future<String?>.value(null)
      : _channel.invokeMethod<String>('getImportUri');
}

