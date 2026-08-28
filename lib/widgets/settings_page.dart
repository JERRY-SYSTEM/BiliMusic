import 'package:flutter/material.dart';
import 'package:hugeicons/hugeicons.dart';
import '../services/app_settings_service.dart';
import '../theme/app_theme.dart';
import 'cache_settings_page.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});
  static const colors = <Color>[Color(0xFFFF3366), Color(0xFF7C4DFF), Color(0xFF00A6FF), Color(0xFF00A878), Color(0xFFFF9800)];
  @override State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  static const _appVersion = String.fromEnvironment(
    'APP_VERSION',
    defaultValue: '3.12.0',
  );
  final settings = AppSettingsService.instance;
  @override void initState() { super.initState(); settings.addListener(_changed); }
  @override void dispose() { settings.removeListener(_changed); super.dispose(); }
  void _changed() { if (mounted) setState(() {}); }

  @override Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('设置')),
    body: Column(children: [
      Expanded(child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
        _entry(context, icon: HugeIcons.strokeRoundedShirt01, title: '外观设置', subtitle: '主题模式与主题色', onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AppearanceSettingsPage()))),
        _entry(context, icon: HugeIcons.strokeRoundedAudioWave01, title: '默认音质', subtitle: _qualityLabel(settings.defaultAudioQuality), onTap: () => _showQuality(context)),
        _entry(context, icon: HugeIcons.strokeRoundedPieChart03, title: '缓存管理', subtitle: '按歌曲管理音频、封面、歌词与元信息', onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const CacheSettingsPage()))),
      ])),
      SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Center(
            child: Text(
              '版本 $_appVersion',
              style: TextStyle(color: context.palette.textMuted),
            ),
          ),
        ),
      ),
    ]),
  );

  Widget _entry(BuildContext context, {required dynamic icon, required String title, required String subtitle, required VoidCallback onTap}) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: HugeIcon(icon: icon, color: context.palette.textSecondary),
    title: Text(title), subtitle: Text(subtitle, style: TextStyle(color: context.palette.textMuted)),
    trailing: HugeIcon(icon: HugeIcons.strokeRoundedArrowRight01, color: context.palette.textMuted), onTap: onTap,
  );

  String _qualityLabel(int value) => value == 30232 ? '132k' : value == 30251 ? 'Hi-Res / FLAC' : '192k / 自动';
  Future<void> _showQuality(BuildContext context) async {
    const options = <MapEntry<int, String>>[MapEntry(30280, '192k / 自动'), MapEntry(30251, 'Hi-Res / FLAC'), MapEntry(30232, '132k')];
    await showModalBottomSheet<void>(context: context, showDragHandle: true, builder: (sheet) => SafeArea(child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), shrinkWrap: true, children: options.map((option) => ListTile(
      title: Text(option.value), selected: settings.defaultAudioQuality == option.key,
      trailing: settings.defaultAudioQuality == option.key ? HugeIcon(icon: HugeIcons.strokeRoundedTick01, color: context.palette.accent) : null,
      onTap: () { settings.setDefaultAudioQuality(option.key); Navigator.pop(sheet); },
    )).toList())));
  }
}

class AppearanceSettingsPage extends StatefulWidget {
  const AppearanceSettingsPage({super.key});
  @override State<AppearanceSettingsPage> createState() => _AppearanceSettingsPageState();
}
class _AppearanceSettingsPageState extends State<AppearanceSettingsPage> {
  final settings = AppSettingsService.instance;
  static const colors = SettingsPage.colors;
  @override void initState() { super.initState(); settings.addListener(_changed); }
  @override void dispose() { settings.removeListener(_changed); super.dispose(); }
  void _changed() { if (mounted) setState(() {}); }
  @override Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: const Text('外观设置')), body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
    Text('主题模式', style: Theme.of(context).textTheme.titleMedium), const SizedBox(height: 8),
    Card(clipBehavior: Clip.antiAlias, child: Column(children: ['system', 'light', 'dark'].map((mode) => RadioListTile<String>(value: mode, groupValue: settings.themeMode, title: Text({'system':'跟随系统','light':'浅色','dark':'深色'}[mode]!), subtitle: Text({'system':'根据系统明暗自动切换','light':'始终使用浅色','dark':'始终使用深色'}[mode]!), onChanged: (v) { if (v != null) settings.setThemeMode(v); })).toList())),
    const SizedBox(height: 24), Text('主题颜色', style: Theme.of(context).textTheme.titleMedium), const SizedBox(height: 8),
    Card(child: Padding(padding: const EdgeInsets.all(16), child: Wrap(spacing: 18, runSpacing: 12, children: colors.map((color) => IconButton(onPressed: () => settings.setAccentValue(color.value), tooltip: '选择主题色', icon: Container(width: 30, height: 30, decoration: BoxDecoration(color: color, shape: BoxShape.circle, boxShadow: settings.accentValue == color.value ? const [BoxShadow(blurRadius: 8)] : null)))).toList()))),
  ]));
}
