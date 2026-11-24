import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/ad_service.dart';
import '../../services/native_vpn_service.dart';

const _background = Color(0xFF080B09);
const _surface = Color(0xFF101512);
const _line = Color(0xFF39413B);
const _muted = Color(0xFFA7B0AA);
const _green = Color(0xFF55E89A);
const _gameChannel = MethodChannel('com.swock.vpn/channel');

class GameScreen extends StatefulWidget {
  const GameScreen({super.key});

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> {
  static const _modeKey = 'game_launch_mode';
  static const _confirmKey = 'game_confirm_launch';
  static const _rememberKey = 'game_remember_selection';
  final _vpn = NativeVpnService();
  List<Map<String, dynamic>> _games = const [];
  String? _selectedPackage;
  String _mode = 'Ultimate';
  bool _confirmBeforeLaunch = true;
  bool _rememberSelection = true;
  bool _vpnConnected = false;
  bool _loading = true;
  bool _busy = false;
  String? _sessionGame;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final games = await _gameChannel.invokeListMethod<dynamic>(
            'listLaunchableApps',
          ) ??
          const [];
      final status = await _vpn.getStatus();
      final savedPackage = prefs.getString('game_selected_package');
      if (!mounted) return;
      setState(() {
        _games = games
            .map((game) => Map<String, dynamic>.from(game as Map))
            .toList()
          ..sort((a, b) => (a['label'] as String)
              .toLowerCase()
              .compareTo((b['label'] as String).toLowerCase()));
        _selectedPackage =
            _games.any((game) => game['packageName'] == savedPackage)
                ? savedPackage
                : null;
        _mode = prefs.getString(_modeKey) ?? 'Ultimate';
        _confirmBeforeLaunch = prefs.getBool(_confirmKey) ?? true;
        _rememberSelection = prefs.getBool(_rememberKey) ?? true;
        _vpnConnected = status['connected'] == true;
        _sessionGame = prefs.getString('game_active_session');
        _loading = false;
      });
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      _message(error.message ?? 'Could not read installed games.');
    } on MissingPluginException {
      if (!mounted) return;
      setState(() => _loading = false);
      _message('Game launching is available on Android.');
    }
  }

  Future<void> _save(String key, Object value) async {
    final prefs = await SharedPreferences.getInstance();
    if (value is String) {
      await prefs.setString(key, value);
    } else if (value is bool) {
      await prefs.setBool(key, value);
    }
  }

  Future<void> _selectGame(Map<String, dynamic> game) async {
    final packageName = game['packageName'] as String;
    setState(() => _selectedPackage = packageName);
    if (_rememberSelection) {
      await _save('game_selected_package', packageName);
    }
  }

  Future<bool> _isVpnConnected() async {
    final status = await _vpn.getStatus();
    final connected = status['connected'] == true;
    if (mounted) setState(() => _vpnConnected = connected);
    return connected;
  }

  Future<void> _startGame() async {
    final selected = _games.where(
      (game) => game['packageName'] == _selectedPackage,
    );
    if (selected.isEmpty) {
      _message('Select an installed game first.');
      return;
    }
    bool connected;
    try {
      connected = await _isVpnConnected();
    } on PlatformException catch (error) {
      _message(error.message ?? 'Could not verify the VPN connection.');
      return;
    } on MissingPluginException {
      _message('Game launching is available on Android.');
      return;
    }
    if (!connected) {
      _message('Connect Swock VPN before starting a game.');
      return;
    }
    if (!mounted) return;
    if (_confirmBeforeLaunch) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Start game?'),
          content: Text(
            'Swock will attempt to show an ad, then open ${selected.first['label']}. The VPN must remain connected.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Continue'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }

    setState(() => _busy = true);
    try {
      await AdService.instance.showConnectionInterstitial();
      if (!mounted) return;
      if (!await _isVpnConnected()) {
        _message('VPN disconnected before the game could launch.');
        return;
      }
      final packageName = selected.first['packageName'] as String;
      await _gameChannel.invokeMethod<bool>(
        'launchGame',
        {'packageName': packageName},
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('game_active_session', packageName);
      if (mounted) {
        setState(() => _sessionGame = packageName);
        _message(
          'Game launched through the active VPN. Android does not allow Swock to force FPS or ping improvements.',
        );
      }
    } on PlatformException catch (error) {
      if (mounted) _message(error.message ?? 'Could not launch this game.');
    } on MissingPluginException {
      if (mounted) _message('Game launching is available on Android.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _endSession() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('game_active_session');
    if (mounted) setState(() => _sessionGame = null);
  }

  void _message(String value) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(value)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final selected = _games.where(
      (game) => game['packageName'] == _selectedPackage,
    );
    final session = _games.where(
      (game) => game['packageName'] == _sessionGame,
    );
    return Scaffold(
      backgroundColor: _background,
      appBar: AppBar(
        title: const Text(
          'GAME LAUNCHER',
          style: TextStyle(
            color: _green,
            fontFamily: 'monospace',
            letterSpacing: 2,
            fontSize: 16,
          ),
        ),
        backgroundColor: _background,
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator(color: _green))
            : ListView(
                padding: const EdgeInsets.fromLTRB(18, 8, 18, 28),
                children: [
                  _panel(
                    child: Row(
                      children: [
                        Icon(
                          _vpnConnected
                              ? Icons.vpn_lock_rounded
                              : Icons.vpn_lock_outlined,
                          color: _vpnConnected ? _green : Colors.orangeAccent,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            _vpnConnected
                                ? 'Swock VPN is connected. Game traffic uses the active VPN routing.'
                                : 'Connect Swock VPN before starting a game.',
                            style: const TextStyle(color: Colors.white70),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  _panel(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'LAUNCH PROFILE',
                          style: TextStyle(
                            color: _muted,
                            fontFamily: 'monospace',
                            letterSpacing: 1.4,
                          ),
                        ),
                        const SizedBox(height: 10),
                        DropdownButtonFormField<String>(
                          initialValue: _mode,
                          decoration: const InputDecoration(
                            labelText: 'Mode',
                            enabledBorder: OutlineInputBorder(
                              borderSide: BorderSide(color: _line),
                            ),
                          ),
                          dropdownColor: _surface,
                          items: const [
                            DropdownMenuItem(
                              value: 'Balanced',
                              child: Text('Balanced'),
                            ),
                            DropdownMenuItem(
                              value: 'Performance',
                              child: Text('Performance'),
                            ),
                            DropdownMenuItem(
                              value: 'Ultimate',
                              child: Text('Ultimate'),
                            ),
                          ],
                          onChanged: _busy
                              ? null
                              : (value) {
                                  if (value == null) return;
                                  setState(() => _mode = value);
                                  unawaited(_save(_modeKey, value));
                                },
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'This profile saves your launch preference. Android does not let ordinary apps change another game’s CPU/GPU priority or guarantee lower ping.',
                          style: TextStyle(color: _muted, height: 1.35),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  _panel(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Expanded(
                              child: Text(
                                'INSTALLED GAMES & APPS',
                                style: TextStyle(
                                  color: _muted,
                                  fontFamily: 'monospace',
                                  letterSpacing: 1.4,
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: 'Refresh games',
                              onPressed: _busy
                                  ? null
                                  : () {
                                      setState(() => _loading = true);
                                      unawaited(_load());
                                    },
                              icon: const Icon(Icons.refresh, color: _green),
                            ),
                          ],
                        ),
                        if (_games.isEmpty)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 14),
                            child: Text(
                              'No launchable apps were found on this device. Choose a game from the list.',
                              style: TextStyle(color: _muted),
                            ),
                          )
                        else
                          ..._games.map((game) {
                            final isSelected =
                                game['packageName'] == _selectedPackage;
                            return ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(
                                Icons.sports_esports_outlined,
                                color: isSelected ? _green : _muted,
                              ),
                              title: Text(game['label'] as String),
                              subtitle: Text(
                                game['packageName'] as String,
                                style: const TextStyle(
                                  color: _muted,
                                  fontSize: 11,
                                ),
                              ),
                              trailing: isSelected
                                  ? const Icon(Icons.check_circle,
                                      color: _green)
                                  : null,
                              onTap: _busy ? null : () => _selectGame(game),
                            );
                          }),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  _panel(
                    child: Column(
                      children: [
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Confirm before launch'),
                          value: _confirmBeforeLaunch,
                          activeThumbColor: _green,
                          onChanged: (value) {
                            setState(() => _confirmBeforeLaunch = value);
                            unawaited(_save(_confirmKey, value));
                          },
                        ),
                        const Divider(color: _line, height: 1),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Remember selected game'),
                          value: _rememberSelection,
                          activeThumbColor: _green,
                          onChanged: (value) async {
                            setState(() => _rememberSelection = value);
                            await _save(_rememberKey, value);
                            if (!value) {
                              final prefs =
                                  await SharedPreferences.getInstance();
                              await prefs.remove('game_selected_package');
                            } else if (_selectedPackage != null) {
                              await _save(
                                'game_selected_package',
                                _selectedPackage!,
                              );
                            }
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  if (_sessionGame != null)
                    OutlinedButton.icon(
                      onPressed: _endSession,
                      icon: const Icon(Icons.stop_circle_outlined),
                      label: Text(
                        session.isEmpty
                            ? 'End game session'
                            : 'End ${session.first['label']} session',
                      ),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.orangeAccent,
                        side: const BorderSide(color: _line),
                        minimumSize: const Size.fromHeight(48),
                      ),
                    )
                  else
                    FilledButton.icon(
                      onPressed: _busy ? null : _startGame,
                      icon: _busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.play_arrow_rounded),
                      label: Text(
                        _busy
                            ? 'Starting…'
                            : selected.isEmpty
                                ? 'Select a game'
                                : 'Start ${selected.first['label']}',
                      ),
                      style: FilledButton.styleFrom(
                        backgroundColor: _green,
                        foregroundColor: _background,
                        minimumSize: const Size.fromHeight(50),
                      ),
                    ),
                  const SizedBox(height: 10),
                  const Text(
                    'Starting attempts an interstitial first; if no ad is available, the game still launches. Ending this session clears the launcher state; it cannot force-close the game.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: _muted, fontSize: 12, height: 1.4),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _panel({required Widget child}) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: _surface,
          border: Border.all(color: _line),
          borderRadius: BorderRadius.circular(8),
        ),
        child: child,
      );
}
