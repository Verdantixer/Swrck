import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/app_config.dart';

class HotshareSettings {
  const HotshareSettings({
    required this.name,
    required this.password,
    required this.port,
  });

  final String name;
  final String password;
  final int port;
}

class HotshareStatus {
  const HotshareStatus({
    this.state = 'stopped',
    this.message = 'Hotshare is off',
    this.ssid = '',
    this.password = '',
    this.host = '',
    this.port = HotshareService.autoPort,
    this.mode = 'proxy',
    this.clients = 0,
    this.bytes = 0,
  });

  factory HotshareStatus.fromMap(Map<String, dynamic> map) => HotshareStatus(
        state: map['state'] as String? ?? 'stopped',
        message: map['message'] as String? ?? '',
        ssid: map['ssid'] as String? ?? '',
        password: map['password'] as String? ?? '',
        host: map['host'] as String? ?? '',
        port: (map['port'] as num?)?.toInt() ?? HotshareService.autoPort,
        mode: map['mode'] as String? ?? 'proxy',
        clients: (map['clients'] as num?)?.toInt() ?? 0,
        bytes: (map['bytes'] as num?)?.toInt() ?? 0,
      );

  final String state;
  final String message;
  final String ssid;
  final String password;
  final String host;
  final int port;
  final String mode;
  final int clients;
  final int bytes;

  bool get isRunning => state == 'running';
  bool get isStarting => state == 'starting';
  bool get isActive => isRunning || isStarting;
}

class HotshareService {
  HotshareService({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('com.swock.vpn/channel');

  static const autoPort = 0;
  static const _nameKey = 'hotshare_name';
  static const _passwordKey = 'hotshare_password';
  static const _portKey = 'hotshare_proxy_port';
  static const _passwordAlphabet =
      'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789';

  final MethodChannel _channel;

  Future<HotshareSettings> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    var name = prefs.getString(_nameKey);
    var password = prefs.getString(_passwordKey);
    final port = _validPort(prefs.getInt(_portKey));
    if (name == null || password == null) {
      name ??= '${AppConfig.appName}Spot';
      password ??= _generatePassword();
      await prefs.setString(_nameKey, name);
      await prefs.setString(_passwordKey, password);
      await prefs.setInt(_portKey, port);
    }
    return HotshareSettings(name: name, password: password, port: port);
  }

  Future<void> saveSettings(HotshareSettings settings) async {
    final name = settings.name.trim();
    if (name.isEmpty || utf8.encode(name).length > 22) {
      throw ArgumentError.value(
        settings.name,
        'name',
        'Must be 1-22 bytes.',
      );
    }
    if (settings.password.length < 8 || settings.password.length > 63) {
      throw ArgumentError.value(
        settings.password,
        'password',
        'Must be 8-63 characters.',
      );
    }
    if (settings.port != autoPort &&
        (settings.port < 1024 || settings.port > 65535)) {
      throw ArgumentError.value(
        settings.port,
        'port',
        'Must be blank for automatic selection or between 1024 and 65535.',
      );
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_nameKey, name);
    await prefs.setString(_passwordKey, settings.password);
    await prefs.setInt(_portKey, settings.port);
  }

  Future<bool> requestPermissions() async =>
      await _channel.invokeMethod<bool>('hotspotRequestPermissions') ?? false;

  Future<void> start({
    required HotshareSettings settings,
    bool direct = false,
  }) async {
    await saveSettings(settings);
    await _channel.invokeMethod<void>(
      'hotspotStart',
      <String, dynamic>{
        'name': settings.name.trim(),
        'password': settings.password,
        'port': settings.port,
        'mode': direct ? 'direct' : 'proxy',
      },
    );
  }

  Future<void> stop() => _channel.invokeMethod<void>('hotspotStop');

  Future<HotshareStatus> status() async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'hotspotStatus',
    );
    return result == null
        ? const HotshareStatus()
        : HotshareStatus.fromMap(result);
  }

  static int _validPort(int? value) {
    if (value == autoPort) return autoPort;
    return value != null && value >= 1024 && value <= 65535 ? value : autoPort;
  }

  static String _generatePassword() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => _passwordAlphabet[random.nextInt(_passwordAlphabet.length)],
    ).join();
  }
}
