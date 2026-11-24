import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../../models/vpn_profile.dart';
import '../../services/ad_service.dart';
import '../../services/channel_prompt_service.dart';
import '../../services/dvs_file_service.dart';
import '../../services/native_vpn_service.dart';
import '../../services/profile_service.dart';
import '../../services/sock_uri_service.dart';
import '../../services/xray_json_service.dart';
import '../../services/time_bank_service.dart';
import '../settings/settings_screen.dart';
import '../tools/game_screen.dart';
import 'app_tutorial.dart';
import 'native_ad_strip.dart';
import 'time_widgets.dart';

const _background = Color(0xFF080B09);
const _surface = Color(0xFF101512);
const _line = Color(0xFF39413B);
const _muted = Color(0xFFA7B0AA);
const _faint = Color(0xFF77817A);
const _green = Color(0xFF55E89A);

class _DvsExportOptions {
  const _DvsExportOptions(
      {required this.locked, this.expiresAt, this.password});

  final bool locked;
  final DateTime? expiresAt;
  final String? password;
}

String _stateLabel(String state) => switch (state) {
      'connected' => 'CONNECTED',
      'connecting' => 'CONNECTING',
      'reconnecting' => 'RECONNECTING',
      'disconnecting' => 'DISCONNECTING',
      'error' => 'RETRYING CONNECTION',
      _ => 'DISCONNECTED',
    };

