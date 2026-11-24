import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/ad_service.dart';
import '../../services/advanced_settings_service.dart';
import '../../services/native_vpn_service.dart';
import '../../theme/swock_widgets.dart';

class AdvancedScreen extends StatefulWidget {
  const AdvancedScreen({super.key});

  @override
  State<AdvancedScreen> createState() => _AdvancedScreenState();
}

class _AdvancedScreenState extends State<AdvancedScreen> {
  final _service = AdvancedSettingsService();
  final _vpn = NativeVpnService();
  final _udpGatewayPort = TextEditingController(text: '7200');
  AdvancedSettings _settings = const AdvancedSettings();
  bool _loaded = false;
  bool _vpnRunning = false;
  bool _saving = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _service.load().then((settings) {
      if (!mounted) return;
      setState(() {
        _settings = settings;
        _udpGatewayPort.text = settings.udpGatewayPort.toString();
        _loaded = true;
      });
    });
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _udpGatewayPort.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final status = await _vpn.getStatus();
      if (!mounted) return;
      setState(() => _vpnRunning = status['state'] != 'disconnected');
    } on MissingPluginException {
      // The native bridge is unavailable in widget tests.
    } on PlatformException {
      // Keep the last known state until the next poll.
    }
  }

  Future<void> _update(AdvancedSettings next) async {
    if (_vpnRunning || _saving) return;
    final enabling = !_settings.callStability && next.callStability;
    setState(() {
      _saving = true;
      _settings = next;
    });
    try {
      await _service.save(next);
      if (enabling && mounted) {
        final earned = await AdService.instance.offerTemporaryAdFree(
          context,
          occasion: 'Advanced Settings',
        );
        if (mounted && earned) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Ads are paused for 30 minutes.')),
          );
        }
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveUdpGatewayPort() async {
    final port = int.tryParse(_udpGatewayPort.text.trim());
    if (port == null || port < 1 || port > 65535) {
      _udpGatewayPort.text = _settings.udpGatewayPort.toString();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a port from 1 to 65535.')),
      );
      return;
    }
    if (port != _settings.udpGatewayPort) {
      await _update(_settings.copyWith(udpGatewayPort: port));
    }
  }

  @override
  Widget build(BuildContext context) {
    final editable = _loaded && !_vpnRunning && !_saving;
    return Scaffold(
      backgroundColor: SwockColors.background,
      appBar: AppBar(
        toolbarHeight: 72,
        centerTitle: true,
        title: const Text(
          'ADVANCED',
          style: TextStyle(
            color: SwockColors.green,
            fontFamily: 'monospace',
            fontSize: 16,
            fontWeight: FontWeight.w600,
            letterSpacing: 4,
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          SwockCard(
            minHeight: 64,
            child: Row(
              children: [
                Icon(
                  _vpnRunning ? Icons.lock_outline : Icons.tune_rounded,
                  color: _vpnRunning ? SwockColors.amber : SwockColors.green,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _vpnRunning
                        ? 'The VPN is running. Disconnect it to change these options.'
                        : 'These options apply the next time you connect.',
                    style: TextStyle(
                      color:
                          _vpnRunning ? SwockColors.amber : SwockColors.muted,
                      fontSize: 13,
                      height: 1.35,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          _OptionCard(
            icon: Icons.network_check_rounded,
            title: 'Enable IPv6',
            description:
                'Applies to all VPN protocols. When disabled, IPv6 traffic is blocked instead of bypassing the VPN.',
            value: _settings.ipv6Enabled,
            enabled: editable,
            onChanged: (value) =>
                _update(_settings.copyWith(ipv6Enabled: value)),
          ),
          const SizedBox(height: 10),
          _OptionCard(
            icon: Icons.call_outlined,
            title: 'Call Stability Mode',
            description:
                'Keeps the device awake and enables Wi-Fi low-latency mode '
                'while the VPN is connected.',
            value: _settings.callStability,
            enabled: editable,
            onChanged: (value) =>
                _update(_settings.copyWith(callStability: value)),
          ),
          const SizedBox(height: 10),
          _OptionCard(
            icon: Icons.swap_horiz_rounded,
            title: 'SSH UDP Gateway',
            description:
                'Sends SSH tunnel UDP traffic through a BadVPN UDPGW service on the SSH server. Proxy protocols keep their own UDP routing.',
            value: _settings.udpGatewayEnabled,
            enabled: editable,
            onChanged: (value) => _update(
              _settings.copyWith(udpGatewayEnabled: value),
            ),
          ),
          if (_settings.udpGatewayEnabled) ...[
            const SizedBox(height: 8),
            SwockCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'UDPGW port',
                    style: TextStyle(fontSize: 14),
                  ),
                  const SizedBox(height: 5),
                  const Text(
                    'Default: 7200. The gateway must be running on the SSH server.',
                    style: TextStyle(
                      color: SwockColors.muted,
                      fontSize: 12,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _udpGatewayPort,
                    enabled: editable,
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.done,
                    decoration: const InputDecoration(
                      labelText: 'Port',
                      hintText: '7200',
                    ),
                    onSubmitted: (_) => _saveUdpGatewayPort(),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _OptionCard extends StatelessWidget {
  const _OptionCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final String description;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => AnimatedOpacity(
        duration: const Duration(milliseconds: 200),
        opacity: enabled ? 1 : .6,
        child: SwockCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: (value ? SwockColors.green : SwockColors.faint)
                          .withValues(alpha: .12),
                    ),
                    child: Icon(
                      icon,
                      size: 21,
                      color: value ? SwockColors.green : SwockColors.muted,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(title, style: const TextStyle(fontSize: 15)),
                  ),
                  Switch(
                    value: value,
                    onChanged: enabled ? onChanged : null,
                    activeThumbColor: SwockColors.green,
                    activeTrackColor: SwockColors.green.withValues(alpha: .3),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                description,
                style: const TextStyle(
                  color: SwockColors.muted,
                  fontSize: 12,
                  height: 1.45,
                ),
              ),
            ],
          ),
        ),
      );
}
