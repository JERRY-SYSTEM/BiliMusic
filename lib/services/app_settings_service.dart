import 'package:flutter/foundation.dart';
import 'app_database.dart';

class AppSettingsService extends ChangeNotifier {
  AppSettingsService._();
  @visibleForTesting
  AppSettingsService.forTesting();
  static final AppSettingsService instance = AppSettingsService._();

  String themeMode = 'dark';
  int accentValue = 0xFFFF3366;
  int defaultAudioQuality = 30280;
  Future<void>? _initializing;
  Future<void> _pending = Future.value();

  Future<void> initialize() => _initializing ??= _load();
  Future<void> _load() async {
    try {
      final map = await AppDatabase.readState('settings');
      if (map != null) {
        themeMode = map['themeMode'] as String? ?? themeMode;
        accentValue = (map['accentValue'] as num?)?.toInt() ?? accentValue;
        defaultAudioQuality =
            (map['defaultAudioQuality'] as num?)?.toInt() ?? defaultAudioQuality;
      }
    } catch (_) {
      _initializing = null;
      rethrow;
    }
    notifyListeners();
  }

  Future<void> _save(String key, Object value) {
    final operation = _pending.then((_) async {
      await initialize();
      final map = <String, dynamic>{'themeMode': themeMode, 'accentValue': accentValue, 'defaultAudioQuality': defaultAudioQuality, key: value};
      await AppDatabase.writeState('settings', map);
      themeMode = map['themeMode'] as String;
      accentValue = map['accentValue'] as int;
      defaultAudioQuality = map['defaultAudioQuality'] as int;
      notifyListeners();
    });
    _pending = operation.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return operation;
  }

  Future<void> setThemeMode(String value) async {
    await _save('themeMode', value);
  }

  Future<void> setAccentValue(int value) async {
    await _save('accentValue', value);
  }

  Future<void> setDefaultAudioQuality(int value) async {
    await _save('defaultAudioQuality', value);
  }
}
