import 'package:bilimusic/services/diagnostic_log.dart';
import 'package:bilimusic/widgets/diagnostics_page.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('iOS export failure keeps the snapshot available for copy and view', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    const channel = MethodChannel('bilimusic/diagnostics');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    String? copied;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'shareLog');
      expect((call.arguments as Map)['text'], contains('test.export_snapshot'));
      throw PlatformException(code: 'log_staging_failed', message: 'write failed');
    });
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      messenger.setMockMethodCallHandler(channel, null);
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    });
    DiagnosticLog.event('test.export_snapshot');
    await tester.pumpWidget(const MaterialApp(home: DiagnosticsPage()));
    await tester.tap(find.text('导出诊断日志'));
    await tester.pumpAndSettle();
    expect(find.textContaining('文件导出失败'), findsOneWidget);
    await tester.tap(find.text('复制日志'));
    await tester.pumpAndSettle();
    expect(copied, contains('test.export_snapshot'));
    expect(copied, contains('log_staging_failed'));
    await tester.tap(find.text('查看日志'));
    await tester.pumpAndSettle();
    expect(find.text('日志内容'), findsOneWidget);
    final text = tester.widget<SelectableText>(find.byType(SelectableText));
    expect(text.data, copied);
  });
}
