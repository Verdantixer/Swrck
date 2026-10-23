import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../../models/vpn_profile.dart';
import '../../services/ad_service.dart';
import '../../services/native_vpn_service.dart';
import '../../services/profile_service.dart';
import '../../services/sock_uri_service.dart';
import '../../services/time_bank_service.dart';
import '../settings/settings_screen.dart';
import 'app_tutorial.dart';
import 'native_ad_strip.dart';
import 'time_widgets.dart';

const _background = Color(0xFF080B09);
const _surface = Color(0xFF101512);
const _line = Color(0xFF39413B);
const _muted = Color(0xFFA7B0AA);
const _faint = Color(0xFF77817A);
const _green = Color(0xFF55E89A);

String _stateLabel(String state) => switch (state) {
  'connected' => 'CONNECTED',
  'connecting' => 'CONNECTING',
  'reconnecting' => 'RECONNECTING',
  'disconnecting' => 'DISCONNECTING',
  'error' => 'RETRYING CONNECTION',
  _ => 'DISCONNECTED',
};

Color _stateColor(String state) => switch (state) {
  'connected' => _green,
  'connecting' => const Color(0xFFFFD45C),
  'reconnecting' => const Color(0xFFFFA14A),
  'disconnecting' || 'error' => const Color(0xFFFF625C),
  _ => _faint,
};

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  final _profileService = ProfileService();
  final _vpnService = NativeVpnService();
  final List<_AppLog> _logs = [];
  List<VpnProfile> _profiles = [];
  int _tab = 0;
  String _connectionState = 'disconnected';
  bool _loading = true;
  bool _busy = false;
  bool _adsReady = false;
  bool _privacyOptionsRequired = false;
  bool _addOptionsOpen = false;
  int? _latencyMs;
  double _downloadSpeed = 0;
  double _uploadSpeed = 0;
  int? _previousDownloadBytes;
  int? _previousUploadBytes;
  DateTime? _previousStatsAt;
  final Map<String, int> _profileLatencies = {};
  String? _pingError;
  String? _rewardMessage;
  String? _lastStatusMessage;
  DateTime? _backgroundedAt;
  Timer? _statusTimer;
  Map<String, dynamic> _statistics = {};
  TimeBank? _timeBank;
  Duration _remaining = Duration.zero;
  bool _addTimeBusy = false;
  bool _expiryHandled = false;
  DateTime? _addCooldownUntil;
  final Set<int> _warnedThresholds = {};

  VpnProfile? get _activeProfile =>
      _profiles.where((profile) => profile.isSelected).firstOrNull;
  bool get _vpnLocked => _connectionState != 'disconnected';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_startup());
    _loadProfiles();
    _loadTimeBank();
    _refreshStatus();
    _statusTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _refreshStatus();
      _tickTime();
    });
  }

  Future<void> _startup() async {
    await showAppTutorialIfNeeded(context);
    if (!mounted) return;
    await _initializeAds();
  }

  Future<void> _initializeAds() async {
    await AdService.instance.initialize();
    final privacyOptionsRequired =
        await AdService.instance.privacyOptionsRequired();
    if (!mounted) return;
    setState(() {
      _adsReady = AdService.instance.canRequestAds;
      _privacyOptionsRequired = privacyOptionsRequired;
    });
    AdService.instance.prepareForForeground();
    AdService.instance.preloadTimeReward();
    await _refreshStatus();
    if (mounted && _connectionState == 'disconnected') {
      AdService.instance.showAppOpenIfReady(appWasBackgrounded: true);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _statusTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _backgroundedAt = DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      final returnedFromBackground = _backgroundedAt != null;
      _backgroundedAt = null;
      if (returnedFromBackground && _connectionState == 'disconnected') {
        AdService.instance.showAppOpenIfReady(appWasBackgrounded: true);
      }
    }
  }

  Future<void> _loadProfiles() async {
    try {
      final profiles = await _profileService.loadProfiles();
      if (!mounted) return;
      setState(() {
        _profiles = profiles;
        _loading = false;
      });
      final importUri = await _vpnService.getImportUri();
      if (importUri != null && importUri.trim().isNotEmpty) {
        await _importProfile(importUri);
      }
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      _message(error.message ?? 'Could not load saved profiles.');
    } on MissingPluginException {
      if (mounted) setState(() => _loading = false);
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      _message('Could not load profiles: $error');
    }
  }

  Future<void> _refreshStatus() async {
    try {
      final events = await _vpnService.drainVpnLogs();
      final status = await _vpnService.getStatus();
      final stats = await _vpnService.getStatistics();
      if (!mounted) return;
      for (final event in events) {
        final message = event['message'] as String?;
        final timestamp = (event['timestamp'] as num?)?.toInt();
        if (message != null && message.isNotEmpty) {
          _recordVpnLog(message, timestampMs: timestamp);
        }
      }
      final nextState = status['state'] as String? ?? 'disconnected';
        final justConnected =
          nextState == 'connected' && _connectionState != 'connected';
      if (nextState != _connectionState) {
        _recordVpnLog('State: ${_stateLabel(nextState)}.');
      }
      final statusMessage = status['message'] as String?;
      if (statusMessage != null && statusMessage != _lastStatusMessage) {
        _recordVpnLog(statusMessage);
        _lastStatusMessage = statusMessage;
      }
      final now = DateTime.now();
      final downloadBytes = (stats['downloadBytes'] as num?)?.toInt();
      final uploadBytes = (stats['uploadBytes'] as num?)?.toInt();
      final previousAt = _previousStatsAt;
      final elapsed =
          previousAt == null
              ? 0.0
              : now.difference(previousAt).inMilliseconds / 1000;
      final isConnected = nextState == 'connected';
      setState(() {
        _connectionState = nextState;
        _statistics = stats;
        if (isConnected &&
            elapsed > 0 &&
            downloadBytes != null &&
            _previousDownloadBytes != null) {
          _downloadSpeed =
              ((downloadBytes - _previousDownloadBytes!) / elapsed)
                  .clamp(0, double.infinity)
                  .toDouble();
        } else if (!isConnected) {
          _downloadSpeed = 0;
        }
        if (isConnected &&
            elapsed > 0 &&
            uploadBytes != null &&
            _previousUploadBytes != null) {
          _uploadSpeed =
              ((uploadBytes - _previousUploadBytes!) / elapsed)
                  .clamp(0, double.infinity)
                  .toDouble();
        } else if (!isConnected) {
          _uploadSpeed = 0;
        }
      });
      _previousStatsAt = now;
      _previousDownloadBytes = downloadBytes;
      _previousUploadBytes = uploadBytes;
      if (justConnected) {
        unawaited(_offerAdFreeAfterAction('your VPN connection'));
      }
    } on MissingPluginException {
      // The native bridge is unavailable in widget tests and desktop previews.
    } on PlatformException catch (error) {
      if (mounted && _connectionState != 'error') {
        setState(() => _connectionState = 'error');
        _recordVpnLog(error.message ?? 'Could not read VPN status.');
      }
    }
  }

  void _recordVpnLog(String message, {int? timestampMs}) {
    if (!mounted) return;
    setState(() {
      final timestamp =
          timestampMs == null
              ? DateTime.now()
              : DateTime.fromMillisecondsSinceEpoch(timestampMs);
      _logs.insert(0, _AppLog(timestamp, message));
      if (_logs.length > 200) _logs.removeLast();
    });
  }

  void _message(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _saveProfiles(List<VpnProfile> profiles) async {
    await _profileService.saveProfiles(profiles);
    if (mounted) setState(() => _profiles = profiles);
  }

  Future<void> _selectProfile(VpnProfile selected) async {
    if (_vpnLocked) return;
    final next =
        _profiles
            .map(
              (profile) =>
                  profile.copyWith(isSelected: profile.id == selected.id),
            )
            .toList();
    await _saveProfiles(next);
  }

  Future<void> _openEditor({VpnProfile? profile}) async {
    if (_vpnLocked) return;
    final result = await showDialog<VpnProfile>(
      context: context,
      builder: (context) => _ProfileEditorDialog(profile: profile),
    );
    if (result == null) return;
    final exists = _profiles.any((item) => item.id == result.id);
    var next =
        exists
            ? _profiles
                .map((item) => item.id == result.id ? result : item)
                .toList()
            : [..._profiles, result.copyWith(isSelected: _profiles.isEmpty)];
    if (_profiles.isEmpty && next.isNotEmpty) {
      next =
          next
              .map(
                (item) => item.copyWith(isSelected: item.id == next.first.id),
              )
              .toList();
    }
    try {
      await _saveProfiles(next);
      _message(exists ? 'Profile updated.' : 'Profile saved.');
    } catch (error) {
      _message('Could not save profile: $error');
    }
  }

  Future<void> _deleteProfile(VpnProfile profile) async {
    if (_vpnLocked) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('Delete profile?'),
            content: Text(
              '“${profile.name}” will be removed from this device.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Delete'),
              ),
            ],
          ),
    );
    if (confirmed != true) return;
    try {
      await _profileService.deleteProfile(profile.id);
      final remaining =
          _profiles.where((item) => item.id != profile.id).toList();
      if (profile.isSelected && remaining.isNotEmpty) {
        remaining[0] = remaining[0].copyWith(isSelected: true);
        await _profileService.saveProfiles(remaining);
      }
      if (mounted) setState(() => _profiles = remaining);
    } catch (error) {
      _message('Could not delete profile: $error');
    }
  }

  Future<void> _shareProfile(VpnProfile profile) async {
    final uri =
        Uri(
          scheme: 'swock',
          host: profile.server,
          queryParameters: {
            'v': '2',
            'name': profile.name,
            'port': profile.port.toString(),
            'spk': profile.serverPublicKey,
            'cpk': profile.clientPrivateKey,
            if (profile.tunnelAddress.isNotEmpty) 'ip': profile.tunnelAddress,
            'transport': profile.transport.name,
            if (profile.webSocket.enabled) 'ws': '1',
            if (profile.webSocket.enabled) 'wspath': profile.webSocket.path,
            if (profile.webSocket.host.isNotEmpty)
              'wshost': profile.webSocket.host,
            if (profile.tls.enabled) 'tls': '1',
            if (profile.tls.sni.isNotEmpty) 'sni': profile.tls.sni,
            if (profile.dns.enabled) 'dns': '1',
            if (profile.dns.primary.isNotEmpty) 'dns1': profile.dns.primary,
            if (profile.dns.secondary.isNotEmpty) 'dns2': profile.dns.secondary,
            if (profile.dns.tertiary.isNotEmpty) 'dns3': profile.dns.tertiary,
          },
        ).toString();
    await Clipboard.setData(ClipboardData(text: uri));
    _message('Swock profile link copied. It contains the client private key.');
  }

  Future<void> _showImportDialog() async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('Import Swock profile'),
            content: TextField(
              controller: controller,
              minLines: 2,
              maxLines: 4,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(hintText: 'swock://…'),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, controller.text),
                child: const Text('Import'),
              ),
            ],
          ),
    );
    controller.dispose();
    if (value == null || value.trim().isEmpty) return;
    await _importProfile(value);
  }

  Future<void> _importProfile(String value) async {
    if (_vpnLocked) return;
    try {
      final imported = SwockUriService.importUri(value);
      final existing = _profiles.indexWhere((item) => item.id == imported.id);
      final next = [..._profiles];
      if (existing >= 0) {
        next[existing] = imported;
      } else {
        next.add(imported.copyWith(isSelected: _profiles.isEmpty));
      }
      if (_profiles.isEmpty) {
        next[0] = next[0].copyWith(isSelected: true);
      }
      await _saveProfiles(next);
      _message('Profile imported and saved.');
    } on FormatException catch (error) {
      _message(error.message);
    } catch (error) {
      _message('Could not import profile: $error');
    }
  }

  Future<void> _loadTimeBank() async {
    final bank = await TimeBank.load();
    if (!mounted) return;
    // If Android restored a running VPN while the app process was gone, keep
    // charging its persisted session instead of resetting the timer.
    await bank.sync(connected: bank.isRunning, now: DateTime.now());
    if (!mounted) return;
    setState(() {
      _timeBank = bank;
      _remaining = bank.remaining(DateTime.now());
    });
    await _tickTime();
  }

  int get _cooldownSeconds {
    final until = _addCooldownUntil;
    if (until == null) return 0;
    final left = until.difference(DateTime.now()).inMilliseconds;
    return left <= 0 ? 0 : (left / 1000).ceil();
  }

  Future<void> _tickTime() async {
    final bank = _timeBank;
    if (bank == null) return;
    final now = DateTime.now();
    final connected = _connectionState == 'connected';
    await bank.sync(connected: connected, now: now);
    if (!mounted) return;
    final remaining = bank.remaining(now);
    setState(() => _remaining = remaining);
    if (remaining > Duration.zero) _expiryHandled = false;
    if (!connected) return;
    _warnIfLow(remaining);
    if (remaining == Duration.zero && !_expiryHandled) {
      _expiryHandled = true;
      unawaited(_handleTimeExpired());
    }
  }

  // Warns once per threshold; thresholds re-arm after time is added.
  void _warnIfLow(Duration remaining) {
    const thresholds = [600, 300, 60];
    final seconds = remaining.inSeconds;
    for (final threshold in thresholds) {
      if (seconds > threshold) _warnedThresholds.remove(threshold);
    }
    if (seconds <= 0) return;
    final level = thresholds
        .where((t) => seconds <= t)
        .fold<int?>(
          null,
          (smallest, t) => smallest == null || t < smallest ? t : smallest,
        );
    if (level == null || _warnedThresholds.contains(level)) return;
    _warnedThresholds.addAll(thresholds.where((t) => t >= level));
    _message(
      '${describeRemaining(remaining)} of VPN time left. Tap Add + Time to keep your connection.',
    );
  }

  Future<void> _handleTimeExpired() async {
    _recordVpnLog('VPN time ran out.');
    while (mounted &&
        _remaining == Duration.zero &&
        _connectionState == 'connected') {
      if (!mounted) return;
      final addTime = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => TimeUpDialog(initialCooldownSeconds: _cooldownSeconds),
      );
      if (addTime != true) break;
      if (await _addTime()) return;
    }
    if (!mounted ||
        _remaining > Duration.zero ||
        _connectionState != 'connected') {
      return;
    }
    await _toggleConnection();
    _recordVpnLog('Disconnected because VPN time ran out.');
  }

  Future<bool> _addTime() async {
    if (_addTimeBusy || _cooldownSeconds > 0 || _timeBank == null) {
      return false;
    }
    setState(() => _addTimeBusy = true);
    try {
      if (!AdService.instance.canRequestAds) {
        await AdService.instance.initialize();
      }
      if (!AdService.instance.canRequestAds) {
        _message('Ads are unavailable right now. Try again in a moment.');
        return false;
      }
      final earned = await AdService.instance.showTimeReward();
      if (!mounted) return false;
      if (!earned) {
        _message('Watch the full ad to earn time.');
        return false;
      }
      final won = await showDialog<TimeReward>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const RewardWheelDialog(),
      );
      if (won == null) return false;
      final reward = won;
      final bank = _timeBank!;
      await bank.add(reward.duration, DateTime.now());
      if (!mounted) return true;
      setState(() {
        _remaining = bank.remaining(DateTime.now());
        _expiryHandled = false;
      });
      _warnedThresholds.clear();
      _recordVpnLog('Added ${reward.label} of VPN time.');
      _message('Added ${reward.label} to your timer.');
      return true;
    } finally {
      if (mounted) {
        setState(() {
          _addTimeBusy = false;
          _addCooldownUntil = DateTime.now().add(const Duration(seconds: 5));
        });
      }
    }
  }

  String _timerMessage(bool connected) {
    if (_timeBank == null) return 'Loading your time…';
    if (_remaining == Duration.zero) return 'Out of time. Add time to connect.';
    if (_remaining <= const Duration(minutes: 1)) {
      return 'Under a minute left. Add time now.';
    }
    if (_remaining <= const Duration(minutes: 10)) {
      return 'Running low: ${describeRemaining(_remaining)} left. Add more time.';
    }
    return connected
        ? 'Counting down while connected.'
        : 'Time only counts down while connected.';
  }

  Future<void> _toggleConnection() async {
    if (_connectionState != 'disconnected') {
      if (_connectionState == 'disconnecting') return;
      await _vpnService.clearVpnLogs();
      if (!mounted) return;
      setState(() => _logs.clear());
      _lastStatusMessage = null;
      _recordVpnLog('User requested VPN stop.');
      setState(() => _busy = true);
      if (mounted) setState(() => _connectionState = 'disconnecting');
      try {
        await _vpnService.disconnect();
        await _refreshStatus();
      } on PlatformException catch (error) {
        _message(error.message ?? 'Could not disconnect VPN.');
      } finally {
        if (mounted) setState(() => _busy = false);
      }
      return;
    }
    if (_busy) return;
    if (_timeBank != null && _remaining == Duration.zero) {
      _message('You are out of VPN time. Tap Add + Time to connect.');
      return;
    }
    final profile = _activeProfile;
    if (profile == null) {
      _message('Add or select a profile first.');
      setState(() => _tab = 1);
      return;
    }
    if (!profile.hasValidServer || !profile.hasValidPort) {
      _message('Edit this profile and enter a valid server and port.');
      await _openEditor(profile: profile);
      return;
    }

    if (profile.protocol == VpnProtocol.swock) {
      final keyPattern = RegExp(r'^[0-9a-fA-F]{64}$');
      if (!keyPattern.hasMatch(profile.serverPublicKey) ||
          !keyPattern.hasMatch(profile.clientPrivateKey)) {
        _message(
          'Edit this Swock profile and enter both 64-character X25519 keys.',
        );
        await _openEditor(profile: profile);
        return;
      }
    } else if (profile.protocol == VpnProtocol.vless ||
        profile.protocol == VpnProtocol.vmess) {
      if (profile.uuid.trim().isEmpty) {
        _message('Edit this profile and enter a valid User ID / UUID.');
        await _openEditor(profile: profile);
        return;
      }
    } else if (profile.protocol == VpnProtocol.trojan ||
        profile.protocol == VpnProtocol.shadowsocks) {
      if (profile.password.trim().isEmpty) {
        _message('Edit this profile and enter a valid Password / Key.');
        await _openEditor(profile: profile);
        return;
      }
    }
    await _vpnService.clearVpnLogs();
    if (!mounted) return;
    setState(() {
      _busy = true;
      _connectionState = 'connecting';
      _logs.clear();
      _lastStatusMessage = null;
      _downloadSpeed = 0;
      _uploadSpeed = 0;
      _previousDownloadBytes = null;
      _previousUploadBytes = null;
      _previousStatsAt = null;
    });
    _recordVpnLog('Starting VPN connection to ${profile.name}.');
    try {
      final started = await _vpnService.connect(profile);
      if (!started) throw Exception('The VPN service did not start.');
      await _refreshStatus();
    } on PlatformException catch (error) {
      if (mounted) setState(() => _connectionState = 'error');
      _recordVpnLog(error.message ?? 'VPN connection failed.');
      _message(error.message ?? 'VPN connection failed.');
    } catch (error) {
      if (mounted) setState(() => _connectionState = 'error');
      _recordVpnLog('VPN connection failed: $error');
      _message('VPN connection failed: $error');
    } finally {
      await _refreshStatus();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pingActive() async {
    if (_vpnLocked || _busy) return;
    final profile = _activeProfile;
    if (profile == null) return;
    setState(() => _busy = true);
    try {
      final latency = await _measureTcpLatency(profile);
      if (!mounted) return;
      setState(() {
        _latencyMs = latency;
        _profileLatencies[profile.id] = latency;
        _pingError = null;
      });
    } on SocketException catch (error) {
      if (mounted) setState(() => _pingError = error.message);
    } on TimeoutException {
      if (mounted) setState(() => _pingError = 'Timed out');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<int> _measureTcpLatency(VpnProfile profile) async {
    final stopwatch = Stopwatch()..start();
    final socket = await Socket.connect(
      profile.server,
      profile.port,
      timeout: const Duration(seconds: 4),
    );
    stopwatch.stop();
    socket.destroy();
    return stopwatch.elapsedMilliseconds;
  }

  @override
  Widget build(BuildContext context) {
    final active = _activeProfile;
    return Scaffold(
      backgroundColor: _background,
      appBar: AppBar(
        toolbarHeight: 72,
        centerTitle: true,
        title: const _BrandHeader(),
        actions: [
          if (_privacyOptionsRequired)
            IconButton(
              tooltip: 'Privacy options',
              onPressed: _managePrivacyOptions,
              icon: const Icon(Icons.privacy_tip_outlined, color: _muted),
            ),
          IconButton(
            tooltip: 'Premium',
            onPressed: _showPremiumDialog,
            icon: const Icon(Icons.stars_rounded, color: _green),
          ),
          IconButton(
            tooltip: 'Settings',
            onPressed: _openSettings,
            icon: const Icon(Icons.settings_outlined, color: _muted),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        top: false,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 260),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder:
              (child, animation) => FadeTransition(
                opacity: animation,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0.025, 0),
                    end: Offset.zero,
                  ).animate(animation),
                  child: child,
                ),
              ),
          child: KeyedSubtree(
            key: ValueKey(_tab),
            child:
                [
                  _homePage(active),
                  _configsPage(),
                  _statsPage(),
                  _infoPage(),
                  _logsPage(),
                ][_tab],
          ),
        ),
      ),
      bottomNavigationBar: AnnotatedRegion<SystemUiOverlayStyle>(
        value: const SystemUiOverlayStyle(
          systemNavigationBarColor: _surface,
          systemNavigationBarDividerColor: _surface,
          systemNavigationBarIconBrightness: Brightness.light,
          systemNavigationBarContrastEnforced: false,
        ),
        child: _BottomTabs(
          selected: _tab,
          onSelected: (index) => setState(() => _tab = index),
        ),
      ),
      floatingActionButton:
          _tab == 1 && !_vpnLocked
              ? Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  AnimatedSize(
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOutCubic,
                    child:
                        _addOptionsOpen
                            ? Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: Material(
                                color: const Color(0xFF171D19),
                                borderRadius: BorderRadius.circular(8),
                                elevation: 8,
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    _AddOptionButton(
                                      icon: Icons.edit_note,
                                      label: 'Add manually',
                                      onPressed:
                                          () => _chooseAddOption('manual'),
                                    ),
                                    const Divider(height: 1, color: _line),
                                    _AddOptionButton(
                                      icon: Icons.link,
                                      label: 'Import via URI',
                                      onPressed:
                                          () => _chooseAddOption('import'),
                                    ),
                                  ],
                                ),
                              ),
                            )
                            : const SizedBox.shrink(),
                  ),
                  FloatingActionButton(
                    tooltip: _addOptionsOpen ? 'Close add menu' : 'Add profile',
                    onPressed: _showAddOptions,
                    backgroundColor: _green,
                    foregroundColor: const Color(0xFF07120B),
                    child: AnimatedRotation(
                      turns: _addOptionsOpen ? 0.125 : 0,
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOutBack,
                      child: Icon(
                        _addOptionsOpen ? Icons.add : Icons.add,
                        size: 28,
                      ),
                    ),
                  ),
                ],
              )
              : null,
    );
  }

  void _showAddOptions() {
    setState(() => _addOptionsOpen = !_addOptionsOpen);
  }

  Future<void> _openSettings() => Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen()));

  Future<void> _chooseAddOption(String action) async {
    setState(() => _addOptionsOpen = false);
    if (action == 'manual') await _openEditor();
    if (action == 'import') await _showImportDialog();
  }

  Future<void> _showPremiumDialog() => showDialog<void>(
    context: context,
    builder:
        (context) => Dialog(
          backgroundColor: const Color(0xFF101713),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: Color(0xFF345341)),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFF163323),
                    border: Border.all(color: _green.withValues(alpha: .5)),
                  ),
                  child: const Icon(
                    Icons.stars_rounded,
                    color: _green,
                    size: 32,
                  ),
                ),
                const SizedBox(height: 18),
                const Text(
                  'PREMIUM',
                  style: TextStyle(
                    color: _green,
                    fontFamily: 'monospace',
                    letterSpacing: 2.2,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  'Something better is coming.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Swock Premium is on its way. We will share more when it is ready.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: _muted, height: 1.45),
                ),
                const SizedBox(height: 22),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Close'),
                  ),
                ),
              ],
            ),
          ),
        ),
  );

  Future<void> _managePrivacyOptions() async {
    await AdService.instance.showPrivacyOptions();
    if (!mounted) return;
    final required = await AdService.instance.privacyOptionsRequired();
    if (!mounted) return;
    setState(() {
      _adsReady = AdService.instance.canRequestAds;
      _privacyOptionsRequired = required;
    });
  }

  Future<void> _showRewardChoices() async {
    final interstitial = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('Earn ad-free time'),
            content: const Text(
              'Choose an optional video. Ads only play after you select one, and the benefit is granted after the reward is earned.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Not now'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('15 min · rewarded interstitial'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('30 min · rewarded video'),
              ),
            ],
          ),
    );
    if (interstitial == null) return;
    final earned = await AdService.instance.showReward(
      interstitial: interstitial,
    );
    if (!mounted) return;
    setState(() {
      _rewardMessage =
          earned
              ? 'Ad-free access is active for ${interstitial ? 15 : 30} minutes.'
              : 'The reward was not completed. No ad-free time was added.';
    });
  }

  Future<void> _offerAdFreeAfterAction(String occasion) async {
    final earned = await AdService.instance.offerTemporaryAdFree(
      context,
      occasion: occasion,
    );
    if (!mounted || !earned) return;
    setState(() {
      _rewardMessage = 'Ads are paused for 30 minutes.';
    });
    _message('Ads are paused for 30 minutes. VPN access remains active.');
  }

  Widget _homePage(VpnProfile? active) {
    final connected = _connectionState == 'connected';
    final duration = (_statistics['durationMs'] as num?)?.toInt() ?? 0;
    final statusText =
        connected
            ? 'Secure tunnel is active${duration > 0 ? ' · ${_formatDuration(duration)}' : ''}.'
            : _connectionState == 'connecting'
            ? 'Preparing your encrypted tunnel.'
            : _connectionState == 'reconnecting'
            ? 'Connection interrupted. Reconnecting automatically.'
            : _connectionState == 'disconnecting'
            ? 'Closing the secure tunnel.'
            : _connectionState == 'error'
            ? 'Connection failed. Retrying automatically.'
            : active == null
            ? 'Add a configuration, then connect.'
            : 'Choose a configuration, then connect.';
    return LayoutBuilder(
      builder: (context, constraints) {
        final controlSize = (constraints.maxHeight * .27).clamp(104.0, 178.0);
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
          child: SingleChildScrollView(
            child: Column(
              children: [
                SizedBox(
                  height: controlSize + 4,
                  child: Center(
                    child: _PowerControl(
                      size: controlSize,
                      state: _connectionState,
                      onPressed: _toggleConnection,
                    ),
                  ),
                ),
                Tooltip(
                  message: 'Double-tap for an optional ad-free offer',
                  child: Semantics(
                    hint: 'Double-tap to open an optional ad-free offer',
                    child: GestureDetector(
                      onDoubleTap: () =>
                          unawaited(_offerAdFreeAfterAction('the Home panel')),
                      child: Container(
                        constraints: const BoxConstraints(minHeight: 82),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: _surface,
                          border: Border.all(color: _line),
                          borderRadius: BorderRadius.circular(7),
                        ),
                        child: Row(
                          children: [
                            _ConnectionCloud(state: _connectionState),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _stateLabel(_connectionState),
                                    style: const TextStyle(
                                      color: _muted,
                                      fontFamily: 'monospace',
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 1.4,
                                    ),
                                  ),
                                  const SizedBox(height: 5),
                                  Text(
                                    statusText,
                                    style: const TextStyle(
                                      color: _inkColor,
                                      height: 1.25,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: TimerCard(
                          remaining: _remaining,
                          counting: connected,
                          message: _timerMessage(connected),
                        ),
                      ),
                      const SizedBox(width: 10),
                      AddTimeButton(
                        onPressed: _addTime,
                        cooldownSeconds: _cooldownSeconds,
                        busy: _addTimeBusy,
                        attention: _remaining <= const Duration(minutes: 10),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                active == null
                    ? _emptyActiveCard()
                    : _activeConfigurationCard(active),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _emptyActiveCard() => Container(
    width: double.infinity,
    constraints: const BoxConstraints(minHeight: 82),
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    decoration: BoxDecoration(
      color: _surface,
      border: Border.all(color: _line),
      borderRadius: BorderRadius.circular(7),
    ),
    child: Row(
      children: [
        _configIcon(),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _SectionHeading('ACTIVE CONFIGURATION'),
              const SizedBox(height: 5),
              const Text('No profile selected', style: TextStyle(fontSize: 15)),
              const SizedBox(height: 3),
              const Text(
                'Add a Swock profile to get started in Configs.',
                style: TextStyle(color: _muted, fontSize: 12),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _configIcon() => Container(
    width: 54,
    height: 54,
    decoration: BoxDecoration(
      color: _green.withValues(alpha: .08),
      shape: BoxShape.circle,
    ),
    child: Icon(
      Icons.description_outlined,
      color: _green.withValues(alpha: .8),
    ),
  );

  Widget _activeConfigurationCard(VpnProfile profile) => Container(
    width: double.infinity,
    constraints: const BoxConstraints(minHeight: 82),
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    decoration: BoxDecoration(
      color: _surface,
      border: Border.all(color: _line),
      borderRadius: BorderRadius.circular(7),
    ),
    child: Row(
      children: [
        _configIcon(),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _SectionHeading('ACTIVE CONFIGURATION'),
              const SizedBox(height: 3),
              Text(
                profile.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 15),
              ),
              const SizedBox(height: 2),
              Text(
                '${profile.server}:${profile.port}  ·  ${_transportSummary(profile)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: _muted,
                  fontFamily: 'monospace',
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 10,
                runSpacing: 2,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    _latencyMs == null ? 'PING —' : 'PING $_latencyMs ms',
                    style: const TextStyle(
                      color: Color(0xFFFFD45C),
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: _vpnLocked || _busy ? null : _pingActive,
                    icon: const Icon(Icons.network_ping, size: 16),
                    label: const Text('TEST'),
                    style: TextButton.styleFrom(
                      foregroundColor: _green,
                      padding: const EdgeInsets.symmetric(horizontal: 5),
                      minimumSize: const Size(0, 30),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                  if (_connectionState == 'connected') ...[
                    Text(
                      '↓ ${_formatSpeed(_downloadSpeed)}',
                      style: const TextStyle(
                        color: _muted,
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                    Text(
                      '↑ ${_formatSpeed(_uploadSpeed)}',
                      style: const TextStyle(
                        color: _muted,
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                  ],
                  if (_connectionState == 'connected' &&
                      _adsReady &&
                      !AdService.instance.hasTemporaryAdFreeAccess)
                    TextButton.icon(
                      onPressed: _showRewardChoices,
                      icon: const Icon(Icons.play_circle_outline, size: 16),
                      label: const Text('AD-FREE'),
                      style: TextButton.styleFrom(
                        foregroundColor: _green,
                        padding: const EdgeInsets.symmetric(horizontal: 5),
                        minimumSize: const Size(0, 30),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                ],
              ),
              if (_pingError != null)
                Text(
                  'Ping failed: $_pingError',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFFFFA14A),
                    fontSize: 11,
                  ),
                ),
              if (_rewardMessage != null)
                Text(
                  _rewardMessage!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: _muted, fontSize: 11),
                ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _configsPage() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final favorites = _profiles.where((profile) => profile.favorite).toList();
    final saved = _profiles.where((profile) => !profile.favorite).toList();
    return _profiles.isEmpty
        ? Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.cloud_outlined, size: 48, color: _faint),
                const SizedBox(height: 18),
                const Text(
                  'NO CONFIGURATIONS',
                  style: TextStyle(fontFamily: 'monospace', letterSpacing: 1.5),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Add a profile to connect to your Swock server.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: _muted),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        )
        : ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 110),
          children: [
            if (_adsReady && !AdService.instance.hasTemporaryAdFreeAccess)
              const NativeAdStrip(),
            if (favorites.isNotEmpty) ...[
              const SizedBox(height: 6),
              _ProfileGroupHeader(title: 'FAVORITES', count: favorites.length),
              for (final profile in favorites) _profileTile(profile),
            ],
            const SizedBox(height: 12),
            _ProfileGroupHeader(title: 'SAVED', count: saved.length),
            for (final profile in saved) _profileTile(profile),
            const SizedBox(height: 120),
          ],
        );
  }

  Widget _profileTile(VpnProfile profile) {
    final selected = profile.isSelected;
    return InkWell(
      onTap: _vpnLocked ? null : () => _selectProfile(profile),
      child: Container(
        height: 64,
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF073B2A) : _surface,
          border: Border.all(
            color: selected ? _green : _line,
            width: selected ? 1.5 : 1,
          ),
          borderRadius: BorderRadius.circular(5),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    profile.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${profile.server}:${profile.port}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: _muted,
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  _transportSummary(profile),
                  style: const TextStyle(
                    color: _muted,
                    fontFamily: 'monospace',
                    fontSize: 11,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _profileLatencies[profile.id] == null
                      ? 'Ping —'
                      : 'Ping ${_profileLatencies[profile.id]}ms',
                  style: const TextStyle(
                    color: Color(0xFFFFD45C),
                    fontFamily: 'monospace',
                    fontSize: 10,
                  ),
                ),
              ],
            ),
            if (profile.favorite) ...[
              const SizedBox(width: 8),
              const Icon(Icons.star, color: _green, size: 17),
            ],
            IconButton(
              tooltip: 'Edit ${profile.name}',
              onPressed:
                  _vpnLocked ? null : () => _openEditor(profile: profile),
              icon: const Icon(Icons.edit, size: 19),
            ),
            PopupMenuButton<String>(
              tooltip: 'More actions for ${profile.name}',
              onSelected: (action) {
                if (action == 'share') _shareProfile(profile);
                if (action == 'delete') _deleteProfile(profile);
              },
              itemBuilder:
                  (context) => [
                    const PopupMenuItem(
                      value: 'share',
                      child: ListTile(
                        leading: Icon(Icons.share_outlined),
                        title: Text('Copy Swock URI'),
                      ),
                    ),
                    PopupMenuItem(
                      value: 'delete',
                      enabled: !_vpnLocked,
                      child: const ListTile(
                        leading: Icon(Icons.delete_outline),
                        title: Text('Delete'),
                      ),
                    ),
                  ],
              icon: const Icon(Icons.more_vert, size: 20),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statsPage() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 110),
      children: [
        _ProfileGroupHeader(title: 'STATS', count: 0),
        Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
          decoration: BoxDecoration(
            color: _surface,
            border: Border.all(color: _line),
            borderRadius: BorderRadius.circular(7),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    _latencyMs == null ? 'Ping —' : 'Ping $_latencyMs ms',
                    style: const TextStyle(
                      color: _muted,
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                  TextButton(
                    onPressed: _vpnLocked || _busy ? null : _pingActive,
                    child: const Text('Ping'),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              const Divider(color: _line, height: 1),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'DOWNLINK',
                          style: TextStyle(
                            color: _muted,
                            fontFamily: 'monospace',
                            fontSize: 11,
                            letterSpacing: 1.6,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            const Icon(
                              Icons.keyboard_arrow_down,
                              color: _faint,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              _formatSpeed(_downloadSpeed),
                              style: const TextStyle(
                                color: _muted,
                                fontFamily: 'monospace',
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  Container(width: 1, height: 62, color: _line),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(left: 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'UPLINK',
                            style: TextStyle(
                              color: _muted,
                              fontFamily: 'monospace',
                              fontSize: 11,
                              letterSpacing: 1.6,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              const Icon(
                                Icons.keyboard_arrow_up,
                                color: _faint,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                _formatSpeed(_uploadSpeed),
                                style: const TextStyle(
                                  color: _muted,
                                  fontFamily: 'monospace',
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _infoPage() => ListView(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 110),
    children: [
      _ProfileGroupHeader(title: 'INFO', count: 0),
      Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
        decoration: BoxDecoration(
          color: _surface,
          border: Border.all(color: _line),
          borderRadius: BorderRadius.circular(7),
        ),
        child: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _InfoRow(label: 'App', value: 'Swock VPN'),
            SizedBox(height: 10),
            _InfoRow(label: 'Protocol', value: 'Swock custom tunnel'),
            SizedBox(height: 10),
            _InfoRow(label: 'Transport', value: 'TCP / WebSocket / TLS'),
            SizedBox(height: 10),
            _InfoRow(
              label: 'DNS',
              value: 'Primary, secondary, tertiary values if enabled',
            ),
            SizedBox(height: 10),
            _InfoRow(label: 'Status', value: 'Connected/Disconnected'),
          ],
        ),
      ),
    ],
  );

  Future<void> _clearLogs() async {
    try {
      await _vpnService.clearVpnLogs();
    } on MissingPluginException {
      // The native bridge is unavailable in widget tests.
    } on PlatformException {
      // The visible log is still cleared below.
    }
    if (mounted) setState(_logs.clear);
  }

  Widget _logsPage() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 12, 4),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'SESSION ACTIVITY',
                  style: TextStyle(
                    color: _muted,
                    fontFamily: 'monospace',
                    letterSpacing: 1.4,
                  ),
                ),
              ),
              TextButton(
                onPressed: _logs.isEmpty ? null : _clearLogs,
                child: const Text('Clear'),
              ),
            ],
          ),
        ),
        const Divider(color: _line, height: 1),
        Expanded(
          child:
              _logs.isEmpty
                  ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(28),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.description_outlined,
                            size: 54,
                            color: _faint,
                          ),
                          SizedBox(height: 24),
                          Text(
                            '[ NO LOGS ]',
                            style: TextStyle(
                              color: _muted,
                              fontFamily: 'monospace',
                              letterSpacing: 2,
                            ),
                          ),
                          SizedBox(height: 12),
                          Text(
                            'No logs available.',
                            style: TextStyle(color: _muted),
                          ),
                          SizedBox(height: 12),
                          Text(
                            'Connect or manage a profile to see activity here.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: _muted, height: 1.45),
                          ),
                        ],
                      ),
                    ),
                  )
                  : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                    itemCount: _logs.length,
                    separatorBuilder:
                        (context, index) => const Divider(color: _line, height: 1),
                    itemBuilder: (context, index) {
                      final entry = _logs[index];
                      return ListTile(
                        contentPadding: const EdgeInsets.symmetric(vertical: 5),
                        leading: const Icon(Icons.info_outline, color: _faint),
                        title: Text(
                          entry.message,
                          style: const TextStyle(fontSize: 14),
                        ),
                        subtitle: Text(
                          _formatDateTime(entry.time),
                          style: const TextStyle(color: _muted, fontSize: 12),
                        ),
                      );
                    },
                  ),
        ),
      ],
    );
  }
}

const _inkColor = Color(0xFFE2E8E4);

class _PowerControl extends StatefulWidget {
  const _PowerControl({
    required this.size,
    required this.state,
    required this.onPressed,
  });

  final double size;
  final String state;
  final VoidCallback onPressed;

  @override
  State<_PowerControl> createState() => _PowerControlState();
}

class _PowerControlState extends State<_PowerControl>
    with SingleTickerProviderStateMixin {
  late final AnimationController _effect = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1550),
  );

  bool get _animating => widget.state != 'disconnected';

  @override
  void initState() {
    super.initState();
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant _PowerControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) _syncAnimation();
  }

  void _syncAnimation() {
    if (_animating) {
      _effect.repeat();
    } else {
      _effect.stop();
      _effect.value = 0;
    }
  }

  @override
  void dispose() {
    _effect.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = _stateColor(widget.state);
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _effect,
        builder:
            (context, child) => CustomPaint(
              painter: _PowerRipplePainter(
                progress: _effect.value,
                color: color,
                active: _animating,
              ),
              child: Center(
                child: Material(
                  color: _surface,
                  shape: CircleBorder(
                    side: BorderSide(
                      color: color.withValues(alpha: .65),
                      width: 1.3,
                    ),
                  ),
                  elevation: widget.state == 'connected' ? 10 : 2,
                  shadowColor: color.withValues(alpha: .32),
                  child: InkWell(
                    onTap: widget.onPressed,
                    customBorder: const CircleBorder(),
                    splashColor: color.withValues(alpha: .28),
                    highlightColor: color.withValues(alpha: .1),
                    child: SizedBox.square(
                      dimension: widget.size * .8,
                      child: ClipOval(
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            if (widget.state == 'connecting' ||
                                widget.state == 'reconnecting')
                              Positioned.fill(
                                child: CustomPaint(
                                  painter: _WaterFillPainter(
                                    progress: _effect.value,
                                    color: color,
                                  ),
                                ),
                              ),
                            Icon(
                              Icons.power_settings_new,
                              size: widget.size * .3,
                              color: color,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
      ),
    );
  }
}

class _PowerRipplePainter extends CustomPainter {
  const _PowerRipplePainter({
    required this.progress,
    required this.color,
    required this.active,
  });

  final double progress;
  final Color color;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    if (!active) return;
    final center = Offset(size.width / 2, size.height / 2);
    for (var ring = 0; ring < 3; ring++) {
      final phase = (progress + ring / 3) % 1;
      final radius = 68 + phase * 19;
      final paint =
          Paint()
            ..color = color.withValues(alpha: (1 - phase) * .27)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5 + (1 - phase);
      canvas.drawCircle(center, radius, paint);
    }
    final sparkPaint =
        Paint()
          ..color = color.withValues(alpha: .25 + .4 * (1 - progress))
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round;
    for (var spark = 0; spark < 10; spark++) {
      final angle = (spark * 0.628) + progress * 1.3;
      final innerRadius = 73.0;
      final travel = 6 + ((spark + progress * 10) % 5) * 2;
      final start = Offset(
        center.dx + math.cos(angle) * innerRadius,
        center.dy + math.sin(angle) * innerRadius,
      );
      final end = Offset(
        center.dx + math.cos(angle) * (innerRadius + travel),
        center.dy + math.sin(angle) * (innerRadius + travel),
      );
      canvas.drawLine(start, end, sparkPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _PowerRipplePainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.color != color ||
      oldDelegate.active != active;
}

class _WaterFillPainter extends CustomPainter {
  const _WaterFillPainter({required this.progress, required this.color});

  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final level =
        size.height *
        (.72 - .24 * ((math.sin(progress * math.pi * 2) + 1) / 2));
    final path = Path()..moveTo(0, level);
    for (var step = 0; step <= 24; step++) {
      final x = size.width * step / 24;
      final wave =
          math.sin((step / 24 * math.pi * 2) + progress * math.pi * 2) * 4;
      path.lineTo(x, level + wave);
    }
    path
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(path, Paint()..color = color.withValues(alpha: .22));
  }

  @override
  bool shouldRepaint(covariant _WaterFillPainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.color != color;
}

class _ConnectionCloud extends StatefulWidget {
  const _ConnectionCloud({required this.state});
  final String state;

  @override
  State<_ConnectionCloud> createState() => _ConnectionCloudState();
}

class _ConnectionCloudState extends State<_ConnectionCloud>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1250),
  );

  @override
  void initState() {
    super.initState();
    _syncPulse();
  }

  @override
  void didUpdateWidget(covariant _ConnectionCloud oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) _syncPulse();
  }

  void _syncPulse() {
    if (widget.state == 'disconnected') {
      _pulse.stop();
      _pulse.value = 0;
    } else {
      _pulse.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = _stateColor(widget.state);
    return AnimatedBuilder(
      animation: _pulse,
      builder:
          (context, child) => AnimatedContainer(
            duration: const Duration(milliseconds: 360),
            width: 54,
            height: 54,
            decoration: BoxDecoration(
              color: color.withValues(alpha: .08 + .08 * _pulse.value),
              shape: BoxShape.circle,
              boxShadow:
                  widget.state == 'disconnected'
                      ? const []
                      : [
                        BoxShadow(
                          color: color.withValues(
                            alpha: .12 + .24 * _pulse.value,
                          ),
                          blurRadius: 10 + 8 * _pulse.value,
                        ),
                      ],
            ),
            child: Icon(
              Icons.cloud_outlined,
              color: color.withValues(alpha: .65 + .35 * _pulse.value),
            ),
          ),
    );
  }
}

String _transportSummary(VpnProfile profile) {
  final webSocket =
      profile.webSocket.enabled ||
      profile.transport == TransportMode.websocket ||
      profile.transport == TransportMode.websocketTls;
  final tls =
      profile.tls.enabled || profile.transport == TransportMode.websocketTls;
  if (webSocket && tls) return 'ws+tls';
  if (webSocket) return 'ws';
  if (tls) return 'tls';
  return profile.transport == TransportMode.auto ? 'auto' : 'tcp';
}

class _BrandHeader extends StatelessWidget {
  const _BrandHeader();

  @override
  Widget build(BuildContext context) => const Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        'SWOCK',
        style: TextStyle(
          color: _green,
          fontFamily: 'monospace',
          fontSize: 16,
          fontWeight: FontWeight.w600,
          letterSpacing: 4,
        ),
      ),
      SizedBox(height: 3),
      Text(
        'Developed By: Verdantix Digital',
        style: TextStyle(
          color: _muted,
          fontFamily: 'monospace',
          fontSize: 8.5,
          letterSpacing: .15,
        ),
      ),
    ],
  );
}

class _BottomTabs extends StatelessWidget {
  const _BottomTabs({required this.selected, required this.onSelected});

  final int selected;
  final ValueChanged<int> onSelected;

  static const _tabs = [
    (Icons.home_outlined, 'Home'),
    (Icons.cloud_outlined, 'Configs'),
    (Icons.bar_chart_rounded, 'Stats'),
    (Icons.info_outline_rounded, 'Info'),
    (Icons.description_outlined, 'Logs'),
  ];
  static const _barHeight = 50.0;
  static const _bubbleSize = 40.0;

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    return SizedBox(
      height: _barHeight + bottomInset,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final slot = constraints.maxWidth / _tabs.length;
          return TweenAnimationBuilder<double>(
            tween: Tween<double>(end: selected.toDouble()),
            duration: const Duration(milliseconds: 420),
            curve: Curves.easeInOutCubic,
            builder: (context, position, _) {
              final centerX = (position + .5) * slot;
              return Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: const BoxDecoration(
                        color: _surface,
                        border: Border(top: BorderSide(color: _line)),
                      ),
                    ),
                  ),
                  for (var index = 0; index < _tabs.length; index++) ...[
                    Positioned(
                      left: index * slot,
                      width: slot,
                      top: 0,
                      height: _barHeight,
                      child: Semantics(
                        button: true,
                        selected: selected == index,
                        label: _tabs[index].$2,
                        child: InkResponse(
                          onTap: () => onSelected(index),
                          radius: slot / 2,
                          splashColor: Colors.transparent,
                          highlightColor: Colors.transparent,
                          hoverColor: Colors.transparent,
                          splashFactory: NoSplash.splashFactory,
                          child: Center(
                            child: AnimatedOpacity(
                              duration: const Duration(milliseconds: 180),
                              opacity: selected == index ? 0 : 1,
                              child: Icon(
                                _tabs[index].$1,
                                color: _muted,
                                size: 23,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                  Positioned(
                    left: centerX - _bubbleSize / 2,
                    top: (_barHeight - _bubbleSize) / 2,
                    child: IgnorePointer(
                      child: Container(
                        width: _bubbleSize,
                        height: _bubbleSize,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: const Color(0xFF087E8A),
                          border: Border.all(
                            color: _green.withValues(alpha: .32),
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(
                                0xFF087E8A,
                              ).withValues(alpha: .2),
                              blurRadius: 10,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: Center(
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 220),
                            child: Icon(
                              _tabs[selected].$1,
                              key: ValueKey(selected),
                              color: const Color(0xFFE6FFFF),
                              size: 22,
                              semanticLabel: _tabs[selected].$2,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: const TextStyle(
      color: _muted,
      fontFamily: 'monospace',
      fontSize: 11,
      letterSpacing: 1.8,
    ),
  );
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SizedBox(
        width: 66,
        child: Text(
          label,
          style: const TextStyle(
            color: _inkColor,
            fontWeight: FontWeight.w600,
            fontSize: 13,
          ),
        ),
      ),
      Expanded(
        child: Text(value, style: const TextStyle(color: _muted, fontSize: 13)),
      ),
    ],
  );
}

class _AddOptionButton extends StatelessWidget {
  const _AddOptionButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 176,
    height: 42,
    child: TextButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, color: _green, size: 18),
      label: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          label,
          style: const TextStyle(color: _inkColor, fontSize: 13),
        ),
      ),
      style: TextButton.styleFrom(
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 16),
      ),
    ),
  );
}

class _ProfileGroupHeader extends StatelessWidget {
  const _ProfileGroupHeader({required this.title, required this.count});
  final String title;
  final int count;

  @override
  Widget build(BuildContext context) => Container(
    height: 48,
    margin: const EdgeInsets.only(bottom: 8),
    padding: const EdgeInsets.symmetric(horizontal: 14),
    decoration: BoxDecoration(
      color: const Color(0xFF1A201C),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Row(
      children: [
        const Icon(Icons.keyboard_arrow_down, color: _muted),
        const SizedBox(width: 8),
        Text(title, style: const TextStyle(fontWeight: FontWeight.w500)),
        const SizedBox(width: 8),
        Text(
          '($count)',
          style: const TextStyle(
            color: _muted,
            fontFamily: 'monospace',
            fontSize: 12,
          ),
        ),
      ],
    ),
  );
}

class _AppLog {
  const _AppLog(this.time, this.message);
  final DateTime time;
  final String message;
}

class _ProfileEditorDialog extends StatefulWidget {
  const _ProfileEditorDialog({this.profile});
  final VpnProfile? profile;

  @override
  State<_ProfileEditorDialog> createState() => _ProfileEditorDialogState();
}

class _ProfileEditorDialogState extends State<_ProfileEditorDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _server;
  late final TextEditingController _port;
  late final TextEditingController _publicKey;
  late final TextEditingController _privateKey;
  late final TextEditingController _tunnelAddress;
  late final TextEditingController _uuid;
  late final TextEditingController _password;
  late final TextEditingController _flow;
  late final TextEditingController _alterId;
  late final TextEditingController _notes;
  late final TextEditingController _webSocketHost;
  late final TextEditingController _webSocketPath;
  late final TextEditingController _tlsSni;
  late final TextEditingController _tlsVerifyName;
  late final TextEditingController _dnsPrimary;
  late final TextEditingController _dnsSecondary;
  late final TextEditingController _dnsTertiary;
  late VpnProtocol _protocol;
  late TransportMode _transport;
  late bool _webSocketEnabled;
  late bool _tlsEnabled;
  late bool _allowTlsHostnameMismatch;
  late bool _dnsEnabled;

  @override
  void initState() {
    super.initState();
    final profile = widget.profile;
    _name = TextEditingController(text: profile?.name ?? '');
    _server = TextEditingController(text: profile?.server ?? '');
    _port = TextEditingController(text: profile?.port.toString() ?? '443');
    _protocol = profile?.protocol ?? VpnProtocol.swock;
    _publicKey = TextEditingController(text: profile?.serverPublicKey ?? '');
    _privateKey = TextEditingController(text: profile?.clientPrivateKey ?? '');
    _tunnelAddress = TextEditingController(text: profile?.tunnelAddress ?? '');
    _uuid = TextEditingController(text: profile?.uuid ?? '');
    _password = TextEditingController(text: profile?.password ?? '');
    _flow = TextEditingController(text: profile?.flow ?? '');
    _alterId = TextEditingController(text: profile?.alterId.toString() ?? '0');
    _notes = TextEditingController(text: profile?.notes ?? '');
    _webSocketHost = TextEditingController(text: profile?.webSocket.host ?? '');
    _webSocketPath = TextEditingController(
      text: profile?.webSocket.path ?? '/',
    );
    _tlsSni = TextEditingController(text: profile?.tls.sni ?? '');
    _tlsVerifyName = TextEditingController(
      text: profile?.tls.serverName ?? '',
    );
    _dnsPrimary = TextEditingController(text: profile?.dns.primary ?? '');
    _dnsSecondary = TextEditingController(text: profile?.dns.secondary ?? '');
    _dnsTertiary = TextEditingController(text: profile?.dns.tertiary ?? '');
    _transport = profile?.transport ?? TransportMode.auto;
    _webSocketEnabled =
        profile?.webSocket.enabled == true ||
        profile?.transport == TransportMode.websocket ||
        profile?.transport == TransportMode.websocketTls;
    _tlsEnabled =
        profile?.tls.enabled == true ||
        profile?.transport == TransportMode.websocketTls;
    _allowTlsHostnameMismatch =
      profile?.tls.allowInsecureCertificate ?? false;
    _dnsEnabled = profile?.dns.enabled ?? false;
  }

  @override
  void dispose() {
    _name.dispose();
    _server.dispose();
    _port.dispose();
    _publicKey.dispose();
    _privateKey.dispose();
    _tunnelAddress.dispose();
    _uuid.dispose();
    _password.dispose();
    _flow.dispose();
    _alterId.dispose();
    _notes.dispose();
    _webSocketHost.dispose();
    _webSocketPath.dispose();
    _tlsSni.dispose();
    _tlsVerifyName.dispose();
    _dnsPrimary.dispose();
    _dnsSecondary.dispose();
    _dnsTertiary.dispose();
    super.dispose();
  }

  String? _required(String? value, String label) =>
      value == null || value.trim().isEmpty ? '$label is required.' : null;

  String? _keyValidation(String? value, String label) {
    if (_protocol != VpnProtocol.swock) return null;
    if (value == null || value.trim().isEmpty) return '$label is required.';
    if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(value.trim())) {
      return 'Enter exactly 64 hexadecimal characters.';
    }
    return null;
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    final now = DateTime.now();
    final original = widget.profile;
    final wsHost = _webSocketHost.text.trim();
    final sniHost = _tlsSni.text.trim().isEmpty ? wsHost : _tlsSni.text.trim();
    Navigator.pop(
      context,
      VpnProfile(
        id: original?.id ?? const Uuid().v4(),
        name: _name.text.trim(),
        server: _server.text.trim(),
        port: int.parse(_port.text.trim()),
        protocol: _protocol,
        serverPublicKey: _publicKey.text.trim().toLowerCase(),
        clientPrivateKey: _privateKey.text.trim().toLowerCase(),
        tunnelAddress: _tunnelAddress.text.trim(),
        uuid: _uuid.text.trim(),
        password: _password.text.trim(),
        flow: _flow.text.trim(),
        alterId: int.tryParse(_alterId.text.trim()) ?? 0,
        cipher: original?.cipher ?? 'chacha20-poly1305',
        transport: _transport,
        webSocket: WebSocketConfig(
          enabled: _webSocketEnabled,
          host: wsHost,
          path:
              _webSocketPath.text.trim().isEmpty
                  ? '/'
                  : _webSocketPath.text.trim(),
          headers: original?.webSocket.headers ?? const {},
          connectionOptions: original?.webSocket.connectionOptions ?? const {},
        ),
        tls: TlsConfig(
          enabled: _tlsEnabled,
          sni: sniHost,
          serverName: _tlsVerifyName.text.trim().isEmpty ? sniHost : _tlsVerifyName.text.trim(),
          allowInsecureCertificate: _allowTlsHostnameMismatch,
          alpn: original?.tls.alpn ?? const [],
        ),
        proxy: original?.proxy ?? const ProxyConfig(),
        dns: DnsConfig(
          enabled: _dnsEnabled,
          primary: _dnsPrimary.text.trim(),
          secondary: _dnsSecondary.text.trim(),
          tertiary: _dnsTertiary.text.trim(),
        ),
        encryption: original?.encryption ?? const EncryptionConfig(),
        metadata: original?.metadata ?? '',
        createdAt: original?.createdAt ?? now,
        lastUsedAt: now,
        favorite: original?.favorite ?? false,
        notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
        isSelected: original?.isSelected ?? false,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
    title: Text(
      widget.profile == null ? 'Add configuration' : 'Edit configuration',
    ),
    content: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 440),
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _name,
                decoration: const InputDecoration(
                  labelText: 'Remarks / profile name',
                ),
                validator: (value) => _required(value, 'Profile name'),
                textCapitalization: TextCapitalization.words,
              ),
              const SizedBox(height: 14),
              DropdownButtonFormField<VpnProtocol>(
                initialValue: _protocol,
                decoration: const InputDecoration(labelText: 'Protocol'),
                items: const [
                  DropdownMenuItem(
                    value: VpnProtocol.swock,
                    child: Text('Swock (Native)'),
                  ),
                  DropdownMenuItem(
                    value: VpnProtocol.vless,
                    child: Text('VLESS'),
                  ),
                  DropdownMenuItem(
                    value: VpnProtocol.vmess,
                    child: Text('VMess'),
                  ),
                  DropdownMenuItem(
                    value: VpnProtocol.trojan,
                    child: Text('Trojan'),
                  ),
                  DropdownMenuItem(
                    value: VpnProtocol.shadowsocks,
                    child: Text('Shadowsocks'),
                  ),
                ],
                onChanged:
                    (value) => setState(
                      () => _protocol = value ?? VpnProtocol.swock,
                    ),
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _server,
                decoration: const InputDecoration(
                  labelText: 'Address / server host',
                ),
                validator: (value) => _required(value, 'Server'),
                keyboardType: TextInputType.url,
                autocorrect: false,
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _port,
                decoration: const InputDecoration(labelText: 'Port'),
                validator: (value) {
                  final port = int.tryParse(value?.trim() ?? '');
                  if (port == null || port < 1 || port > 65535) {
                    return 'Enter a port from 1 to 65535.';
                  }
                  return null;
                },
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 14),
              if (_protocol == VpnProtocol.vless || _protocol == VpnProtocol.vmess) ...[
                TextFormField(
                  controller: _uuid,
                  decoration: const InputDecoration(
                    labelText: 'User ID / UUID',
                  ),
                  validator: (value) => _required(value, 'UUID'),
                  autocorrect: false,
                ),
                const SizedBox(height: 14),
              ],
              if (_protocol == VpnProtocol.vless) ...[
                TextFormField(
                  controller: _flow,
                  decoration: const InputDecoration(
                    labelText: 'Flow (optional)',
                    hintText: 'xtls-rprx-vision',
                  ),
                  autocorrect: false,
                ),
                const SizedBox(height: 14),
              ],
              if (_protocol == VpnProtocol.vmess) ...[
                TextFormField(
                  controller: _alterId,
                  decoration: const InputDecoration(
                    labelText: 'AlterId',
                    hintText: '0',
                  ),
                  keyboardType: TextInputType.number,
                ),
                const SizedBox(height: 14),
              ],
              if (_protocol == VpnProtocol.trojan || _protocol == VpnProtocol.shadowsocks) ...[
                TextFormField(
                  controller: _password,
                  decoration: const InputDecoration(
                    labelText: 'Password / Key',
                  ),
                  validator: (value) => _required(value, 'Password'),
                  obscureText: true,
                  autocorrect: false,
                ),
                const SizedBox(height: 14),
              ],
              DropdownButtonFormField<TransportMode>(
                initialValue: _transport,
                decoration: const InputDecoration(labelText: 'Transport'),
                items: const [
                  DropdownMenuItem(
                    value: TransportMode.auto,
                    child: Text('Auto'),
                  ),
                  DropdownMenuItem(
                    value: TransportMode.tcp,
                    child: Text('TCP'),
                  ),
                  DropdownMenuItem(
                    value: TransportMode.websocket,
                    child: Text('WebSocket'),
                  ),
                  DropdownMenuItem(
                    value: TransportMode.websocketTls,
                    child: Text('WebSocket + TLS'),
                  ),
                ],
                onChanged:
                    (value) => setState(
                      () => _transport = value ?? TransportMode.auto,
                    ),
              ),
              const SizedBox(height: 14),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('WebSocket'),
                value: _webSocketEnabled,
                activeThumbColor: _green,
                onChanged: (value) => setState(() => _webSocketEnabled = value),
              ),
              if (_webSocketEnabled) ...[
                TextFormField(
                  controller: _webSocketHost,
                  decoration: const InputDecoration(
                    labelText: 'WebSocket host header (optional)',
                  ),
                  autocorrect: false,
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _webSocketPath,
                  decoration: const InputDecoration(
                    labelText: 'WebSocket path',
                    hintText: '/',
                  ),
                  validator:
                      (value) =>
                          value != null &&
                                  value.trim().isNotEmpty &&
                                  !value.trim().startsWith('/')
                              ? 'WebSocket path must start with /.'
                              : null,
                  autocorrect: false,
                ),
                const SizedBox(height: 14),
              ],
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('TLS'),
                value: _tlsEnabled,
                activeThumbColor: _green,
                onChanged: (value) => setState(() => _tlsEnabled = value),
              ),
              if (_tlsEnabled) ...[
                TextFormField(
                  controller: _tlsSni,
                  decoration: const InputDecoration(
                    labelText: 'TLS SNI hostname (optional)',
                    hintText: 'swock-server-host',
                    helperText:
                        'The hostname sent to the TLS server for virtual-host routing.',
                  ),
                  autocorrect: false,
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _tlsVerifyName,
                  decoration: const InputDecoration(
                    labelText: 'Certificate hostname',
                    hintText: 'hostname on the TLS certificate',
                    helperText:
                      'Must match the certificate. Leave blank to verify the SNI hostname, or the server address if SNI is blank.',
                  ),
                  autocorrect: false,
                ),
                const SizedBox(height: 14),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Allow certificate hostname mismatch'),
                  subtitle: const Text(
                    'Less secure. The certificate must still chain to a trusted issuer.',
                  ),
                  value: _allowTlsHostnameMismatch,
                  activeThumbColor: _green,
                  onChanged:
                      (value) =>
                          setState(() => _allowTlsHostnameMismatch = value),
                ),
                const SizedBox(height: 14),
              ],
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('Custom DNS'),
                value: _dnsEnabled,
                activeThumbColor: _green,
                onChanged: (value) => setState(() => _dnsEnabled = value),
              ),
              if (_dnsEnabled) ...[
                _dnsField(_dnsPrimary, 'DNS server 1', required: true),
                const SizedBox(height: 14),
                _dnsField(_dnsSecondary, 'DNS server 2'),
                const SizedBox(height: 14),
                _dnsField(_dnsTertiary, 'DNS server 3'),
                const SizedBox(height: 14),
              ],
              if (_protocol == VpnProtocol.swock) ...[
                TextFormField(
                  controller: _publicKey,
                  decoration: const InputDecoration(
                    labelText: 'Server public key (X25519 hex)',
                  ),
                  validator:
                      (value) => _keyValidation(value, 'Server public key'),
                  autocorrect: false,
                  enableSuggestions: false,
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _privateKey,
                  decoration: const InputDecoration(
                    labelText: 'Client private key (X25519 hex)',
                  ),
                  validator:
                      (value) => _keyValidation(value, 'Client private key'),
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _tunnelAddress,
                  decoration: const InputDecoration(
                    labelText: 'Assigned tunnel IP (SWK2)',
                    hintText: 'Assigned by the Swock VPS panel',
                  ),
                  validator: (value) {
                    final address = value?.trim() ?? '';
                    if (address.isEmpty) {
                      return 'Required for SWK2. Import a current profile URI from the VPS panel.';
                    }
                    if (!RegExp(
                      r'^10\.8\.0\.(?:[2-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-4])$',
                    ).hasMatch(address)) {
                      return 'Use the assigned address from the account profile.';
                    }
                    return null;
                  },
                  keyboardType: TextInputType.number,
                ),
                const SizedBox(height: 14),
              ],
              TextFormField(
                controller: _notes,
                decoration: const InputDecoration(
                  labelText: 'Notes (optional)',
                ),
                maxLines: 2,
                textCapitalization: TextCapitalization.sentences,
              ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _submit,
        child: Text(widget.profile == null ? 'Save' : 'Save changes'),
      ),
    ],
  );

  Widget _dnsField(
    TextEditingController controller,
    String label, {
    bool required = false,
  }) => TextFormField(
    controller: controller,
    keyboardType: TextInputType.url,
    autocorrect: false,
    decoration: InputDecoration(labelText: label),
    validator: (value) {
      final address = value?.trim() ?? '';
      if (required && address.isEmpty) {
        return 'At least one DNS server is required.';
      }
      if (address.isNotEmpty && InternetAddress.tryParse(address) == null) {
        return 'Enter an IPv4 or IPv6 address.';
      }
      return null;
    },
  );
}

String _formatTime(DateTime time) =>
    '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

String _formatDateTime(DateTime time) =>
    '${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')} ${_formatTime(time)}';

String _formatDuration(int milliseconds) {
  final seconds = milliseconds ~/ 1000;
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  final remainder = seconds % 60;
  if (hours > 0) return '${hours}h ${minutes}m';
  if (minutes > 0) return '${minutes}m ${remainder}s';
  return '${remainder}s';
}

String _formatSpeed(double bytesPerSecond) {
  if (bytesPerSecond <= 0) return '0 B/s';
  if (bytesPerSecond >= 1024 * 1024) {
    return '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(1)} MB/s';
  }
  if (bytesPerSecond >= 1024) {
    return '${(bytesPerSecond / 1024).toStringAsFixed(1)} KB/s';
  }
  return '${bytesPerSecond.toStringAsFixed(0)} B/s';
}
