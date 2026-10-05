import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Diagnostics never depend on the playback database. Memory remains usable
/// for export even when directory lookup or file writes stop completing.
class DiagnosticLog {
  static final _lines = Queue<String>();
  static final _clock = Stopwatch()..start();
  static final _session = DateTime.now().toUtc().toIso8601String();
  static File? _file;
  static Future<void> _writes = Future<void>.value();
  static int _pending = 0;
  static int _operation = 0;

  static Future<void> initialize() async {
    event('session.start', {
      'os': Platform.operatingSystemVersion,
      'dart': Platform.version,
      'app': const String.fromEnvironment('APP_VERSION', defaultValue: '3.12.0'),
      'revision': const String.fromEnvironment('GIT_REVISION', defaultValue: 'unknown'),
      'flutter': const String.fromEnvironment('BILIMUSIC_FLUTTER_VERSION', defaultValue: 'unknown'),
    });
    try {
      final directory = await trace('diagnostics.directory', getApplicationSupportDirectory)
          .timeout(const Duration(seconds: 5));
      final folder = Directory('${directory.path}/bilimusic_diagnostics');
      await folder.create(recursive: true).timeout(const Duration(seconds: 5));
      _file = File('${folder.path}/current.jsonl');
      event('diagnostics.ready', {
        'os': Platform.operatingSystemVersion,
        'app': const String.fromEnvironment('APP_VERSION', defaultValue: '3.12.0'),
        'revision': const String.fromEnvironment('GIT_REVISION', defaultValue: 'unknown'),
        'flutter': const String.fromEnvironment('BILIMUSIC_FLUTTER_VERSION', defaultValue: 'unknown'),
      });
    } catch (error, stack) {
      event('diagnostics.memory_only', {'error': '$error', 'stack': '$stack'});
    }
  }

  static void event(String name, [Map<String, Object?> fields = const {}]) {
    final line = jsonEncode({
      'time': DateTime.now().toUtc().toIso8601String(),
      'session': _session,
      'elapsedMs': _clock.elapsedMilliseconds,
      'event': name,
      ...fields.map((key, value) {
        if (value is! String) return MapEntry(key, value);
        final safe = redact(value);
        return MapEntry(key, safe.length > 4096 ? '${safe.substring(0, 4096)} [truncated]' : safe);
      }),
    });
    _lines.add(line);
    if (_lines.length > 2000) _lines.removeFirst();
    final file = _file;
    if (file == null || _pending >= 100) return;
    _pending++;
    _writes = _writes.then((_) async {
      try {
        if (await file.exists() && await file.length() > 2 * 1024 * 1024) {
          final previous = File('${file.parent.path}/previous.jsonl');
          if (await previous.exists()) await previous.delete();
          await file.rename(previous.path);
        }
        await file.writeAsString('$line\n', mode: FileMode.append);
      } catch (_) {
        // Recording must never interrupt the operation being diagnosed.
      } finally {
        _pending--;
      }
    });
  }

  /// A warning observes a slow operation; it does not cancel or retry it.
  static Future<T> trace<T>(String name, Future<T> Function() action) async {
    final id = ++_operation;
    final watch = Stopwatch()..start();
    event('$name.begin', {'operation': id});
    final warning = Timer(const Duration(seconds: 15), () {
      event('$name.waiting', {'operation': id, 'ms': watch.elapsedMilliseconds});
    });
    try {
      final result = await action();
      event('$name.end', {'operation': id, 'ms': watch.elapsedMilliseconds});
      return result;
    } catch (error, stack) {
      event('$name.error', {'operation': id, 'ms': watch.elapsedMilliseconds,
        'error': redact('$error'), 'stack': '$stack'});
      rethrow;
    } finally {
      warning.cancel();
    }
  }

  static String redact(String text) => text
      .replaceAll(RegExp(r'https?://[^\s\)\]]+'), '[URL]')
      .replaceAll(RegExp(r'(SESSDATA|bili_jct|cookie|authorization)[=:][^\s,;]+', caseSensitive: false), '[credential]');

  static Future<String> exportText() async {
    event('diagnostics.export');
    // Always take the memory snapshot before attempting potentially stuck IO.
    final memory = _lines.join('\n');
    final file = _file;
    if (file == null) return '$memory\n';
    try {
      final disk = await (() async {
        await _writes;
        final previous = File('${file.parent.path}/previous.jsonl');
        return '${await previous.exists() ? await previous.readAsString() : ''}'
            '${await file.exists() ? await file.readAsString() : ''}';
      })().timeout(const Duration(seconds: 3));
      return '${[...disk.split('\n'), ...memory.split('\n')].where((line) => line.isNotEmpty).toSet().join('\n')}\n';
    } catch (_) {
      return '$memory\n';
    }
  }
}
