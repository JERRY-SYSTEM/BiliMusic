import 'package:flutter/material.dart';

import '../services/app_settings_service.dart';
import '../theme/app_theme.dart';
import 'cache_settings_page.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final settings = AppSettingsService.instance;
  static const colors = <Color>[Color(0xFFFF3366), Color(0xFF7C4DFF), Color(0xFF00A6FF), Color(0xFF00A878), Color(0xFFFF9800)];

  @override
  void initState() { super.initState(); settings.addListener(_changed); }
  @override
  void dispose() { settings.removeListener(_changed); super.dispose(); }
  void _changed() { if (mounted) setState(() {}); }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('设置')),
    body: ListView(padding: const EdgeInsets.all(20), children: [
      const Text('主题模式', style: AppTypography.title),
      const SizedBox(height: 8),
      Card(child: Column(children: [
        for (final mode in const ['system', 'light', 'dark']) RadioListTile<String>(
          value: mode, groupValue: settings.themeMode,
          title: Text({'system': '跟随系统', 'light': '浅色', 'dark': '深色'}[mode]!),
          onChanged: (v) { if (v != null) settings.setThemeMode(v); },
        ),
      ])),
      const SizedBox(height: 24),
      const Text('主题颜色', style: AppTypography.title),
      const SizedBox(height: 8),
      Card(child: Wrap(spacing: 18, runSpacing: 12, children: [
        for (final color in colors) IconButton(
          tooltip: '选择主题色',
          onPressed: () => settings.setAccentValue(color.value),
          icon: Icon(Icons.circle, color: color, size: 30,
              shadows: settings.accentValue == color.value ? const [Shadow(blurRadius: 8)] : null),
        ),
      ])),
      const SizedBox(height: 24),
      const Text('默认下载音质', style: AppTypography.title),
      const SizedBox(height: 8),
      Card(child: DropdownButtonHideUnderline(child: DropdownButton<int>(
        value: const [30232, 30280, 30251].contains(settings.defaultAudioQuality) ? settings.defaultAudioQuality : 30280,
        isExpanded: true, padding: const EdgeInsets.symmetric(horizontal: 16),
        items: const [DropdownMenuItem(value: 30232, child: Text('132k')), DropdownMenuItem(value: 30280, child: Text('192k / 自动')), DropdownMenuItem(value: 30251, child: Text('Hi-Res / FLAC'))],
        onChanged: (value) { if (value != null) settings.setDefaultAudioQuality(value); },
      ))),
      const SizedBox(height: 24),
      ListTile(
        leading: const Icon(Icons.cleaning_services_outlined), title: const Text('缓存管理'),
        subtitle: const Text('图片、歌词、元信息和已下载音频'), trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const CacheSettingsPage())),
      ),
    ]),
  );
}
