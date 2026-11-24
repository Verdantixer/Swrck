import 'dart:convert';

import 'package:flutter/services.dart';

import '../models/vpn_profile.dart';
import 'advanced_settings_service.dart';

class NativeVpnService {
  NativeVpnService({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('com.swock.vpn/channel');

  final MethodChannel _channel;

  Future<bool> connect(VpnProfile profile) async {
    final advanced = await AdvancedSettingsService().load();
    return await _channel.invokeMethod<bool>('connect', <String, dynamic>{
          'profile': jsonEncode({
            ...profile.toJson(),
            'advanced': advanced.toJson(),
          }),
        }) ??
        false;
  }

  Future<void> disconnect() => _channel.invokeMethod<void>('disconnect');

  Future<Map<String, dynamic>> getStatus() async {
    final result = await _channel.invokeMapMethod<String, dynamic>('getStatus');
    return result ??
        <String, dynamic>{'state': 'disconnected', 'connected': false};
  }

  Future<Map<String, dynamic>> getStatistics() async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'getStatistics',
    );
    return result ?? <String, dynamic>{};
  }

  Future<List<Map<String, dynamic>>> drainVpnLogs() async {
    final events = await _channel.invokeListMethod<dynamic>('drainVpnLogs');
    return (events ?? const <dynamic>[])
        .map((event) => Map<String, dynamic>.from(event as Map))
        .toList();
  }

  Future<void> clearVpnLogs() => _channel.invokeMethod<void>('clearVpnLogs');

  Future<bool> openExternalUrl(String url) async =>
      await _channel.invokeMethod<bool>('openExternalUrl', {'url': url}) ??
      false;

  Future<String?> getImportUri() =>
      _channel.invokeMethod<String>('getImportUri');

  Future<String?> importProfileFile() =>
      _channel.invokeMethod<String>('importProfileFile');

  Future<bool> exportDvsFile({
    required String fileName,
    required String contents,
  }) async =>
      await _channel.invokeMethod<bool>('exportDvsFile', {
        'fileName': fileName,
        'contents': contents,
      }) ??
      false;
}
