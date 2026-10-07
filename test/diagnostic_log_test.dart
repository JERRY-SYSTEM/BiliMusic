import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:bilimusic/services/diagnostic_log.dart';

void main() {
  testWidgets('iOS resource snapshots report descriptor growth and playback context', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    const channel = MethodChannel('bilimusic/diagnostics');
    var calls = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'resourceSnapshot');
      calls++;
      return {'fdCount': 10 + calls, 'categories': {'audio_cache': calls},
        'softLimit': '256', 'targets': [], 'scanTruncated': false};
    });
    try {
      DiagnosticLog.playbackContext({'nativeQueueLength': 4});
      await DiagnosticLog.sampleResources('test.first', force: true);
      await DiagnosticLog.sampleResources('test.second', force: true);
      await DiagnosticLog.sampleResources('test.throttled');
      expect(calls, 2);
      final rows = (await DiagnosticLog.exportText()).trim().split('\n')
          .map((line) => jsonDecode(line) as Map<String, dynamic>);
      final second = rows.singleWhere((row) => row['reason'] == 'test.second');
      expect(second['deltaFromPrevious'], 1);
      expect(second['categoryDelta'], {'audio_cache': 1});
      expect(second['nativeQueueLength'], 4);
    } finally {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('slow operation is reported without cancellation', (tester) async {
    final completer = Completer<int>();
    final operation = DiagnosticLog.trace('test.slow', () => completer.future);
    await tester.pump(const Duration(seconds: 16));
    final text = await DiagnosticLog.exportText();
    expect(text, contains('test.slow.waiting'));
    completer.complete(7);
    expect(await operation, 7);
  });

  test('trace preserves results and errors with matched operation records', () async {
    expect(await DiagnosticLog.trace('test.success', () async => 42), 42);
    final error = StateError('test failure');
    await expectLater(DiagnosticLog.trace<void>('test.failure', () async {
      throw error;
    }), throwsA(same(error)));
    final records = (await DiagnosticLog.exportText()).trim().split('\n')
        .map((line) => jsonDecode(line) as Map<String, dynamic>).toList();
    final begin = records.singleWhere((row) => row['event'] == 'test.failure.begin');
    final failure = records.singleWhere((row) => row['event'] == 'test.failure.error');
    expect(failure['operation'], begin['operation']);
    expect(failure['stack'], isNotEmpty);
    expect(records.any((row) => row['event'] == 'test.success.end'), isTrue);
  });

  test('export stays bounded in memory and removes URLs and credentials', () async {
    for (var i = 0; i < 2100; i++) {
      DiagnosticLog.event('test.fill', {'index': i});
    }
    DiagnosticLog.event('test.private', {
      'error': 'failed https://example.com/image?token=secret SESSDATA=secret cookie=secret',
    });
    final text = await DiagnosticLog.exportText();
    expect(text.trim().split('\n').length, 2000);
    expect(text, isNot(contains('secret')));
    expect(text, contains('[URL]'));
  });
}
