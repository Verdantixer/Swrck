import 'package:shared_preferences/shared_preferences.dart';

class AdvancedSettings {
  const AdvancedSettings({
    this.callStability = false,
    this.udpGatewayEnabled = false,
    this.udpGatewayPort = 7200,
    this.ipv6Enabled = true,
  });

  final bool callStability;
  final bool udpGatewayEnabled;
  final int udpGatewayPort;
  final bool ipv6Enabled;

  AdvancedSettings copyWith({
    bool? callStability,
    bool? udpGatewayEnabled,
    int? udpGatewayPort,
    bool? ipv6Enabled,
  }) =>
      AdvancedSettings(
        callStability: callStability ?? this.callStability,
        udpGatewayEnabled: udpGatewayEnabled ?? this.udpGatewayEnabled,
        udpGatewayPort: udpGatewayPort ?? this.udpGatewayPort,
        ipv6Enabled: ipv6Enabled ?? this.ipv6Enabled,
      );

  Map<String, dynamic> toJson() => {
        'callStability': callStability,
        'udpGatewayEnabled': udpGatewayEnabled,
        'udpGatewayPort': udpGatewayPort,
        'ipv6Enabled': ipv6Enabled,
      };
}

class AdvancedSettingsService {
  static const _callStabilityKey = 'advanced_call_stability';
  static const _udpGatewayEnabledKey = 'advanced_udp_gateway_enabled';
  static const _udpGatewayPortKey = 'advanced_udp_gateway_port';
  static const _ipv6EnabledKey = 'advanced_ipv6_enabled';

  Future<AdvancedSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    return AdvancedSettings(
      callStability: prefs.getBool(_callStabilityKey) ?? false,
      udpGatewayEnabled: prefs.getBool(_udpGatewayEnabledKey) ?? false,
      udpGatewayPort: _validPort(prefs.getInt(_udpGatewayPortKey)),
      ipv6Enabled: prefs.getBool(_ipv6EnabledKey) ?? true,
    );
  }

  Future<void> save(AdvancedSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_callStabilityKey, settings.callStability);
    await prefs.setBool(_udpGatewayEnabledKey, settings.udpGatewayEnabled);
    await prefs.setInt(_udpGatewayPortKey, _validPort(settings.udpGatewayPort));
    await prefs.setBool(_ipv6EnabledKey, settings.ipv6Enabled);
  }

  static int _validPort(int? value) =>
      value != null && value >= 1 && value <= 65535 ? value : 7200;
}
