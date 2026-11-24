import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../theme/swock_widgets.dart';

const _tutorialSeenKey = 'swock_tutorial_seen_v1';

Future<void> showAppTutorial(BuildContext context) async {
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const _TutorialDialog(),
  );
  final preferences = await SharedPreferences.getInstance();
  await preferences.setBool(_tutorialSeenKey, true);
}

Future<void> showAppTutorialIfNeeded(BuildContext context) async {
  final preferences = await SharedPreferences.getInstance();
  if (preferences.getBool(_tutorialSeenKey) ?? false) return;
  await Future<void>.delayed(const Duration(milliseconds: 350));
  if (!context.mounted) return;
  await showAppTutorial(context);
}

class _TutorialStep {
  const _TutorialStep(this.icon, this.title, this.description);

  final IconData icon;
  final String title;
  final String description;
}

class _TutorialDialog extends StatefulWidget {
  const _TutorialDialog();

  @override
  State<_TutorialDialog> createState() => _TutorialDialogState();
}

class _TutorialDialogState extends State<_TutorialDialog> {
  static const _steps = [
    _TutorialStep(
      Icons.power_settings_new_rounded,
      'Connect privately',
      'Select a profile in Configs, then tap the power control. The tunnel status appears on Home.',
    ),
    _TutorialStep(
      Icons.hourglass_bottom_rounded,
      'Keep VPN time',
      'Time counts down only while connected. Tap Add Time and complete three rewarded ads to add eight hours to your timer.',
    ),
    _TutorialStep(
      Icons.play_circle_outline_rounded,
      'Connection ads',
      'A regular interstitial may appear after the VPN connects; it does not award VPN time. Use Add Time to watch rewarded ads and earn extra VPN time.',
    ),
    _TutorialStep(
      Icons.wifi_tethering_rounded,
      'Share with Hotshare',
      'Connect the VPN first, then start Hotshare in Settings. Use proxy mode for manual proxy settings, or enable root direct mode to share without configuring proxies on connected devices.',
    ),
    _TutorialStep(
      Icons.tune_rounded,
      'Tune your connection',
      'Advanced options apply on the next connection. Disconnect the VPN before changing them.',
    ),
  ];

  final _controller = PageController();
  int _index = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _next() {
    if (_index == _steps.length - 1) {
      Navigator.of(context).pop();
      return;
    }
    _controller.nextPage(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) => Dialog(
    backgroundColor: const Color(0xFF101713),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(10),
      side: const BorderSide(color: Color(0xFF345341)),
    ),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 430),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 20, 22, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'SWOCK GUIDE',
                    style: TextStyle(
                      color: SwockColors.green,
                      fontFamily: 'monospace',
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 2,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Skip'),
                ),
              ],
            ),
            SizedBox(
              height: 252,
              child: PageView.builder(
                controller: _controller,
                itemCount: _steps.length,
                onPageChanged: (index) => setState(() => _index = index),
                itemBuilder: (context, index) {
                  final step = _steps[index];
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(4, 10, 4, 4),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 66,
                          height: 66,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: SwockColors.green.withValues(alpha: .1),
                            border: Border.all(
                              color: SwockColors.green.withValues(alpha: .45),
                            ),
                          ),
                          child: Icon(
                            step.icon,
                            color: SwockColors.green,
                            size: 30,
                          ),
                        ),
                        const SizedBox(height: 20),
                        Text(
                          step.title,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: SwockColors.ink,
                            fontSize: 19,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          step.description,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: SwockColors.muted,
                            fontSize: 13,
                            height: 1.45,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Text(
                  '${_index + 1} / ${_steps.length}',
                  style: const TextStyle(
                    color: SwockColors.faint,
                    fontFamily: 'monospace',
                    fontSize: 11,
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: _index == 0
                      ? null
                      : () => _controller.previousPage(
                            duration: const Duration(milliseconds: 260),
                            curve: Curves.easeOutCubic,
                          ),
                  child: const Text('Back'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _next,
                  child: Text(
                    _index == _steps.length - 1 ? 'Done' : 'Next',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
