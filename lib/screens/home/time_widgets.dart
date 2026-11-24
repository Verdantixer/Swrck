import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../services/time_bank_service.dart';
import '../../theme/swock_widgets.dart';

class TimerCard extends StatelessWidget {
  const TimerCard({
    super.key,
    required this.remaining,
    required this.counting,
    required this.message,
  });

  final Duration remaining;
  final bool counting;
  final String message;

  Color get _color {
    if (remaining == Duration.zero) return SwockColors.red;
    if (!counting) return SwockColors.ink;
    if (remaining <= const Duration(minutes: 1)) return SwockColors.red;
    if (remaining <= const Duration(minutes: 10)) return SwockColors.amber;
    return SwockColors.ink;
  }

  @override
  Widget build(BuildContext context) {
    final color = _color;
    return SwockCard(
      minHeight: 56,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: color.withValues(alpha: .1),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.timer_outlined,
              color: color.withValues(alpha: .85),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Timer: ${formatTimer(remaining)}',
                    style: TextStyle(
                      color: color,
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                      letterSpacing: .4,
                    ),
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  message,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: SwockColors.muted,
                    fontSize: 9,
                    height: 1.15,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class AddTimeButton extends StatefulWidget {
  const AddTimeButton({
    super.key,
    required this.onPressed,
    required this.cooldownSeconds,
    required this.busy,
    this.attention = false,
  });

  final VoidCallback onPressed;
  final int cooldownSeconds;
  final bool busy;
  final bool attention;

  @override
  State<AddTimeButton> createState() => _AddTimeButtonState();
}

class _AddTimeButtonState extends State<AddTimeButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1900),
  )..repeat();
  bool _pressed = false;

  bool get _enabled => widget.cooldownSeconds <= 0 && !widget.busy;

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final label = widget.busy
        ? 'LOADING'
        : widget.cooldownSeconds > 0
            ? 'WAIT ${widget.cooldownSeconds}s'
            : 'ADD TIME';
    return AnimatedScale(
      scale: _pressed && _enabled ? .95 : 1,
      duration: const Duration(milliseconds: 110),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapCancel: () => setState(() => _pressed = false),
        onTapUp: (_) => setState(() => _pressed = false),
        onTap: _enabled ? widget.onPressed : null,
        child: AnimatedBuilder(
          animation: _pulse,
          builder: (context, _) {
            final wave = (math.sin(_pulse.value * math.pi * 2) + 1) / 2;
            final glow = widget.attention ? 1.0 : .55;
            return Container(
              width: 112,
              height: 56,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(7),
                boxShadow: _enabled
                    ? [
                        BoxShadow(
                          color: SwockColors.green.withValues(
                            alpha: (.10 + .16 * wave) * glow,
                          ),
                          blurRadius: 8 + 8 * wave,
                        ),
                      ]
                    : const [],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(7),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: _enabled
                              ? const [Color(0xFF0E7C58), Color(0xFF075F63)]
                              : const [
                                  Color(0xFF1B231E),
                                  Color(0xFF161C18),
                                ],
                        ),
                      ),
                    ),
                    if (_enabled)
                      Positioned.fill(
                        child: OverflowBox(
                          maxHeight: 240,
                          alignment: Alignment(-1.6 + 3.2 * _pulse.value, 0),
                          child: Transform.rotate(
                            angle: .35,
                            child: Container(
                              width: 26,
                              height: 240,
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [
                                    Colors.white.withValues(alpha: 0),
                                    Colors.white.withValues(alpha: .10),
                                    Colors.white.withValues(alpha: 0),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: _enabled
                              ? SwockColors.green.withValues(alpha: .55)
                              : SwockColors.line,
                        ),
                        borderRadius: BorderRadius.circular(7),
                      ),
                    ),
                    Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          widget.busy
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: SwockColors.green,
                                  ),
                                )
                              : Transform.rotate(
                                  angle: _enabled
                                      ? math.sin(_pulse.value * math.pi * 2) *
                                          .12
                                      : 0,
                                  child: Icon(
                                    Icons.add_alarm_rounded,
                                    size: 18,
                                    color: _enabled
                                        ? const Color(0xFFD9FFEF)
                                        : SwockColors.faint,
                                  ),
                                ),
                          const SizedBox(height: 4),
                          Text(
                            label,
                            style: TextStyle(
                              color: _enabled
                                  ? const Color(0xFFD9FFEF)
                                  : SwockColors.muted,
                              fontFamily: 'monospace',
                              fontSize: 8,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class RewardTimeDialog extends StatefulWidget {
  const RewardTimeDialog({
    super.key,
    required this.showRewardAd,
    required this.onRewardComplete,
  });

  final Future<bool> Function() showRewardAd;
  final Future<void> Function() onRewardComplete;

  @override
  State<RewardTimeDialog> createState() => _RewardTimeDialogState();
}

class _RewardTimeDialogState extends State<RewardTimeDialog> {
  static const _requiredAds = 3;
  int _watchedAds = 0;
  int _cooldown = 0;
  bool _busy = false;
  String? _message;
  Timer? _cooldownTimer;

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    super.dispose();
  }

  Future<void> _watchAd() async {
    if (_busy || _cooldown > 0 || _watchedAds >= _requiredAds) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    var earned = false;
    try {
      earned = await widget.showRewardAd();
    } catch (_) {
      earned = false;
    }
    if (!mounted) return;
    if (!earned) {
      setState(() {
        _busy = false;
        _message = 'The ad reward was not confirmed. Please try again.';
      });
      return;
    }

    final nextCount = _watchedAds + 1;
    if (nextCount == _requiredAds) {
      setState(() {
        _watchedAds = nextCount;
        _message = 'All rewards confirmed. Adding your eight hours…';
      });
      try {
        await widget.onRewardComplete();
      } catch (_) {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _message = 'Could not save the time reward. Please try again.';
        });
        return;
      }
      if (mounted) Navigator.of(context).pop(true);
      return;
    }

    setState(() {
      _watchedAds = nextCount;
      _busy = false;
      _cooldown = 5;
      _message = 'Reward counted. Your next ad will be ready shortly.';
    });
    _cooldownTimer?.cancel();
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() => _cooldown = _cooldown > 0 ? _cooldown - 1 : 0);
      if (_cooldown == 0) timer.cancel();
    });
  }

  @override
  Widget build(BuildContext context) => Dialog(
        backgroundColor: const Color(0xFF101713),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: SwockColors.green.withValues(alpha: .36)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 24, 22, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 58,
                height: 58,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: SwockColors.green.withValues(alpha: .12),
                  border: Border.all(
                      color: SwockColors.green.withValues(alpha: .5)),
                ),
                child: const Icon(
                  Icons.timer_rounded,
                  color: SwockColors.green,
                  size: 29,
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'ADD 8 HOURS',
                style: TextStyle(
                  color: SwockColors.green,
                  fontFamily: 'monospace',
                  letterSpacing: 2,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Watch three rewarded ads to add eight hours to your VPN timer.',
                textAlign: TextAlign.center,
                style: TextStyle(color: SwockColors.muted, height: 1.4),
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(_requiredAds, (index) {
                  final complete = index < _watchedAds;
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 7),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 220),
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: complete
                            ? SwockColors.green.withValues(alpha: .18)
                            : const Color(0xFF19221C),
                        border: Border.all(
                          color:
                              complete ? SwockColors.green : SwockColors.line,
                        ),
                      ),
                      child: Icon(
                        complete
                            ? Icons.check_rounded
                            : Icons.play_arrow_rounded,
                        color: complete ? SwockColors.green : SwockColors.muted,
                        size: 23,
                      ),
                    ),
                  );
                }),
              ),
              const SizedBox(height: 12),
              Text(
                '$_watchedAds OF $_requiredAds ADS WATCHED',
                style: const TextStyle(
                  color: SwockColors.ink,
                  fontFamily: 'monospace',
                  letterSpacing: 1.1,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  value: _watchedAds / _requiredAds,
                  minHeight: 6,
                  backgroundColor: const Color(0xFF202923),
                  valueColor: const AlwaysStoppedAnimation(SwockColors.green),
                ),
              ),
              if (_message != null) ...[
                const SizedBox(height: 12),
                Text(
                  _message!,
                  textAlign: TextAlign.center,
                  style:
                      const TextStyle(color: SwockColors.muted, fontSize: 12),
                ),
              ],
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _busy || _cooldown > 0 ? null : _watchAd,
                  icon: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Color(0xFF07120B),
                          ),
                        )
                      : const Icon(Icons.play_circle_outline_rounded),
                  label: Text(
                    _busy
                        ? 'LOADING REWARDED AD…'
                        : _cooldown > 0
                            ? 'NEXT AD IN ${_cooldown}s'
                            : 'WATCH REWARDED AD',
                  ),
                ),
              ),
              TextButton(
                onPressed:
                    _busy ? null : () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
            ],
          ),
        ),
      );
}