bool _isNativeSingboxConfig(String value) {
  try {
    return isSingboxJson(parseXrayJson(value));
  } on FormatException {
    return false;
  }
}

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
  final _dvsFileService = DvsFileService();
  final _channelPrompt = ChannelPromptService();
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
  bool get _vpnLocked =>
      _connectionState != 'disconnected' && _connectionState != 'error';

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
    await _showChannelPromptIfNeeded();
    await _initializeAds();
  }

  Future<void> _showChannelPromptIfNeeded() async {
    if (!await _channelPrompt.shouldShow()) return;
    await Future<void>.delayed(const Duration(milliseconds: 450));
    if (!mounted) return;

    final joined = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) => Dialog(
        backgroundColor: const Color(0xFF101713),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: _green.withValues(alpha: .45)),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 430),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 22),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Align(
                  alignment: Alignment.topRight,
                  child: IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(dialogContext).pop(false),
                    icon: const Icon(Icons.close_rounded),
                    color: _muted,
                  ),
                ),
                Container(
                  width: 76,
                  height: 76,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        _green.withValues(alpha: .28),
                        const Color(0xFF1C83E5).withValues(alpha: .22),
                      ],
                    ),
                    border: Border.all(
                      color: _green.withValues(alpha: .65),
                      width: 1.2,
                    ),
                  ),
                  child: const Icon(
                    Icons.campaign_rounded,
                    color: Color(0xFF66B8FF),
                    size: 42,
                  ),
                ),
                const SizedBox(height: 18),
                const Text(
                  'SWOCK OFFICIAL CHANNEL',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: _green,
                    fontFamily: 'monospace',
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.8,
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Join Swock Official Channel\nLearn How Create Accounts And Get New Updates',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Color(0xFFE8EEE9),
                    fontSize: 17,
                    height: 1.35,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 22),
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: FilledButton.icon(
                    onPressed: () => Navigator.of(dialogContext).pop(true),
                    icon: const Icon(Icons.open_in_new_rounded),
                    label: const Text(
                      'Join Channel',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        letterSpacing: .3,
                      ),
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: _green,
                      foregroundColor: const Color(0xFF07120B),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (joined == true) {
      final opened = await _vpnService.openExternalUrl(
        ChannelPromptService.channelUrl,
      );
      if (opened) {
        await _channelPrompt.markJoined();
      }
    } else {
      await _channelPrompt.markDismissed();
    }
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
      var changed = false;
      if (profiles.isNotEmpty &&
          !profiles.any((profile) => profile.isSelected)) {
        profiles[0] = profiles[0].copyWith(isSelected: true);
        changed = true;
      }
      if (changed) await _profileService.saveProfiles(profiles);
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
      final elapsed = previousAt == null
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
          _downloadSpeed = ((downloadBytes - _previousDownloadBytes!) / elapsed)
              .clamp(0, double.infinity)
              .toDouble();
        } else if (!isConnected) {
          _downloadSpeed = 0;
        }
        if (isConnected &&
            elapsed > 0 &&
            uploadBytes != null &&
            _previousUploadBytes != null) {
          _uploadSpeed = ((uploadBytes - _previousUploadBytes!) / elapsed)
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
        unawaited(_showConnectionInterstitial());
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
      final timestamp = timestampMs == null
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
    final next = _profiles
        .map(
          (profile) => profile.copyWith(isSelected: profile.id == selected.id),
        )
        .toList();
    await _saveProfiles(next);
  }

  Future<void> _openEditor({VpnProfile? profile}) async {
    if (_vpnLocked) return;
    if (profile?.isLocked == true) {
      _message('This profile is locked. It can only be deleted.');
      return;
    }
    final result = await showDialog<VpnProfile>(
      context: context,
      builder: (context) => _ProfileEditorDialog(profile: profile),
    );
    if (result == null) return;
    final exists = _profiles.any((item) => item.id == result.id);
    var next = exists
        ? _profiles.map((item) => item.id == result.id ? result : item).toList()
        : [..._profiles, result.copyWith(isSelected: _profiles.isEmpty)];
    if (_profiles.isEmpty && next.isNotEmpty) {
      next = next
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
    if (profile.isLocked) {
      _message('Locked profiles cannot be deleted.');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
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
    if (profile.isLocked) {
      _message('Locked profiles cannot be shared.');
      return;
    }
    if (profile.protocol == VpnProtocol.ssh) {
      _message(
        'SSH profiles include SSH-specific credentials and tunnel options. Export the profile to preserve them.',
      );
      return;
    }
    final singboxJson = profile.xrayConfig.trim().isNotEmpty &&
        _isNativeSingboxConfig(profile.xrayConfig);
    final configName = singboxJson ? 'Sing-box' : 'Xray';
    if (profile.protocol == VpnProtocol.xray &&
        profile.xrayConfig.trim().isEmpty &&
        profile.xrayShareLink.trim().isEmpty) {
      _message(
          'Add a $configName JSON configuration or import a proxy share link first.');
      return;
    }
    final shareText = profile.xrayShareLink.trim().isNotEmpty
        ? profile.xrayShareLink.trim()
        : profile.xrayConfig.trim().isNotEmpty
            ? profile.xrayConfig.trim()
            : const JsonEncoder.withIndent('  ')
                .convert(_xrayConfigFromProfile(profile));
    await Clipboard.setData(ClipboardData(text: shareText));
    final protocolName = switch (profile.protocol) {
      VpnProtocol.directProxy => 'Direct proxy',
      VpnProtocol.hysteria2 => 'Hysteria 2',
      VpnProtocol.xray => '$configName JSON',
      _ => profile.protocol.name.toUpperCase(),
    };
    final contentType = profile.xrayShareLink.trim().isNotEmpty
        ? '$protocolName share link'
        : profile.xrayConfig.trim().isNotEmpty ||
                profile.protocol == VpnProtocol.xray
            ? '$configName JSON configuration'
            : '$protocolName profile as Xray JSON';
    await Clipboard.setData(ClipboardData(text: shareText));
    _message('$contentType copied. It contains proxy credentials.');
  }

  Future<void> _showImportDialog() async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Import VPN profile'),
        content: TextField(
          controller: controller,
          minLines: 3,
          maxLines: 6,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(
            hintText:
                'SSH profile URI, proxy share link, Xray JSON, or Sing-box JSON…',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton.icon(
            onPressed: () async {
              final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
              if (!context.mounted) return;
              final text = clipboard?.text?.trim();
              if (text == null || text.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                      content: Text('The clipboard has no text to import.')),
                );
                return;
              }
              Navigator.pop(context, text);
            },
            icon: const Icon(Icons.content_paste),
            label: const Text('Import clipboard'),
          ),
          TextButton.icon(
            onPressed: () => Navigator.pop(context, '__pick_profile_file__'),
            icon: const Icon(Icons.folder_open),
            label: const Text('Import profile file'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Import'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == '__pick_profile_file__') {
      await _importProfileFile();
      return;
    }
    if (value == null || value.trim().isEmpty) return;
    await _importProfile(value);
  }

  Future<void> _importProfileFile() async {
    if (_vpnLocked) return;
    try {
      final contents = await _vpnService.importProfileFile();
      if (contents == null || contents.isEmpty) return;
      await _importProfile(contents);
    } on PlatformException catch (error) {
      _message(error.message ?? 'Could not read the selected profile file.');
    } catch (error) {
      _message('Could not import the selected profile file: $error');
    }
  }

  Future<void> _exportDvsFile(VpnProfile profile) async {
    if (profile.isLocked) {
      _message('Locked profiles cannot be exported.');
      return;
    }
    if (profile.isLocked) {
      _message('Locked profiles cannot be exported or shared.');
      return;
    }
    var lockFile = true;
    var protectWithPassword = false;
    var exportPassword = '';
    DateTime? expiresAt;
    final options = await showDialog<_DvsExportOptions>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Export .dvs profile'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('Lock exported profile'),
                subtitle: const Text(
                  'When imported, it can only be deleted. Editing, sharing, and re-export are disabled.',
                ),
                value: lockFile,
                onChanged: (value) => setDialogState(() => lockFile = value),
              ),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('Advanced password protection'),
                subtitle: const Text('Encrypt the exported profile file.'),
                value: protectWithPassword,
                onChanged: lockFile
                    ? (value) => setDialogState(
                          () => protectWithPassword = value,
                        )
                    : null,
              ),
              if (protectWithPassword) ...[
                TextField(
                  obscureText: true,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'File password (8 characters minimum)',
                  ),
                  onChanged: (value) => setDialogState(
                    () => exportPassword = value,
                  ),
                ),
                const SizedBox(height: 8),
              ],
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () async {
                  final now = DateTime.now();
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: expiresAt ?? now.add(const Duration(days: 30)),
                    firstDate: now,
                    lastDate: DateTime(now.year + 10),
                  );
                  if (picked != null) {
                    setDialogState(() => expiresAt = DateTime(
                          picked.year,
                          picked.month,
                          picked.day,
                          23,
                          59,
                          59,
                        ));
                  }
                },
                icon: const Icon(Icons.event),
                label: Text(expiresAt == null
                    ? 'Set expiration date (optional)'
                    : 'Expires ${MaterialLocalizations.of(context).formatMediumDate(expiresAt!)}'),
              ),
              if (expiresAt != null)
                TextButton(
                  onPressed: () => setDialogState(() => expiresAt = null),
                  child: const Text('Remove expiration date'),
                ),
              const SizedBox(height: 8),
              const Text(
                  'Swock enforces expiration after import. A locked profile can only be deleted in the app.'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: protectWithPassword && exportPassword.length < 8
                  ? null
                  : () => Navigator.pop(
                        dialogContext,
                        _DvsExportOptions(
                          locked: lockFile,
                          expiresAt: expiresAt,
                          password: protectWithPassword ? exportPassword : null,
                        ),
                      ),
              child: const Text('Choose file'),
            ),
          ],
        ),
      ),
    );
    if (options == null) return;
    final fileName = '${_safeFileName(profile.name)}.dvs';
    try {
      final saved = await _vpnService.exportDvsFile(
        fileName: fileName,
        contents: _dvsFileService.encode(
          profile,
          locked: options.locked,
          expiresAt: options.expiresAt,
          password: options.password,
        ),
      );
      if (saved) _message('Profile exported as $fileName.');
    } on PlatformException catch (error) {
      _message(error.message ?? 'Could not export the profile file.');
    } catch (error) {
      _message('Could not export the profile file: $error');
    }
  }

  String _safeFileName(String value) {
    final safe = value.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    return safe.isEmpty ? 'vpn-profile' : safe;
  }

  Future<DvsFileData?> _decodeDvs(String contents) async {
    String? password;
    if (_dvsFileService.requiresPassword(contents)) {
      final controller = TextEditingController();
      password = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Unlock profile file'),
          content: TextField(
            controller: controller,
            obscureText: true,
            autocorrect: false,
            decoration: const InputDecoration(labelText: 'File password'),
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
      if (password == null) return null;
    }
    return _dvsFileService.decode(contents, password: password);
  }

  Future<void> _importProfile(String value) async {
    if (_vpnLocked) return;
    try {
      final VpnProfile imported;
      if (_dvsFileService.isDvsFile(value)) {
        final decoded = await _decodeDvs(value);
        if (decoded == null) return;
        imported = decoded.profile.copyWith(
          id: const Uuid().v4(),
          createdAt: DateTime.now(),
          lastUsedAt: DateTime.now(),
          isSelected: _profiles.isEmpty,
        );
      } else {
        // Core JSON and supported share links/URIs go through the common
        // profile importer. Only the Swock .dvs envelope is decoded
        // by DvsFileService.
        imported = SwockUriService.importUri(value);
      }
      final selectedImport = imported.copyWith(isSelected: true);
      final next =
          _profiles.map((item) => item.copyWith(isSelected: false)).toList();
      final existing = next.indexWhere((item) => item.id == selectedImport.id);
      if (existing >= 0) {
        next[existing] = selectedImport;
      } else {
        next.add(selectedImport);
      }
      await _saveProfiles(next);
      _message(imported.isLocked
          ? 'Locked .dvs profile imported. It can only be deleted.'
          : 'Profile imported and saved.');
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
    final level = thresholds.where((t) => seconds <= t).fold<int?>(
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
    if (_addTimeBusy || _cooldownSeconds > 0) return false;
    final bank = _timeBank;
    if (bank == null) {
      _message('Your VPN timer is still loading. Try again shortly.');
      return false;
    }
    setState(() => _addTimeBusy = true);
    var granted = false;
    try {
      final completed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => RewardTimeDialog(
          showRewardAd: () async {
            if (!AdService.instance.canRequestAds) {
              await AdService.instance.initialize();
            }
            if (!AdService.instance.canRequestAds) return false;
            return AdService.instance.showTimeReward();
          },
          onRewardComplete: () async {
            await bank.add(const Duration(hours: 8), DateTime.now());
            granted = true;
            if (!mounted) return;
            setState(() {
              _remaining = bank.remaining(DateTime.now());
              _expiryHandled = false;
            });
            _warnedThresholds.clear();
            _recordVpnLog('Added 8 hours of VPN time from three rewarded ads.');
          },
        ),
      );
      if (!mounted) return granted;
      if (completed == true && granted) {
        _message('8 hours added to your VPN timer.');
        return true;
      }
      return false;
    } finally {
      if (mounted) {
        setState(() {
          _addTimeBusy = false;
          if (granted) {
            _addCooldownUntil = DateTime.now().add(
              const Duration(seconds: 15),
            );
          }
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
    if (profile.expiresAt != null &&
        !profile.expiresAt!.isAfter(DateTime.now())) {
      _message('This profile has expired and can no longer connect.');
      return;
    }
    final hasXrayData = profile.xrayShareLink.trim().isNotEmpty ||
        profile.xrayConfig.trim().isNotEmpty;
    final xrayConfigOnly = profile.xrayConfig.trim().startsWith('{');
    if (!hasXrayData &&
        !xrayConfigOnly &&
        (!profile.hasValidServer || !profile.hasValidPort)) {
      _message('Edit this profile and enter a valid server and port.');
      await _openEditor(profile: profile);
      return;
    }

    if (profile.xrayShareLink.isEmpty &&
        profile.xrayConfig.isEmpty &&
        (profile.protocol == VpnProtocol.vless ||
            profile.protocol == VpnProtocol.vmess)) {
      if (profile.uuid.trim().isEmpty) {
        _message('Edit this profile and enter a valid User ID / UUID.');
        await _openEditor(profile: profile);
        return;
      }
    } else if (profile.xrayShareLink.isEmpty &&
        profile.xrayConfig.isEmpty &&
        (profile.protocol == VpnProtocol.trojan ||
            profile.protocol == VpnProtocol.shadowsocks)) {
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
        leadingWidth: 56,
        leading: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Game launcher',
              onPressed: _openGameLauncher,
              icon: const Icon(
                Icons.sports_esports_outlined,
                color: _muted,
                size: 21,
              ),
            ),
          ],
        ),
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
          transitionBuilder: (child, animation) => FadeTransition(
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
            child: [
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
      floatingActionButton: _tab == 1 && !_vpnLocked
          ? Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                AnimatedSize(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  child: _addOptionsOpen
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
                                  onPressed: () => _chooseAddOption('manual'),
                                ),
                                const Divider(height: 1, color: _line),
                                _AddOptionButton(
                                  icon: Icons.link,
                                  label: 'Import via URI',
                                  onPressed: () => _chooseAddOption('import'),
                                ),
                                const Divider(height: 1, color: _line),
                                _AddOptionButton(
                                  icon: Icons.folder_open,
                                  label: 'Import profile file',
                                  onPressed: () => _chooseAddOption('file'),
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

  Future<void> _openGameLauncher() => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const GameScreen()),
      );

  Future<void> _chooseAddOption(String action) async {
    setState(() => _addOptionsOpen = false);
    if (action == 'manual') await _openEditor();
    if (action == 'import') await _showImportDialog();
    if (action == 'file') await _importProfileFile();
  }

  Future<void> _showPremiumDialog() => showDialog<void>(
        context: context,
        builder: (context) => Dialog(
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
      builder: (context) => AlertDialog(
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
      _rewardMessage = earned
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

  Future<void> _showConnectionInterstitial() async {
    try {
      final shown = await AdService.instance.showConnectionInterstitial();
      if (!mounted || shown || !_adsReady) return;
      _recordVpnLog('The connection interstitial was unavailable.');
    } on PlatformException catch (error) {
      if (mounted) {
        _recordVpnLog(
          error.message ?? 'Could not show the connection interstitial.',
        );
      }
    } on MissingPluginException {
      if (mounted) {
        _recordVpnLog('Connection interstitial ads are unavailable.');
      }
    }
  }

  Widget _homePage(VpnProfile? active) {
    final connected = _connectionState == 'connected';
    final duration = (_statistics['durationMs'] as num?)?.toInt() ?? 0;
    final statusText = connected
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
                  const Text('No profile selected',
                      style: TextStyle(fontSize: 15)),
                  const SizedBox(height: 3),
                  const Text(
                    'Add a proxy or Xray profile to get started in Configs.',
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
                    '*********  ·  ${_transportSummary(profile)}',
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
                    style:
                        TextStyle(fontFamily: 'monospace', letterSpacing: 1.5),
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
                _ProfileGroupHeader(
                    title: 'FAVORITES', count: favorites.length),
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
                    style: TextStyle(
                      fontSize: 14,
                      color: profile.isLocked ? _muted : null,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    profile.expiresAt != null &&
                            !profile.expiresAt!.isAfter(DateTime.now())
                        ? 'Expired · ${profile.server}:${profile.port}'
                        : '${profile.server}:${profile.port}',
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
            if (profile.isLocked)
              const Padding(
                padding: EdgeInsets.only(right: 6),
                child: Icon(Icons.lock_outline, color: _muted, size: 17),
              ),
            IconButton(
              tooltip: 'Edit ${profile.name}',
              onPressed: _vpnLocked || profile.isLocked
                  ? null
                  : () => _openEditor(profile: profile),
              icon: Icon(
                profile.isLocked ? Icons.lock_outline : Icons.edit,
                size: 19,
              ),
            ),
            PopupMenuButton<String>(
              tooltip: 'More actions for ${profile.name}',
              onSelected: (action) {
                if (action == 'share') _shareProfile(profile);
                if (action == 'export') _exportDvsFile(profile);
                if (action == 'delete') _deleteProfile(profile);
              },
              itemBuilder: (context) => [
                if (!profile.isLocked) ...[
                  const PopupMenuItem(
                    value: 'share',
                    child: ListTile(
                      leading: Icon(Icons.share_outlined),
                      title: Text('Share profile'),
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'export',
                    child: ListTile(
                      leading: Icon(Icons.file_upload_outlined),
                      title: Text('Export .dvs file'),
                    ),
                  ),
                ],
                if (!profile.isLocked)
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
          child: _logs.isEmpty
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
                  separatorBuilder: (context, index) =>
                      const Divider(color: _line, height: 1),
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
        builder: (context, child) => CustomPaint(
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
      final paint = Paint()
        ..color = color.withValues(alpha: (1 - phase) * .27)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5 + (1 - phase);
      canvas.drawCircle(center, radius, paint);
    }
    final sparkPaint = Paint()
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
    final level = size.height *
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
      builder: (context, child) => AnimatedContainer(
        duration: const Duration(milliseconds: 360),
        width: 54,
        height: 54,
        decoration: BoxDecoration(
          color: color.withValues(alpha: .08 + .08 * _pulse.value),
          shape: BoxShape.circle,
          boxShadow: widget.state == 'disconnected'
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
  if (profile.protocol == VpnProtocol.directProxy) return 'SOCKS5';
  final tls =
      profile.tls.enabled || profile.transport == TransportMode.websocketTls;
  final mode =
      profile.transport == TransportMode.auto && profile.webSocket.enabled
          ? TransportMode.websocket
          : profile.transport;
  if (mode.isWebSocket) return tls ? 'ws+tls' : 'ws';
  final label = mode == TransportMode.auto ? 'auto' : mode.label.toLowerCase();
  return tls ? '$label+tls' : label;
}

Map<String, dynamic> _xrayConfigFromProfile(VpnProfile profile) {
  final tlsEnabled =
      profile.tls.enabled || profile.transport == TransportMode.websocketTls;
  final network = profile.transport.xrayNetwork ??
      (profile.webSocket.enabled ? 'ws' : null);
  final tlsSettings = <String, dynamic>{};
  final sni =
      profile.tls.sni.trim().isEmpty ? profile.server : profile.tls.sni.trim();
  if (tlsEnabled) {
    tlsSettings['serverName'] = sni;
    if (profile.tls.allowInsecureCertificate) {
      tlsSettings['allowInsecure'] = true;
    }
    if (profile.tls.alpn.isNotEmpty) tlsSettings['alpn'] = profile.tls.alpn;
  }
  final streamSettings = <String, dynamic>{
    if (network != null) 'network': network,
    'security': tlsEnabled ? 'tls' : 'none',
  };
  if (tlsEnabled) streamSettings['tlsSettings'] = tlsSettings;
  final transportPath = profile.webSocket.path.trim();
  final transportHost = profile.webSocket.host.trim();
  final headers = <String, dynamic>{
    ...profile.webSocket.headers,
    if (transportHost.isNotEmpty) 'Host': transportHost,
  };
  switch (network) {
    case 'ws':
      streamSettings['wsSettings'] = {
        'path': transportPath,
        'headers': headers,
      };
      break;
    case 'httpupgrade':
      streamSettings['httpupgradeSettings'] = {
        'path': transportPath,
        if (transportHost.isNotEmpty) 'host': transportHost,
      };
      break;
    case 'http':
      streamSettings['httpSettings'] = {
        'path': transportPath,
        if (transportHost.isNotEmpty) 'host': [transportHost],
      };
      break;
    case 'grpc':
      streamSettings['grpcSettings'] = {
        'serviceName': transportPath,
        if (transportHost.isNotEmpty) 'authority': transportHost,
      };
      break;
    case 'xhttp':
      streamSettings['xhttpSettings'] = {
        'path': transportPath,
        if (transportHost.isNotEmpty) 'host': transportHost,
        if (profile.webSocket.connectionOptions['mode']?.isNotEmpty == true)
          'mode': profile.webSocket.connectionOptions['mode'],
      };
      break;
  }
  if (profile.protocol == VpnProtocol.directProxy) {
    streamSettings
      ..['network'] = 'tcp'
      ..['security'] = 'none'
      ..remove('tlsSettings')
      ..remove('wsSettings');
  }
  final settings = <String, dynamic>{};
  switch (profile.protocol) {
    case VpnProtocol.vless:
      final user = <String, dynamic>{'id': profile.uuid, 'encryption': 'none'};
      if (profile.flow.isNotEmpty) user['flow'] = profile.flow;
      settings['vnext'] = [
        {
          'address': profile.server,
          'port': profile.port,
          'users': [user]
        },
      ];
      break;
    case VpnProtocol.vmess:
      settings['vnext'] = [
        {
          'address': profile.server,
          'port': profile.port,
          'users': [
            {
              'id': profile.uuid,
              'alterId': profile.alterId,
              'security': profile.security.isEmpty ? 'auto' : profile.security,
            },
          ],
        },
      ];
      break;
    case VpnProtocol.trojan:
      settings['servers'] = [
        {
          'address': profile.server,
          'port': profile.port,
          'password': profile.password
        },
      ];
      break;
    case VpnProtocol.shadowsocks:
      settings['servers'] = [
        {
          'address': profile.server,
          'port': profile.port,
          'method': profile.cipher,
          'password': profile.password,
        },
      ];
      break;
    case VpnProtocol.hysteria2:
      settings.addAll(
          {'address': profile.server, 'port': profile.port, 'version': 2});
      final hysteriaSettings = <String, dynamic>{'version': 2};
      if (profile.password.isNotEmpty) {
        hysteriaSettings['auth'] = profile.password;
      }
      streamSettings
        ..['network'] = 'hysteria'
        ..['security'] = 'tls'
        ..['tlsSettings'] = {'serverName': sni}
        ..['hysteriaSettings'] = hysteriaSettings;
      if (profile.hysteriaObfs == 'salamander') {
        streamSettings['finalmask'] = {
          'udp': [
            {
              'type': 'salamander',
              'settings': {'password': profile.hysteriaObfsPassword},
            },
          ],
        };
      }
      break;
    case VpnProtocol.socks:
    case VpnProtocol.directProxy:
      final server = <String, dynamic>{
        'address': profile.server,
        'port': profile.port
      };
      if (profile.proxy.username.isNotEmpty) {
        server['users'] = [
          {'user': profile.proxy.username, 'pass': profile.password},
        ];
      }
      settings['servers'] = [server];
      break;
    case VpnProtocol.http:
      final server = <String, dynamic>{
        'address': profile.server,
        'port': profile.port
      };
      if (profile.proxy.username.isNotEmpty) {
        server['users'] = [
          {'user': profile.proxy.username, 'pass': profile.password},
        ];
      }
      settings['servers'] = [server];
      break;
    case VpnProtocol.xray:
    case VpnProtocol.ssh:
      break;
  }
  final protocolName = switch (profile.protocol) {
    VpnProtocol.shadowsocks => 'shadowsocks',
    VpnProtocol.socks => 'socks',
    VpnProtocol.directProxy => 'socks',
    VpnProtocol.http => 'http',
    VpnProtocol.hysteria2 => 'hysteria',
    _ => profile.protocol.name,
  };
  return {
    'outbounds': [
      {
        'tag': 'proxy',
        'protocol': protocolName,
        'settings': settings,
        'streamSettings': streamSettings,
      },
    ],
  };
}

String? _validateCoreJson(
  String? value, {
  bool allowEmpty = false,
  VpnCore core = VpnCore.xray,
}) {
  final coreName = core == VpnCore.singbox ? 'Sing-box' : 'Xray';
  if (value == null || value.trim().isEmpty) {
    return allowEmpty ? null : 'Enter a complete $coreName JSON configuration.';
  }
  try {
    final config = parseXrayJson(value);
    final outbounds = config['outbounds'];
    if (outbounds is! List || outbounds.isEmpty) {
      return 'The configuration must contain at least one outbound.';
    }
    if (isSingboxJson(config) && core != VpnCore.singbox) {
      return 'Select Sing-box as the VPN core for this native Sing-box configuration.';
    }
    return null;
  } catch (_) {
    return 'Enter valid JSON for a $coreName configuration.';
  }
}

Map<String, dynamic> _mergeStandardXrayConfig(
  dynamic source,
  Map<String, dynamic> standard,
) {
  final existing = Map<String, dynamic>.from(source as Map);
  final oldOutbounds = existing['outbounds'] as List<dynamic>? ?? const [];
  final newOutbounds = standard['outbounds'] as List<dynamic>? ?? const [];
  if (newOutbounds.isEmpty) return existing;
  final next = Map<String, dynamic>.from(newOutbounds.first as Map);
  if (oldOutbounds.isNotEmpty) {
    final old = Map<String, dynamic>.from(oldOutbounds.first as Map);
    if (old['protocol'] == next['protocol']) {
      next['settings'] = _mergeJsonMap(
        old['settings'] as Map? ?? const {},
        next['settings'] as Map? ?? const {},
      );
      next['streamSettings'] = _mergeJsonMap(
        old['streamSettings'] as Map? ?? const {},
        next['streamSettings'] as Map? ?? const {},
      );
      next.addAll({
        for (final entry in old.entries)
          if (entry.key != 'settings' && entry.key != 'streamSettings')
            entry.key: entry.value,
        ...next,
      });
    }
  }
  existing['outbounds'] = [
    next,
    ...oldOutbounds.skip(1),
  ];
  return existing;
}

Map<String, dynamic> _mergeJsonMap(
    Map<dynamic, dynamic> source, Map<dynamic, dynamic> updates) {
  final result = <String, dynamic>{
    for (final entry in source.entries) entry.key.toString(): entry.value,
  };
  for (final entry in updates.entries) {
    final key = entry.key.toString();
    final value = entry.value;
    final prior = result[key];
    result[key] =
        prior is Map && value is Map ? _mergeJsonMap(prior, value) : value;
  }
  return result;
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
            child: Text(value,
                style: const TextStyle(color: _muted, fontSize: 13)),
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
  late final TextEditingController _uuid;
  late final TextEditingController _password;
  late String _cipher;
  late final TextEditingController _hysteriaObfsPassword;
  late final TextEditingController _sshUsername;
  late final TextEditingController _sshPrivateKey;
  late final TextEditingController _sshKeyPassphrase;
  late final TextEditingController _sshHostKeyFingerprint;
  late final TextEditingController _sshSni;
  late final TextEditingController _sshPayload;
  late final TextEditingController _sshProxyHost;
  late final TextEditingController _sshProxyPort;
  late final TextEditingController _sshProxyUsername;
  late final TextEditingController _sshProxyPassword;
  late final TextEditingController _sshMtu;
  late final TextEditingController _proxyUsername;
  late final TextEditingController _flow;
  late final TextEditingController _alterId;
  late final TextEditingController _notes;
  late final TextEditingController _xrayConfig;
  late final TextEditingController _xrayShareLink;
  late final TextEditingController _webSocketHost;
  late final TextEditingController _webSocketPath;
  late final TextEditingController _tlsSni;
  late final TextEditingController _tlsVerifyName;
  late final TextEditingController _dnsPrimary;
  late final TextEditingController _dnsSecondary;
  late final TextEditingController _dnsTertiary;
  late VpnProtocol _protocol;
  late VpnCore _core;
  late TransportMode _transport;
  late bool _webSocketEnabled;
  late bool _tlsEnabled;
  late bool _allowTlsHostnameMismatch;
  late String _hysteriaObfs;
  late String _sshAuthentication;
  late String _sshProxyType;
  late bool _sshTlsEnabled;
  late bool _sshPayloadEnabled;
  late bool _sshProxyEnabled;
  late bool _dnsEnabled;
  late bool _showXrayConfig;

  bool get _hasCompleteXrayJson => _xrayConfig.text.trim().startsWith('{');

  @override
  void initState() {
    super.initState();
    final profile = widget.profile;
    _name = TextEditingController(text: profile?.name ?? '');
    _server = TextEditingController(text: profile?.server ?? '');
    _port = TextEditingController(
      text: profile == null || profile.port <= 0 ? '' : profile.port.toString(),
    );
    _protocol = profile?.protocol ?? VpnProtocol.vless;
    _core = profile?.core ?? VpnCore.xray;
    _uuid = TextEditingController(text: profile?.uuid ?? '');
    _password = TextEditingController(text: profile?.password ?? '');
    _cipher = profile?.cipher ?? '';
    _hysteriaObfsPassword = TextEditingController(
      text: profile?.hysteriaObfsPassword ?? '',
    );
    _hysteriaObfs = profile?.hysteriaObfs ?? '';
    final ssh = profile?.ssh ?? const SshTunnelConfig();
    _sshUsername = TextEditingController(text: ssh.username);
    _sshPrivateKey = TextEditingController(text: ssh.privateKey);
    _sshKeyPassphrase = TextEditingController(text: ssh.privateKeyPassphrase);
    _sshHostKeyFingerprint =
        TextEditingController(text: ssh.hostKeyFingerprint);
    _sshSni = TextEditingController(text: ssh.sni);
    _sshPayload = TextEditingController(text: ssh.payload);
    _sshProxyHost = TextEditingController(text: ssh.proxyHost);
    _sshProxyPort = TextEditingController(
      text: ssh.proxyPort > 0 ? ssh.proxyPort.toString() : '',
    );
    _sshProxyUsername = TextEditingController(text: ssh.proxyUsername);
    _sshProxyPassword = TextEditingController(text: ssh.proxyPassword);
    _sshMtu = TextEditingController(text: ssh.mtu.toString());
    _sshAuthentication = ssh.authentication;
    _sshProxyType = ssh.proxyType;
    _sshTlsEnabled = ssh.tlsEnabled;
    _sshPayloadEnabled = ssh.payloadEnabled;
    _sshProxyEnabled = ssh.proxyEnabled;
    _proxyUsername = TextEditingController(text: profile?.proxy.username ?? '');
    _flow = TextEditingController(text: profile?.flow ?? '');
    _alterId = TextEditingController(text: profile?.alterId.toString() ?? '0');
    _notes = TextEditingController(text: profile?.notes ?? '');
    _xrayConfig = TextEditingController(text: profile?.xrayConfig ?? '');
    _xrayShareLink = TextEditingController(text: profile?.xrayShareLink ?? '');
    _showXrayConfig = profile?.showXrayConfig ??
        (profile != null && profile.xrayConfig.trim().isNotEmpty);
    _webSocketHost = TextEditingController(text: profile?.webSocket.host ?? '');
    _webSocketPath = TextEditingController(
      text: profile?.webSocket.path ?? '',
    );
    _tlsSni = TextEditingController(text: profile?.tls.sni ?? '');
    _tlsVerifyName = TextEditingController(
      text: profile?.tls.serverName ?? '',
    );
    _dnsPrimary = TextEditingController(text: profile?.dns.primary ?? '');
    _dnsSecondary = TextEditingController(text: profile?.dns.secondary ?? '');
    _dnsTertiary = TextEditingController(text: profile?.dns.tertiary ?? '');
    _transport = profile?.transport ?? TransportMode.auto;
    _webSocketEnabled = profile?.webSocket.enabled == true ||
        (profile?.transport.isWebSocket ?? false);
    _tlsEnabled = profile?.tls.enabled == true ||
        profile?.transport == TransportMode.websocketTls;
    _allowTlsHostnameMismatch = profile?.tls.allowInsecureCertificate ?? false;
    _dnsEnabled = profile?.dns.enabled ?? false;
  }

  @override
  void dispose() {
    _name.dispose();
    _server.dispose();
    _port.dispose();
    _uuid.dispose();
    _password.dispose();
    _hysteriaObfsPassword.dispose();
    _sshUsername.dispose();
    _sshPrivateKey.dispose();
    _sshKeyPassphrase.dispose();
    _sshHostKeyFingerprint.dispose();
    _sshSni.dispose();
    _sshPayload.dispose();
    _sshProxyHost.dispose();
    _sshProxyPort.dispose();
    _sshProxyUsername.dispose();
    _sshProxyPassword.dispose();
    _sshMtu.dispose();
    _proxyUsername.dispose();
    _flow.dispose();
    _alterId.dispose();
    _notes.dispose();
    _xrayConfig.dispose();
    _xrayShareLink.dispose();
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

  VpnProfile _draftProfile({String? configOverride}) {
    final now = DateTime.now();
    final original = widget.profile;
    final port = int.tryParse(_port.text.trim()) ?? 0;
    final sourceChanged = original != null &&
        (_xrayConfig.text.trim() != original.xrayConfig.trim() ||
            _xrayShareLink.text.trim() != original.xrayShareLink.trim());
    final hasImportedSource = _xrayConfig.text.trim().isNotEmpty ||
        _xrayShareLink.text.trim().isNotEmpty;
    int? endpointPortOverride = original?.endpointPortOverride;
    if (hasImportedSource) {
      if (original == null) {
        endpointPortOverride = port > 0 && port <= 65535 ? port : null;
      } else if (port != original.port && port > 0 && port <= 65535) {
        endpointPortOverride = port;
      } else if (sourceChanged || port != original.port) {
        endpointPortOverride = null;
      }
    } else {
      endpointPortOverride = null;
    }
    final wsHost = _webSocketHost.text.trim();
    final sniHost = _tlsSni.text.trim().isEmpty
        ? (_protocol == VpnProtocol.hysteria2 ? '' : wsHost)
        : _tlsSni.text.trim();
    return VpnProfile(
      id: original?.id ?? const Uuid().v4(),
      name: _name.text.trim(),
      server: _server.text.trim().isEmpty && _hasCompleteXrayJson
          ? '${_core == VpnCore.singbox ? 'Sing-box' : 'Xray'} configuration'
          : _server.text.trim(),
      port: port,
      protocol: _protocol,
      core: _core,
      uuid: _uuid.text.trim(),
      password:
          _protocol == VpnProtocol.directProxy ? '' : _password.text.trim(),
      hysteriaObfs: _protocol == VpnProtocol.hysteria2
          ? _hysteriaObfs
          : original?.hysteriaObfs ?? '',
      hysteriaObfsPassword: _protocol == VpnProtocol.hysteria2
          ? _hysteriaObfsPassword.text.trim()
          : original?.hysteriaObfsPassword ?? '',
      flow: _flow.text.trim(),
      alterId: int.tryParse(_alterId.text.trim()) ?? 0,
      cipher: _protocol == VpnProtocol.shadowsocks
          ? _cipher.trim()
          : original?.cipher ?? '',
      transport:
          _protocol == VpnProtocol.directProxy ? TransportMode.tcp : _transport,
      webSocket: WebSocketConfig(
        enabled:
            _protocol == VpnProtocol.directProxy ? false : _webSocketEnabled,
        host: wsHost,
        path: _webSocketPath.text.trim(),
        headers: original?.webSocket.headers ?? const {},
        connectionOptions: original?.webSocket.connectionOptions ?? const {},
      ),
      tls: TlsConfig(
        enabled: _protocol != VpnProtocol.directProxy &&
            (_tlsEnabled || _protocol == VpnProtocol.hysteria2),
        sni: sniHost,
        serverName: _tlsVerifyName.text.trim().isEmpty
            ? sniHost
            : _tlsVerifyName.text.trim(),
        allowInsecureCertificate: _allowTlsHostnameMismatch,
        alpn: original?.tls.alpn ?? const [],
      ),
      proxy: ProxyConfig(
        type: _protocol == VpnProtocol.directProxy ||
                _protocol == VpnProtocol.socks
            ? ProxyType.socks5
            : _protocol == VpnProtocol.http
                ? ProxyType.http
                : original?.proxy.type ?? ProxyType.none,
        host: original?.proxy.host ?? '',
        port: original?.proxy.port ?? 0,
        username: _protocol == VpnProtocol.directProxy
            ? ''
            : _proxyUsername.text.trim(),
        password:
            _protocol == VpnProtocol.socks || _protocol == VpnProtocol.http
                ? _password.text
                : original?.proxy.password ?? '',
      ),
      ssh: _protocol == VpnProtocol.ssh
          ? SshTunnelConfig(
              username: _sshUsername.text.trim(),
              authentication: _sshAuthentication,
              privateKey: _sshPrivateKey.text,
              privateKeyPassphrase: _sshKeyPassphrase.text,
              hostKeyFingerprint: _sshHostKeyFingerprint.text.trim(),
              tlsEnabled: _sshTlsEnabled,
              sni: _sshSni.text.trim(),
              payloadEnabled: _sshPayloadEnabled,
              payload: _sshPayload.text,
              proxyEnabled: _sshProxyEnabled,
              proxyType: _sshProxyType,
              proxyHost: _sshProxyHost.text.trim(),
              proxyPort: int.tryParse(_sshProxyPort.text.trim()) ??
                  original?.ssh.proxyPort ??
                  0,
              proxyUsername: _sshProxyUsername.text.trim(),
              proxyPassword: _sshProxyPassword.text,
              mtu: int.tryParse(_sshMtu.text.trim()) ?? 1400,
            )
          : original?.ssh ?? const SshTunnelConfig(),
      dns: DnsConfig(
        enabled: _dnsEnabled,
        primary: _dnsPrimary.text.trim(),
        secondary: _dnsSecondary.text.trim(),
        tertiary: _dnsTertiary.text.trim(),
      ),
      metadata: original?.metadata ?? '',
      xrayConfig: _canonicalXrayConfig(
        configOverride ?? _effectiveXrayConfig(),
      ),
      xrayShareLink: (_protocol == VpnProtocol.hysteria2 && !_showXrayConfig) ||
              _protocol == VpnProtocol.ssh ||
              _protocol == VpnProtocol.directProxy
          ? ''
          : _xrayShareLink.text.trim(),
      endpointPortOverride: endpointPortOverride,
      showXrayConfig: _showXrayConfig,
      createdAt: original?.createdAt ?? now,
      lastUsedAt: now,
      favorite: original?.favorite ?? false,
      notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
      isSelected: original?.isSelected ?? false,
    );
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.pop(context, _draftProfile());
  }

  String _effectiveXrayConfig() {
    final current = _xrayConfig.text.trim();
    if (_showXrayConfig) return current;
    if (current.isEmpty || !_hasCompleteXrayJson) return current;
    try {
      final existing = parseXrayJson(current);
      final standard =
          _xrayConfigFromProfile(_draftProfile(configOverride: ''));
      return const JsonEncoder.withIndent('  ').convert(
        _mergeStandardXrayConfig(existing, standard),
      );
    } catch (_) {
      return current;
    }
  }

  String _canonicalXrayConfig(String value) {
    if (value.trim().isEmpty) return '';
    try {
      return const JsonEncoder.withIndent('  ').convert(parseXrayJson(value));
    } catch (_) {
      return value;
    }
  }

  void _setEditorMode(bool jsonMode) {
    if (jsonMode == _showXrayConfig) return;
    if (jsonMode) {
      if (_xrayConfig.text.trim().isEmpty &&
          _protocol != VpnProtocol.xray &&
          _protocol != VpnProtocol.ssh) {
        _xrayConfig.text = const JsonEncoder.withIndent('  ').convert(
          _xrayConfigFromProfile(_draftProfile(configOverride: '')),
        );
      }
      setState(() => _showXrayConfig = true);
      return;
    }
    if (_hasCompleteXrayJson && !_loadStandardFieldsFromJson()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'This configuration needs JSON mode because its outbound cannot be represented by the standard fields.'),
        ),
      );
      return;
    }
    setState(() => _showXrayConfig = false);
  }

  bool _loadStandardFieldsFromJson() {
    try {
      final config = parseXrayJson(_xrayConfig.text.trim());
      final outbound = primaryXrayOutbound(config);
      if (outbound == null) return false;
      final protocol = (outbound['protocol'] as String? ?? '').toLowerCase();
      final settings =
          Map<String, dynamic>.from(outbound['settings'] as Map? ?? const {});
      final stream = Map<String, dynamic>.from(
          outbound['streamSettings'] as Map? ?? const {});
      Map<String, dynamic> server = {};
      Map<String, dynamic> user = {};
      Map<String, dynamic> hysteria = {};
      var hysteriaObfs = '';
      var hysteriaObfsPassword = '';
      switch (protocol) {
        case 'vless':
        case 'vmess':
          final endpoints = settings['vnext'] as List<dynamic>?;
          if (endpoints == null || endpoints.isEmpty) return false;
          server = Map<String, dynamic>.from(endpoints.first as Map);
          final users = server['users'] as List<dynamic>?;
          if (users != null && users.isNotEmpty) {
            user = Map<String, dynamic>.from(users.first as Map);
          }
          _protocol =
              protocol == 'vless' ? VpnProtocol.vless : VpnProtocol.vmess;
          break;
        case 'trojan':
        case 'shadowsocks':
        case 'socks':
        case 'http':
          final servers = settings['servers'] as List<dynamic>?;
          if (servers == null || servers.isEmpty) return false;
          server = Map<String, dynamic>.from(servers.first as Map);
          final users = server['users'] as List<dynamic>?;
          if (users != null && users.isNotEmpty) {
            user = Map<String, dynamic>.from(users.first as Map);
          }
          _protocol = switch (protocol) {
            'trojan' => VpnProtocol.trojan,
            'shadowsocks' => VpnProtocol.shadowsocks,
            'socks' => VpnProtocol.socks,
            _ => VpnProtocol.http,
          };
          break;
        case 'hysteria':
          if (settings['version'] != 2 ||
              (stream['network'] ?? stream['method']) != 'hysteria' ||
              stream['security'] != 'tls' ||
              settings.keys.any(
                (key) => !{'address', 'port', 'version'}.contains(key),
              ) ||
              stream.keys.any(
                (key) => !{
                  'network',
                  'method',
                  'security',
                  'tlsSettings',
                  'hysteriaSettings',
                  'finalmask',
                }.contains(key),
              )) {
            return false;
          }
          server = settings;
          hysteria = Map<String, dynamic>.from(
            stream['hysteriaSettings'] as Map? ?? const {},
          );
          if (hysteria['version'] != 2 ||
              hysteria.keys.any((key) => !{'version', 'auth'}.contains(key))) {
            return false;
          }
          final tlsSettings = Map<String, dynamic>.from(
            stream['tlsSettings'] as Map? ?? const {},
          );
          if (tlsSettings.keys.any(
            (key) => !{'serverName', 'allowInsecure'}.contains(key),
          )) {
            return false;
          }
          final finalmask = Map<String, dynamic>.from(
            stream['finalmask'] as Map? ?? const {},
          );
          if (finalmask.keys
                  .any((key) => key != 'udp' && key != 'quicParams') ||
              (finalmask['quicParams'] is Map &&
                  (finalmask['quicParams'] as Map).isNotEmpty) ||
              (finalmask['tcp'] is List &&
                  (finalmask['tcp'] as List).isNotEmpty)) {
            return false;
          }
          final udpMasks = finalmask['udp'] as List<dynamic>? ?? const [];
          if (udpMasks.length > 1) return false;
          if (udpMasks.isNotEmpty) {
            final mask = Map<String, dynamic>.from(udpMasks.first as Map);
            if (mask['type'] != 'salamander') return false;
            hysteriaObfs = 'salamander';
            final obfsSettings = Map<String, dynamic>.from(
              mask['settings'] as Map? ?? const {},
            );
            if (obfsSettings.keys.any((key) => key != 'password')) {
              return false;
            }
            hysteriaObfsPassword = obfsSettings['password']?.toString() ?? '';
          }
          _protocol = VpnProtocol.hysteria2;
          break;
        default:
          return false;
      }
      _server.text = server['address']?.toString() ?? '';
      _port.text = server['port']?.toString() ?? '';
      _uuid.text = user['id']?.toString() ?? '';
      _flow.text = user['flow']?.toString() ?? '';
      _alterId.text = user['alterId']?.toString() ?? '0';
      _password.text = protocol == 'hysteria'
          ? hysteria['auth']?.toString() ?? ''
          : server['password']?.toString() ?? user['pass']?.toString() ?? '';
      if (protocol == 'shadowsocks') {
        _cipher = server['method']?.toString().trim().isNotEmpty == true
            ? server['method'].toString().trim()
            : settings['method']?.toString().trim() ?? '';
      }
      _hysteriaObfs = hysteriaObfs;
      _hysteriaObfsPassword.text = hysteriaObfsPassword;
      _proxyUsername.text = user['user']?.toString() ?? '';
      final tls =
          Map<String, dynamic>.from(stream['tlsSettings'] as Map? ?? const {});
      final ws =
          Map<String, dynamic>.from(stream['wsSettings'] as Map? ?? const {});
      final httpUpgrade = Map<String, dynamic>.from(
        stream['httpupgradeSettings'] as Map? ?? const {},
      );
      final http = Map<String, dynamic>.from(
        stream['httpSettings'] as Map? ?? const {},
      );
      final grpc = Map<String, dynamic>.from(
        stream['grpcSettings'] as Map? ?? const {},
      );
      final xhttp = Map<String, dynamic>.from(
        stream['xhttpSettings'] as Map? ?? const {},
      );
      _tlsEnabled = stream['security'] == 'tls' || protocol == 'hysteria';
      _tlsSni.text = tls['serverName']?.toString() ?? '';
      _tlsVerifyName.text = tls['serverName']?.toString() ?? '';
      _allowTlsHostnameMismatch = tls['allowInsecure'] == true;
      final network = (stream['network']?.toString() ?? 'tcp').toLowerCase();
      _transport = TransportMode.fromNetwork(network, tls: _tlsEnabled);
      _webSocketEnabled = _transport.isWebSocket;
      final transportPath = switch (network) {
        'grpc' => grpc['serviceName']?.toString() ?? '',
        'httpupgrade' => httpUpgrade['path']?.toString() ?? '',
        'http' => http['path']?.toString() ?? '',
        'xhttp' || 'splithttp' => xhttp['path']?.toString() ?? '',
        _ => ws['path']?.toString() ?? '',
      };
      _webSocketPath.text = transportPath;
      final headers =
          Map<String, dynamic>.from(ws['headers'] as Map? ?? const {});
      final httpHosts = http['host'] as List? ?? const [];
      final httpHost = http['host'] is List
          ? (httpHosts.isEmpty ? '' : httpHosts.first.toString())
          : http['host']?.toString() ?? '';
      _webSocketHost.text = switch (network) {
        'http' => httpHost,
        'httpupgrade' => httpUpgrade['host']?.toString() ?? '',
        'xhttp' || 'splithttp' => xhttp['host']?.toString() ?? '',
        _ => headers['Host']?.toString() ?? '',
      };
      return true;
    } catch (_) {
      return false;
    }
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
                  if (_protocol != VpnProtocol.ssh) ...[
                    DropdownButtonFormField<bool>(
                      initialValue: _showXrayConfig,
                      decoration:
                          const InputDecoration(labelText: 'Editor mode'),
                      items: [
                        DropdownMenuItem(value: false, child: Text('Standard')),
                        DropdownMenuItem(
                          value: true,
                          child: Text(_core == VpnCore.singbox
                              ? 'Core JSON'
                              : 'Xray JSON'),
                        ),
                      ],
                      onChanged: (value) => _setEditorMode(value ?? false),
                    ),
                    const SizedBox(height: 14),
                  ],
                  if (_showXrayConfig && _protocol != VpnProtocol.ssh) ...[
                    TextFormField(
                      controller: _xrayShareLink,
                      minLines: 1,
                      maxLines: 4,
                      keyboardType: TextInputType.multiline,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: InputDecoration(
                        labelText:
                            'Proxy share link or subscription (optional)',
                        helperText:
                            'Used when complete JSON is empty. Complete JSON takes precedence when both are provided.',
                      ),
                    ),
                    const SizedBox(height: 14),
                    DropdownButtonFormField<VpnCore>(
                      initialValue: _core,
                      decoration: const InputDecoration(labelText: 'VPN core'),
                      items: [
                        DropdownMenuItem(
                          value: VpnCore.xray,
                          child: Text('Xray-core'),
                        ),
                        DropdownMenuItem(
                          value: VpnCore.singbox,
                          child: Text('Sing-box'),
                        ),
                      ],
                      onChanged: (value) => setState(
                        () => _core = value ?? VpnCore.xray,
                      ),
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _xrayConfig,
                      onChanged: (_) => setState(() {}),
                      minLines: 10,
                      maxLines: 24,
                      keyboardType: TextInputType.multiline,
                      autocorrect: false,
                      enableSuggestions: false,
                      validator: (value) => _validateCoreJson(
                        value,
                        allowEmpty: _xrayShareLink.text.trim().isNotEmpty,
                        core: _core,
                      ),
                      decoration: InputDecoration(
                        labelText: _core == VpnCore.singbox
                            ? 'Sing-box or Xray configuration (JSON)'
                            : 'Complete Xray configuration (JSON)',
                        helperText: _core != VpnCore.singbox
                            ? 'Edit complete Xray JSON, including routing and protocol-specific outbound fields. Comments and trailing commas are accepted.'
                            : 'Native Sing-box JSON is passed to the core with a managed Android TUN inbound. Xray JSON conversion supports common outbound types only; paste native Sing-box JSON for all bundled core protocols.',
                        alignLabelWithHint: true,
                      ),
                    ),
                    const SizedBox(height: 14),
                  ],
                  if (!_showXrayConfig || _protocol == VpnProtocol.ssh) ...[
                    DropdownButtonFormField<VpnProtocol>(
                      initialValue: _protocol,
                      decoration: const InputDecoration(labelText: 'Protocol'),
                      items: const [
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
                        DropdownMenuItem(
                          value: VpnProtocol.hysteria2,
                          child: Text('Hysteria2'),
                        ),
                        DropdownMenuItem(
                          value: VpnProtocol.ssh,
                          child: Text('SSH full tunnel'),
                        ),
                        DropdownMenuItem(
                          value: VpnProtocol.directProxy,
                          child: Text('Direct Proxy (SOCKS5, no auth)'),
                        ),
                        DropdownMenuItem(
                          value: VpnProtocol.socks,
                          child: Text('SOCKS'),
                        ),
                        DropdownMenuItem(
                          value: VpnProtocol.http,
                          child: Text('HTTP proxy'),
                        ),
                        DropdownMenuItem(
                          value: VpnProtocol.xray,
                          child: Text('Xray JSON'),
                        ),
                      ],
                      onChanged: (value) => setState(
                        () => _protocol = value ?? VpnProtocol.vless,
                      ),
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _server,
                      decoration: InputDecoration(
                        labelText: _protocol == VpnProtocol.directProxy
                            ? 'SOCKS5 proxy host'
                            : 'Address / server host',
                      ),
                      validator: (value) => _hasCompleteXrayJson
                          ? null
                          : _required(value, 'Server'),
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _port,
                      decoration: InputDecoration(
                        labelText: _protocol == VpnProtocol.directProxy
                            ? 'Proxy port'
                            : 'Port',
                        helperText: _protocol == VpnProtocol.directProxy
                            ? 'Connect directly to a SOCKS5 proxy without authentication.'
                            : null,
                      ),
                      validator: (value) {
                        if (_hasCompleteXrayJson) return null;
                        final port = int.tryParse(value?.trim() ?? '');
                        if (port == null || port < 1 || port > 65535) {
                          return 'Enter a port from 1 to 65535.';
                        }
                        return null;
                      },
                      keyboardType: TextInputType.number,
                    ),
                    const SizedBox(height: 14),
                    if (_protocol == VpnProtocol.ssh) ...[
                      TextFormField(
                        controller: _sshUsername,
                        decoration: const InputDecoration(
                          labelText: 'SSH username',
                        ),
                        validator: (value) => _required(value, 'SSH username'),
                        autocorrect: false,
                      ),
                      const SizedBox(height: 14),
                      DropdownButtonFormField<String>(
                        initialValue: _sshAuthentication,
                        decoration: const InputDecoration(
                          labelText: 'SSH authentication',
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 'password',
                            child: Text('Password'),
                          ),
                          DropdownMenuItem(
                            value: 'privateKey',
                            child: Text('Private key'),
                          ),
                        ],
                        onChanged: (value) => setState(
                          () => _sshAuthentication = value ?? 'password',
                        ),
                      ),
                      const SizedBox(height: 14),
                      if (_sshAuthentication == 'password') ...[
                        TextFormField(
                          controller: _password,
                          decoration: const InputDecoration(
                            labelText: 'SSH password',
                          ),
                          validator: (value) =>
                              _required(value, 'SSH password'),
                          obscureText: true,
                          autocorrect: false,
                        ),
                        const SizedBox(height: 14),
                      ] else ...[
                        TextFormField(
                          controller: _sshPrivateKey,
                          minLines: 4,
                          maxLines: 8,
                          decoration: const InputDecoration(
                            labelText: 'SSH private key (OpenSSH PEM)',
                          ),
                          validator: (value) =>
                              _required(value, 'SSH private key'),
                          autocorrect: false,
                          enableSuggestions: false,
                        ),
                        const SizedBox(height: 14),
                        TextFormField(
                          controller: _sshKeyPassphrase,
                          decoration: const InputDecoration(
                            labelText: 'Private key passphrase (optional)',
                          ),
                          obscureText: true,
                          autocorrect: false,
                        ),
                        const SizedBox(height: 14),
                      ],
                      TextFormField(
                        controller: _sshHostKeyFingerprint,
                        decoration: const InputDecoration(
                          labelText:
                              'SSH server SHA-256 fingerprint (optional)',
                          helperText:
                              'Leave blank to connect without fingerprint pinning.',
                        ),
                        autocorrect: false,
                      ),
                      const SizedBox(height: 14),
                      SwitchListTile.adaptive(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('TLS wrapper'),
                        subtitle: const Text(
                          'Use only when the server accepts SSH inside TLS.',
                        ),
                        value: _sshTlsEnabled,
                        onChanged: (value) =>
                            setState(() => _sshTlsEnabled = value),
                      ),
                      if (_sshTlsEnabled) ...[
                        TextFormField(
                          controller: _sshSni,
                          decoration: const InputDecoration(
                            labelText: 'TLS SNI hostname',
                          ),
                          validator: (value) => _sshTlsEnabled
                              ? _required(value, 'SNI hostname')
                              : null,
                          autocorrect: false,
                        ),
                        const SizedBox(height: 14),
                      ],
                      SwitchListTile.adaptive(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Custom HTTP payload'),
                        value: _sshPayloadEnabled,
                        onChanged: (value) =>
                            setState(() => _sshPayloadEnabled = value),
                      ),
                      if (_sshPayloadEnabled) ...[
                        TextFormField(
                          controller: _sshPayload,
                          minLines: 3,
                          maxLines: 8,
                          decoration: const InputDecoration(
                            labelText: 'Payload sent through the HTTP proxy',
                            helperText:
                                'Placeholders: [host], [port], and [crlf].',
                          ),
                          validator: (value) => _sshPayloadEnabled
                              ? _required(value, 'HTTP payload')
                              : null,
                          autocorrect: false,
                        ),
                        const SizedBox(height: 14),
                      ],
                      SwitchListTile.adaptive(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Connect through a proxy'),
                        value: _sshProxyEnabled,
                        onChanged: (value) =>
                            setState(() => _sshProxyEnabled = value),
                      ),
                      if (_sshProxyEnabled) ...[
                        DropdownButtonFormField<String>(
                          initialValue: _sshProxyType,
                          decoration: const InputDecoration(
                            labelText: 'Proxy type',
                          ),
                          items: const [
                            DropdownMenuItem(
                              value: 'http',
                              child: Text('HTTP CONNECT'),
                            ),
                            DropdownMenuItem(
                              value: 'socks5',
                              child: Text('SOCKS5'),
                            ),
                          ],
                          onChanged: (value) => setState(
                            () => _sshProxyType = value ?? 'http',
                          ),
                        ),
                        const SizedBox(height: 14),
                        TextFormField(
                          controller: _sshProxyHost,
                          decoration: const InputDecoration(
                            labelText: 'Proxy host',
                          ),
                          validator: (value) => _sshProxyEnabled
                              ? _required(value, 'Proxy host')
                              : null,
                          autocorrect: false,
                        ),
                        const SizedBox(height: 14),
                        TextFormField(
                          controller: _sshProxyPort,
                          decoration: const InputDecoration(
                            labelText: 'Proxy port',
                          ),
                          validator: (value) {
                            if (!_sshProxyEnabled) return null;
                            final port = int.tryParse(value?.trim() ?? '');
                            return port == null || port < 1 || port > 65535
                                ? 'Enter a port from 1 to 65535.'
                                : null;
                          },
                          keyboardType: TextInputType.number,
                        ),
                        const SizedBox(height: 14),
                        TextFormField(
                          controller: _sshProxyUsername,
                          decoration: const InputDecoration(
                            labelText: 'Proxy username (optional)',
                          ),
                          autocorrect: false,
                        ),
                        const SizedBox(height: 14),
                        TextFormField(
                          controller: _sshProxyPassword,
                          decoration: const InputDecoration(
                            labelText: 'Proxy password (optional)',
                          ),
                          obscureText: true,
                          autocorrect: false,
                        ),
                        const SizedBox(height: 14),
                      ],
                      TextFormField(
                        controller: _sshMtu,
                        decoration: const InputDecoration(
                          labelText: 'Tunnel MTU',
                        ),
                        validator: (value) {
                          final mtu = int.tryParse(value?.trim() ?? '');
                          return mtu == null || mtu < 576 || mtu > 9000
                              ? 'Enter an MTU from 576 to 9000.'
                              : null;
                        },
                        keyboardType: TextInputType.number,
                      ),
                      const SizedBox(height: 14),
                    ],
                    if (_protocol == VpnProtocol.vless ||
                        _protocol == VpnProtocol.vmess) ...[
                      TextFormField(
                        controller: _uuid,
                        decoration: InputDecoration(
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
                    if (_protocol == VpnProtocol.socks ||
                        _protocol == VpnProtocol.http) ...[
                      TextFormField(
                        controller: _proxyUsername,
                        decoration: const InputDecoration(
                            labelText: 'Username (optional)'),
                        autocorrect: false,
                      ),
                      const SizedBox(height: 14),
                    ],
                    if (_protocol != VpnProtocol.ssh &&
                        (_protocol == VpnProtocol.trojan ||
                            _protocol == VpnProtocol.shadowsocks ||
                            _protocol == VpnProtocol.hysteria2 ||
                            _protocol == VpnProtocol.socks ||
                            _protocol == VpnProtocol.http)) ...[
                      TextFormField(
                        controller: _password,
                        decoration: InputDecoration(
                          labelText: _protocol == VpnProtocol.hysteria2
                              ? 'Hysteria 2 auth (optional)'
                              : 'Password / Key',
                        ),
                        validator: (value) => _protocol == VpnProtocol.hysteria2
                            ? null
                            : _required(value, 'Password'),
                        obscureText: true,
                        autocorrect: false,
                      ),
                      const SizedBox(height: 14),
                    ],
                    if (_protocol == VpnProtocol.shadowsocks) ...[
                      DropdownButtonFormField<String>(
                        initialValue: _cipher.isNotEmpty ? _cipher : null,
                        decoration: const InputDecoration(
                          labelText: 'Shadowsocks cipher',
                        ),
                        items: [
                          DropdownMenuItem(
                            value: '2022-blake3-aes-128-gcm',
                            child: Text('2022-BLAKE3-AES-128-GCM'),
                          ),
                          DropdownMenuItem(
                            value: '2022-blake3-aes-256-gcm',
                            child: Text('2022-BLAKE3-AES-256-GCM'),
                          ),
                          DropdownMenuItem(
                            value: '2022-blake3-chacha20-poly1305',
                            child: Text('2022-BLAKE3-Chacha20-Poly1305'),
                          ),
                          DropdownMenuItem(
                            value: 'aes-128-gcm',
                            child: Text('AES-128-GCM'),
                          ),
                          DropdownMenuItem(
                            value: 'aes-256-gcm',
                            child: Text('AES-256-GCM'),
                          ),
                          DropdownMenuItem(
                            value: 'chacha20-ietf-poly1305',
                            child: Text('Chacha20-IETF-Poly1305'),
                          ),
                          DropdownMenuItem(
                            value: 'chacha20-poly1305',
                            child: Text('Chacha20-Poly1305'),
                          ),
                          DropdownMenuItem(
                            value: 'xchacha20-ietf-poly1305',
                            child: Text('XChacha20-IETF-Poly1305'),
                          ),
                          if (_cipher.isNotEmpty &&
                              !{
                                '2022-blake3-aes-128-gcm',
                                '2022-blake3-aes-256-gcm',
                                '2022-blake3-chacha20-poly1305',
                                'aes-128-gcm',
                                'aes-256-gcm',
                                'chacha20-ietf-poly1305',
                                'chacha20-poly1305',
                                'xchacha20-ietf-poly1305',
                              }.contains(_cipher))
                            DropdownMenuItem(
                              value: _cipher,
                              child: Text(_cipher),
                            ),
                        ],
                        validator: (value) =>
                            _protocol == VpnProtocol.shadowsocks &&
                                    (value == null || value.isEmpty)
                                ? 'Select a Shadowsocks cipher.'
                                : null,
                        onChanged: (value) => setState(
                          () => _cipher = value ?? '',
                        ),
                      ),
                      const SizedBox(height: 14),
                    ],
                    if (_protocol == VpnProtocol.hysteria2) ...[
                      DropdownButtonFormField<String>(
                        initialValue: _hysteriaObfs == 'salamander'
                            ? 'salamander'
                            : 'none',
                        decoration: const InputDecoration(
                          labelText: 'Hysteria 2 obfuscation',
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 'none',
                            child: Text('None'),
                          ),
                          DropdownMenuItem(
                            value: 'salamander',
                            child: Text('Salamander'),
                          ),
                        ],
                        onChanged: (value) => setState(
                          () => _hysteriaObfs =
                              value == 'none' ? '' : (value ?? ''),
                        ),
                      ),
                      const SizedBox(height: 14),
                      if (_hysteriaObfs == 'salamander') ...[
                        TextFormField(
                          controller: _hysteriaObfsPassword,
                          decoration: const InputDecoration(
                            labelText: 'Salamander obfuscation password',
                          ),
                          validator: (value) => _hysteriaObfs == 'salamander'
                              ? _required(value, 'Obfuscation password')
                              : null,
                          obscureText: true,
                          autocorrect: false,
                        ),
                        const SizedBox(height: 14),
                      ],
                      TextFormField(
                        controller: _tlsSni,
                        decoration: const InputDecoration(
                          labelText: 'TLS SNI hostname (optional)',
                          helperText:
                              'Hysteria 2 always uses TLS. Leave blank to use the server address.',
                        ),
                        autocorrect: false,
                      ),
                      const SizedBox(height: 14),
                    ],
                    if (_protocol != VpnProtocol.hysteria2 &&
                        _protocol != VpnProtocol.ssh &&
                        _protocol != VpnProtocol.directProxy) ...[
                      DropdownButtonFormField<TransportMode>(
                        initialValue: _transport,
                        decoration:
                            const InputDecoration(labelText: 'Transport'),
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
                            value: TransportMode.kcp,
                            child: Text('KCP'),
                          ),
                          DropdownMenuItem(
                            value: TransportMode.websocket,
                            child: Text('WebSocket'),
                          ),
                          DropdownMenuItem(
                            value: TransportMode.websocketTls,
                            child: Text('WebSocket + TLS'),
                          ),
                          DropdownMenuItem(
                            value: TransportMode.httpUpgrade,
                            child: Text('HTTPUpgrade'),
                          ),
                          DropdownMenuItem(
                            value: TransportMode.http,
                            child: Text('HTTP'),
                          ),
                          DropdownMenuItem(
                            value: TransportMode.quic,
                            child: Text('QUIC'),
                          ),
                          DropdownMenuItem(
                            value: TransportMode.grpc,
                            child: Text('gRPC'),
                          ),
                          DropdownMenuItem(
                            value: TransportMode.xhttp,
                            child: Text('XHTTP'),
                          ),
                        ],
                        onChanged: (value) => setState(() {
                          final selected = value ?? TransportMode.auto;
                          _transport = selected;
                          _webSocketEnabled = selected.isWebSocket;
                          if (selected == TransportMode.websocketTls) {
                            _tlsEnabled = true;
                          }
                        }),
                      ),
                      const SizedBox(height: 14),
                      SwitchListTile.adaptive(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('WebSocket'),
                        value: _webSocketEnabled,
                        activeThumbColor: _green,
                        onChanged: (value) => setState(() {
                          _webSocketEnabled = value;
                          if (value) {
                            _transport = _tlsEnabled
                                ? TransportMode.websocketTls
                                : TransportMode.websocket;
                          } else if (_transport.isWebSocket) {
                            _transport = TransportMode.tcp;
                          }
                        }),
                      ),
                      if (_webSocketEnabled ||
                          {
                            TransportMode.httpUpgrade,
                            TransportMode.http,
                            TransportMode.grpc,
                            TransportMode.xhttp,
                          }.contains(_transport)) ...[
                        TextFormField(
                          controller: _webSocketHost,
                          decoration: const InputDecoration(
                            labelText:
                                'Transport host / gRPC authority (optional)',
                          ),
                          autocorrect: false,
                        ),
                        const SizedBox(height: 14),
                        TextFormField(
                          controller: _webSocketPath,
                          decoration: const InputDecoration(
                            labelText: 'Transport path or gRPC service name',
                          ),
                          validator: (value) => value != null &&
                                  value.trim().isNotEmpty &&
                                  _transport != TransportMode.grpc &&
                                  !value.trim().startsWith('/')
                              ? 'Transport path must start with /.'
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
                        onChanged: (value) => setState(() {
                          _tlsEnabled = value;
                          if (_transport == TransportMode.websocketTls &&
                              !value) {
                            _transport = TransportMode.websocket;
                          } else if (_transport == TransportMode.websocket &&
                              value) {
                            _transport = TransportMode.websocketTls;
                          }
                        }),
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
                          title:
                              const Text('Allow certificate hostname mismatch'),
                          subtitle: const Text(
                            'Less secure. The certificate must still chain to a trusted issuer.',
                          ),
                          value: _allowTlsHostnameMismatch,
                          activeThumbColor: _green,
                          onChanged: (value) =>
                              setState(() => _allowTlsHostnameMismatch = value),
                        ),
                        const SizedBox(height: 14),
                      ],
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
  }) =>
      TextFormField(
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
