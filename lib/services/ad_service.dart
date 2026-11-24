import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AdService {
  AdService._();

  static final AdService instance = AdService._();

  static const _channel = MethodChannel('com.swock/rewarded_ads');

  static const appOpenId = '';
  static const nativeId = '';
  static const rewardedInterstitialId = '';
  static const rewardedId = '';

  static const _adFreeUntilKey = 'temporary_ad_free_until_ms';

  Future<void>? _initialization;
  bool _canRequestAds = false;
  Timer? _adFreeExpiryTimer;
  DateTime? _adFreeUntil;
  final ValueNotifier<bool> adFreeAccess = ValueNotifier(false);

  bool get canRequestAds => _canRequestAds;
  bool get hasTemporaryAdFreeAccess =>
      _adFreeUntil != null && DateTime.now().isBefore(_adFreeUntil!);
  bool get canOfferTemporaryAdFree =>
      _canRequestAds && !hasTemporaryAdFreeAccess;

  Future<bool> privacyOptionsRequired() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('privacyOptionsRequired') ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<void> initialize() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    await _restoreRewardState();
    if (!Platform.isAndroid) return;
    try {
      _canRequestAds = await _channel.invokeMethod<bool>('initialize') ?? false;
    } on PlatformException {
      _canRequestAds = false;
    } on MissingPluginException {
      _canRequestAds = false;
    }
  }

  Future<void> _restoreRewardState() async {
    final prefs = await SharedPreferences.getInstance();
    final adFreeUntilMs = prefs.getInt(_adFreeUntilKey);
    _adFreeUntil = adFreeUntilMs == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(adFreeUntilMs);
    adFreeAccess.value = hasTemporaryAdFreeAccess;
    if (_adFreeUntil != null && !hasTemporaryAdFreeAccess) {
      _adFreeUntil = null;
      await prefs.remove(_adFreeUntilKey);
    } else {
      _scheduleAdFreeExpiry();
    }
  }

  Future<void> showPrivacyOptions() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<bool>('showPrivacyOptions');
    } on PlatformException {
      // Keep the settings screen available if the form cannot be displayed.
    } on MissingPluginException {
      // Ads are not provided on platforms without the Android channel.
    }
  }

  void showAppOpenIfReady({required bool appWasBackgrounded}) {}

  void prepareForForeground() {}

  Future<bool> showTimeReward() async {
    await initialize();
    if (!Platform.isAndroid || !_canRequestAds) return false;
    try {
      return await _channel.invokeMethod<bool>('showRewardedTimeAd') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<bool> showConnectionInterstitial() async {
    await initialize();
    if (!Platform.isAndroid || !_canRequestAds || hasTemporaryAdFreeAccess) {
      return false;
    }
    try {
      return await _channel.invokeMethod<bool>(
            'showConnectionInterstitial',
          ) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  void preloadTimeReward() {}

  Future<bool> showReward({required bool interstitial}) async => false;

  Future<bool> offerTemporaryAdFree(
    BuildContext context, {
    required String occasion,
  }) async {
    await initialize();
    if (!Platform.isAndroid || !canOfferTemporaryAdFree || !context.mounted) {
      return false;
    }

    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Enjoy 30 minutes ad-free?'),
        content: Text(
          'After $occasion, you can optionally watch a rewarded video to hide in-app ads for 30 minutes.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Watch video'),
          ),
        ],
      ),
    );
    if (accepted != true || !await showTimeReward()) return false;

    final expiresAt = DateTime.now().add(const Duration(minutes: 30));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_adFreeUntilKey, expiresAt.millisecondsSinceEpoch);
    _adFreeUntil = expiresAt;
    adFreeAccess.value = true;
    _scheduleAdFreeExpiry();
    return true;
  }

  void _scheduleAdFreeExpiry() {
    _adFreeExpiryTimer?.cancel();
    final expiresAt = _adFreeUntil;
    if (expiresAt == null) return;
    final delay = expiresAt.difference(DateTime.now());
    if (delay.isNegative || delay == Duration.zero) {
      _adFreeUntil = null;
      adFreeAccess.value = false;
      unawaited(SharedPreferences.getInstance().then(
        (prefs) => prefs.remove(_adFreeUntilKey),
      ));
      return;
    }
    _adFreeExpiryTimer = Timer(delay, () {
      if (DateTime.now().isBefore(expiresAt)) {
        _scheduleAdFreeExpiry();
        return;
      }
      _adFreeUntil = null;
      adFreeAccess.value = false;
      unawaited(SharedPreferences.getInstance().then(
        (prefs) => prefs.remove(_adFreeUntilKey),
      ));
    });
  }
}
