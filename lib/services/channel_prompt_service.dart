import 'package:shared_preferences/shared_preferences.dart';

class ChannelPromptService {
  static const channelUrl = 'https://t.me/Digicelgroup_bot';
  static const snoozeDuration = Duration(days: 7);

  static const _joinedKey = 'swock_official_channel_joined_v1';
  static const _dismissedAtKey = 'swock_official_channel_dismissed_at_v1';

  Future<bool> shouldShow() async {
    final preferences = await SharedPreferences.getInstance();
    if (preferences.getBool(_joinedKey) ?? false) return false;

    final dismissedAt = preferences.getInt(_dismissedAtKey);
    if (dismissedAt == null) return true;

    final dismissedDate =
        DateTime.fromMillisecondsSinceEpoch(dismissedAt);
    return DateTime.now().difference(dismissedDate) >= snoozeDuration;
  }

  Future<void> markDismissed() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setInt(
      _dismissedAtKey,
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  Future<void> markJoined() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_joinedKey, true);
    await preferences.remove(_dismissedAtKey);
  }
}
