import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/ad_service.dart';
import '../../services/hotshare_service.dart';
import '../../services/native_vpn_service.dart';
import '../../theme/swock_widgets.dart';

class HotshareScreen extends StatefulWidget {
  const HotshareScreen({super.key});

  @override
  State<HotshareScreen> createState() => _HotshareScreenState();
}

class _HotshareScreenState extends State<HotshareScreen> {
  final _service = HotshareService();
  final _vpn = NativeVpnService();
  final _name = TextEditingController();
  final _password = TextEditingController();
  final _port = TextEditingController();
  HotshareStatus _status = const HotshareStatus();
  String _vpnState = 'disconnected';
  bool _busy = false;
  bool _settingsLoaded = false;
  bool _directMode = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    unawaited(_loadSettings());
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _name.dispose();
    _password.dispose();
    _port.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    try {
      final settings = await _service.loadSettings();
      if (!mounted) return;
      setState(() {
        _name.text = settings.name;
        _password.text = settings.password;
        _port.text = settings.port == HotshareService.autoPort
            ? ''
            : settings.port.toString();
        _settingsLoaded = true;
      });
    } on MissingPluginException {
      _message('Hotshare settings storage is unavailable.');
    } on PlatformException catch (error) {
      _message(error.message ?? 'Hotshare settings could not be loaded.');
    }
  }

  Future<void> _refresh() async {
    try {
      final status = await _service.status();
      final vpn = await _vpn.getStatus();
      if (!mounted) return;
      setState(() {
        _status = status;
        _vpnState = vpn['state'] as String? ?? 'disconnected';
      });
    } on MissingPluginException {
      // The native bridge is unavailable in widget tests.
    } on PlatformException {
      // Keep the last known state until the next poll.
    }
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  bool get _vpnConnected => _vpnState == 'connected';

  Future<void> _toggle() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (_status.isActive) {
        await _service.stop();
      } else {
        if (!_settingsLoaded) {
          _message('Hotshare settings are still loading.');
          return;
        }
        if (!_vpnConnected) {
          _message('Connect the VPN on the Home tab before starting Hotshare.');
          return;
        }
        final name = _name.text.trim();
        if (name.isEmpty || utf8.encode(name).length > 22) {
          _message('Enter a Wi-Fi name suffix no longer than 22 bytes.');
          return;
        }
        if (_password.text.length < 8 || _password.text.length > 63) {
          _message('Enter a hotspot password from 8 to 63 characters.');
          return;
        }
        final portText = _port.text.trim();
        final port = portText.isEmpty
            ? HotshareService.autoPort
            : int.tryParse(portText);
        if (port == null ||
            (port != HotshareService.autoPort &&
                (port < 1024 || port > 65535))) {
          _message(
              'Use automatic port selection or enter a port from 1024 to 65535.');
          return;
        }
        if (!await _service.requestPermissions()) {
          _message('Allow Nearby devices access to create the hotspot.');
          return;
        }
        await _service.start(
          settings: HotshareSettings(
            name: name,
            password: _password.text,
            port: port,
          ),
          direct: _directMode,
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await _refresh();
      if (!mounted) return;
      final earned = await AdService.instance.offerTemporaryAdFree(
        context,
        occasion: 'Hotshare',
      );
      if (mounted && earned) {
        _message('Ads are paused for 30 minutes. Hotshare remains available.');
      }
    } on PlatformException catch (error) {
      _message(error.message ?? 'Hotshare could not be changed.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copy(String label, String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    _message('$label copied.');
  }

  Color get _stateColor => switch (_status.state) {
        'running' => SwockColors.green,
        'starting' => SwockColors.amber,
        'error' => SwockColors.red,
        _ => SwockColors.faint,
      };

  String get _stateLabel => switch (_status.state) {
        'running' => 'SHARING',
        'starting' => 'STARTING',
        'error' => 'FAILED',
        _ => 'OFF',
      };

  @override
  Widget build(BuildContext context) {
    final locked = _status.isActive;
    final canToggle = _vpnConnected;
    return Scaffold(
      backgroundColor: SwockColors.background,
      appBar: AppBar(
        toolbarHeight: 72,
        centerTitle: true,
        title: const Text(
          'HOTSHARE',
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
          _statusCard(),
          const SizedBox(height: 10),
          _modeCard(),
          const SizedBox(height: 10),
          _credentialsCard(),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            height: 50,
            child: FilledButton.icon(
              onPressed:
                  _busy || _status.isStarting || !canToggle ? null : _toggle,
              icon: Icon(
                locked ? Icons.stop_circle_outlined : Icons.wifi_tethering,
              ),
              label: Text(
                locked ? 'STOP HOTSHARE' : 'START HOTSHARE',
                style: const TextStyle(letterSpacing: 1.4),
              ),
              style: FilledButton.styleFrom(
                backgroundColor:
                    locked ? const Color(0xFF3A1F1F) : SwockColors.green,
                foregroundColor:
                    locked ? SwockColors.red : const Color(0xFF07120B),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(5),
                ),
              ),
            ),
          ),
          if (_status.isRunning) ...[
            const SizedBox(height: 10),
            _connectCard(),
          ],
          const SizedBox(height: 10),
          SwockCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwockHeading('HOW IT WORKS'),
                SizedBox(height: 10),
                Text(
                  'Connect the Swock VPN, then start Hotshare to create a private '
                  'Wi-Fi Direct network. Proxy mode requires each device to set '
                  'the displayed manual proxy. Root direct mode routes device '
                  'traffic through the VPN without proxy settings and requires '
                  'root access on this phone. Direct mode forwards IPv4 only; '
                  'IPv6 forwarding is blocked. Keep the VPN connected while '
                  'sharing; Hotshare stops if the VPN disconnects.',
                  style: TextStyle(
                    color: SwockColors.muted,
                    fontSize: 12,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _modeCard() {
    return SwockCard(
      child: SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: _directMode,
        onChanged: _busy || _status.isActive
            ? null
            : (value) => setState(() => _directMode = value),
        activeThumbColor: SwockColors.green,
        title: const Text(
          'Root direct mode',
          style: TextStyle(color: SwockColors.ink, fontSize: 14),
        ),
        subtitle: const Text(
          'No proxy settings on connected devices; requires root access.',
          style: TextStyle(color: SwockColors.muted, fontSize: 12, height: 1.3),
        ),
      ),
    );
  }

  Widget _statusCard() {
    final needsVpn = !_status.isActive && !_vpnConnected;
    return SwockCard(
      minHeight: 82,
      child: Row(
        children: [
          Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _stateColor.withValues(alpha: .1),
            ),
            child: Icon(Icons.wifi_tethering, color: _stateColor, size: 26),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _stateLabel,
                  style: const TextStyle(
                    color: SwockColors.muted,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.4,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  needsVpn
                      ? 'Connect the VPN on the Home tab to share it.'
                      : _status.message,
                  style: const TextStyle(color: SwockColors.ink, height: 1.25),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _credentialsCard() {
    final direct = _status.isActive ? _status.mode == 'direct' : _directMode;
    final host = _status.isRunning ? _status.host : '';
    final active = _status.isActive;
    return SwockCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: SwockHeading('HOTSPOT SETTINGS')),
              Icon(
                active ? Icons.lock_outline : Icons.tune,
                size: 14,
                color: SwockColors.faint,
              ),
              SizedBox(width: 4),
              Text(
                active ? 'ACTIVE' : 'EDITABLE',
                style: TextStyle(
                  color: SwockColors.faint,
                  fontFamily: 'monospace',
                  fontSize: 10,
                  letterSpacing: 1.4,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (active) ...[
            _valueRow('Wi-Fi name', _status.ssid),
            _valueRow('Password', _status.password),
            _valueRow('Sharing mode', direct ? 'Root direct' : 'Proxy'),
            if (!direct) ...[
              _valueRow('Proxy host', host),
              _valueRow('Proxy port', _status.port.toString()),
            ],
          ] else ...[
            TextField(
              controller: _name,
              enabled: _settingsLoaded && !_busy,
              maxLength: 22,
              decoration: const InputDecoration(
                labelText: 'Wi-Fi name suffix',
                helperText: 'Android adds the Wi-Fi Direct network prefix.',
              ),
            ),
            TextField(
              controller: _password,
              enabled: _settingsLoaded && !_busy,
              maxLength: 63,
              decoration: const InputDecoration(
                labelText: 'Hotspot password',
              ),
            ),
            if (!direct)
              TextField(
                controller: _port,
                enabled: _settingsLoaded && !_busy,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                  labelText: 'Proxy port',
                  helperText: 'Leave blank to choose an available port.',
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _connectCard() {
    if (_status.mode == 'direct') {
      return SwockCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SwockHeading('CONNECT A DEVICE'),
            const SizedBox(height: 10),
            _step('1', 'Join the Wi-Fi network ${_status.ssid}.'),
            _step(
              '2',
              'Use the device normally; no proxy settings are needed.',
            ),
            const SizedBox(height: 4),
            const Text(
              "Shared traffic is routed through this phone's VPN. IPv6 forwarding is blocked.",
              style: TextStyle(
                color: SwockColors.muted,
                fontSize: 12,
                height: 1.4,
              ),
            ),
            const Divider(color: SwockColors.line, height: 20),
            Text(
              'Devices: ${_status.clients}',
              style: const TextStyle(
                color: SwockColors.muted,
                fontFamily: 'monospace',
                fontSize: 12,
              ),
            ),
          ],
        ),
      );
    }
    final address = '${_status.host}:${_status.port}';
    return SwockCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SwockHeading('CONNECT A DEVICE'),
          const SizedBox(height: 10),
          _step('1', 'Join the Wi-Fi network ${_status.ssid}.'),
          _step('2', 'Open that network\'s settings and set Proxy to Manual.'),
          _step(
            '3',
            'Enter host ${_status.host} and port ${_status.port}. Use the IPv4 address shown below.',
          ),
          const SizedBox(height: 4),
          _valueRow('Proxy address', address),
          const Divider(color: SwockColors.line, height: 20),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Devices: ${_status.clients}',
                  style: const TextStyle(
                    color: SwockColors.muted,
                    fontFamily: 'monospace',
                    fontSize: 12,
                  ),
                ),
              ),
              Text(
                'Shared: ${_formatBytes(_status.bytes)}',
                style: const TextStyle(
                  color: SwockColors.muted,
                  fontFamily: 'monospace',
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _step(String number, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 20,
              height: 20,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: SwockColors.green.withValues(alpha: .14),
              ),
              child: Text(
                number,
                style: const TextStyle(
                  color: SwockColors.green,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                style: const TextStyle(
                  color: SwockColors.ink,
                  fontSize: 13,
                  height: 1.35,
                ),
              ),
            ),
          ],
        ),
      );

  Widget _valueRow(String label, String value, {String placeholder = ''}) {
    final empty = value.isEmpty;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: const TextStyle(color: SwockColors.muted, fontSize: 13),
            ),
          ),
          Expanded(
            child: SelectableText(
              empty ? placeholder : value,
              style: TextStyle(
                color: empty ? SwockColors.faint : SwockColors.ink,
                fontFamily: 'monospace',
                fontSize: 13,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Copy $label',
            visualDensity: VisualDensity.compact,
            onPressed: empty ? null : () => _copy(label, value),
            icon: const Icon(Icons.copy, size: 17, color: SwockColors.green),
          ),
        ],
      ),
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}
