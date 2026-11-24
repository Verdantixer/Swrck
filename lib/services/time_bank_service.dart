import 'dart:math' as math;

import 'package:shared_preferences/shared_preferences.dart';

/// VPN time balance that only counts down while the tunnel is connected.
class TimeBank {
  TimeBank._(
    this._prefs,
    this._balanceMs,
    this._runningSinceMs,
  );

  static const _balanceKey = 'time_balance_ms';
  static const _runningKey = 'time_running_since_ms';
  static const _starterKey = 'time_starter_granted';
  static const starterTime = Duration(minutes: 15);

  final SharedPreferences _prefs;
  int _balanceMs;
  int _runningSinceMs;

  static Future<TimeBank> load() async {
    final prefs = await SharedPreferences.getInstance();
    if (!(prefs.getBool(_starterKey) ?? false)) {
      await prefs.setInt(_balanceKey, starterTime.inMilliseconds);
      await prefs.setBool(_starterKey, true);
    }
    return TimeBank._(
      prefs,
      prefs.getInt(_balanceKey) ?? 0,
      prefs.getInt(_runningKey) ?? 0,
    );
  }

  bool get isRunning => _runningSinceMs > 0;

  Duration remaining(DateTime now) {
    final used = isRunning ? now.millisecondsSinceEpoch - _runningSinceMs : 0;
    return Duration(milliseconds: math.max(0, _balanceMs - math.max(0, used)));
  }

  /// Starts or stops the countdown to match the tunnel state.
  Future<void> sync({required bool connected, required DateTime now}) async {
    final nowMs = now.millisecondsSinceEpoch;
    if (connected) {
      if (!isRunning) {
        _runningSinceMs = nowMs;
        await _persist();
        return;
      }
      return;
    }
    if (isRunning) {
      // Reconcile a persisted run after process death. The monotonic wall clock
      // balance prevents a reboot from granting time beyond the saved balance.
      _balanceMs = math.max(
        0,
        _balanceMs - math.max(0, nowMs - _runningSinceMs),
      );
      _runningSinceMs = 0;
      await _persist();
    }
  }

  Future<void> add(Duration amount, DateTime now) async {
    final nowMs = now.millisecondsSinceEpoch;
    if (isRunning) {
      _balanceMs = math.max(
        0,
        _balanceMs - math.max(0, nowMs - _runningSinceMs),
      );
      _runningSinceMs = nowMs;
    }
    _balanceMs += amount.inMilliseconds;
    await _persist();
  }

  Future<void> _persist() async {
    await _prefs.setInt(_balanceKey, _balanceMs);
    await _prefs.setInt(_runningKey, _runningSinceMs);
  }
}

String formatTimer(Duration value) {
  final total = value.inSeconds;
  final days = total ~/ 86400;
  final hours = (total % 86400) ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  final seconds = total % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(days)}:${two(hours)}:${two(minutes)}:${two(seconds)}';
}

String describeRemaining(Duration value) {
  if (value.inDays >= 1) return '${value.inDays}d ${value.inHours % 24}h';
  if (value.inHours >= 1) return '${value.inHours}h ${value.inMinutes % 60}m';
  if (value.inMinutes >= 1) return '${value.inMinutes} min';
  return '${value.inSeconds} sec';
}
