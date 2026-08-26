import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

class AppSettingsService extends ChangeNotifier {
  AppSettingsService._();
  static final AppSettingsService instance = AppSettingsService._();

  static const _fileName = 'bilibeat_settings.json';
  String themeMode = 'dark';
  int accentValue = 0xFFFF3366;
  int defaultAudioQuality = 30280;
  bool _loaded = false;

  Future<void> initialize() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$_fileName');
      if (await file.exists()) {
        final map = jsonDecode(await file.readAsString()) as Map;
        themeMode = map['themeMode'] as String? ?? themeMode;
        accentValue = (map['accentValue'] as num?)?.toInt() ?? accentValue;
        defaultAudioQuality =
            (map['defaultAudioQuality'] as num?)?.toInt() ?? defaultAudioQuality;
      }
    } catch (e) {
      debugPrint('settings restore failed: $e');
    }
    notifyListeners();
  }

  Future<void> _save() async {
    final dir = await getApplicationDocumentsDirectory();
    await File('${dir.path}/$_fileName').writeAsString(jsonEncode({
      'themeMode': themeMode,
      'accentValue': accentValue,
      'defaultAudioQuality': defaultAudioQuality,
    }));
  }

  Future<void> setThemeMode(String value) async {
    themeMode = value;
    notifyListeners();
    await _save();
  }

  Future<void> setAccentValue(int value) async {
    accentValue = value;
    notifyListeners();
    await _save();
  }

  Future<void> setDefaultAudioQuality(int value) async {
    defaultAudioQuality = value;
    notifyListeners();
    await _save();
  }
}