/// Asks the user to add time; resolves true to add time, false to disconnect.
class TimeUpDialog extends StatefulWidget {
  const TimeUpDialog({super.key, required this.initialCooldownSeconds});

  final int initialCooldownSeconds;

  @override
  State<TimeUpDialog> createState() => _TimeUpDialogState();
}

class _TimeUpDialogState extends State<TimeUpDialog> {
  static const _grace = 30;
  int _left = _grace;
  late int _cooldown = widget.initialCooldownSeconds;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_left <= 1) {
        _timer?.cancel();
        Navigator.of(context).pop(false);
      } else {
        setState(() {
          _left--;
          if (_cooldown > 0) _cooldown--;
        });
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: false,
        child: Dialog(
          backgroundColor: const Color(0xFF101713),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: Color(0xFF53403A)),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 26, 24, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: SwockColors.red.withValues(alpha: .12),
                    border: Border.all(
                      color: SwockColors.red.withValues(alpha: .5),
                    ),
                  ),
                  child: const Icon(
                    Icons.timer_off_outlined,
                    color: SwockColors.red,
                    size: 30,
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  "TIME'S UP",
                  style: TextStyle(
                    color: SwockColors.red,
                    fontFamily: 'monospace',
                    letterSpacing: 2.2,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  'Add more VPN time to stay connected.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Text(
                  'The VPN disconnects in ${_left}s unless you add time.',
                  textAlign: TextAlign.center,
                  style:
                      const TextStyle(color: SwockColors.muted, height: 1.45),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _cooldown == 0
                        ? () => Navigator.of(context).pop(true)
                        : null,
                    icon: const Icon(Icons.add_alarm_rounded),
                    label: Text(
                      _cooldown == 0 ? 'ADD + TIME' : 'WAIT ${_cooldown}s',
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Disconnect'),
                ),
              ],
            ),
          ),
        ),
      );
}
