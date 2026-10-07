import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/diagnostic_log.dart';

class DiagnosticsPage extends StatefulWidget {
  const DiagnosticsPage({super.key});
  @override
  State<DiagnosticsPage> createState() => _DiagnosticsPageState();
}

class _DiagnosticsPageState extends State<DiagnosticsPage> {
  static const _channel = MethodChannel('bilimusic/diagnostics');
  bool _busy = false;
  String? _snapshot;

  Future<void> _capture({bool markProblem = false}) async {
    setState(() { _busy = true; _snapshot = null; });
    try {
      if (markProblem) DiagnosticLog.event('user.problem_observed');
      await DiagnosticLog.sampleResources(markProblem ? 'user.problem' : 'user.manual', force: true);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(
          markProblem ? '已标记故障并请求资源采样，请复制或导出日志' : '已请求资源采样，请复制或导出日志')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copy() async {
    setState(() => _busy = true);
    try {
      final text = _snapshot ?? await DiagnosticLog.exportText();
      _snapshot = text;
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('日志已复制，可粘贴到聊天或备忘录')));
      }
    } catch (error, stack) {
      DiagnosticLog.event('diagnostics.copy_error', {'error': '$error', 'stack': '$stack'});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('复制失败，请使用查看日志')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _view() async {
    setState(() => _busy = true);
    try {
      final text = _snapshot ?? await DiagnosticLog.exportText();
      _snapshot = text;
      if (!mounted) return;
      await Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => Scaffold(
        appBar: AppBar(title: const Text('日志内容')),
        body: SingleChildScrollView(padding: const EdgeInsets.all(16),
          child: SelectableText(text, style: const TextStyle(fontFamily: 'monospace', fontSize: 12))),
      )));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _export() async {
    setState(() => _busy = true);
    try {
      final text = await DiagnosticLog.exportText();
      _snapshot = text;
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
        // Keep the snapshot in memory if staging or the file provider fails.
        await _channel.invokeMethod<bool>('shareLog', {'text': text});
        return;
      }
      final path = await FilePicker.saveFile(
        dialogTitle: '保存诊断日志',
        fileName: 'bilimusic-diagnostics-${DateTime.now().millisecondsSinceEpoch}.txt',
        type: FileType.custom,
        allowedExtensions: const ['txt'],
        mimeType: 'text/plain',
        bytes: Uint8List.fromList(utf8.encode(text)),
      );
      if (mounted && path != null) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('诊断日志已导出')));
      }
    } catch (error, stack) {
      DiagnosticLog.event('diagnostics.export_error', {'error': '$error', 'stack': '$stack'});
      // Include the export failure while preserving the original snapshot.
      _snapshot = '${_snapshot ?? ''}${jsonEncode({
        'time': DateTime.now().toUtc().toIso8601String(),
        'event': 'diagnostics.export_error',
        'error': DiagnosticLog.redact('$error'),
      })}\n';
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('文件导出失败，日志仍保留。请点击“复制日志”或“查看日志”')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('诊断日志')),
    body: ListView(padding: const EdgeInsets.all(20), children: [
      const Text('日志会自动记录后台切换、封面加载和缓存扫描。复现后先标记故障，再导出。iPhone 会打开分享面板，可选择“存储到文件”。若保存失败，可复制或查看日志；操作前请保持应用运行。'),
      const SizedBox(height: 16),
      OutlinedButton(onPressed: _busy ? null : () => _capture(markProblem: true), child: const Text('标记刚刚出现的问题')),
      const SizedBox(height: 8),
      OutlinedButton(onPressed: _busy ? null : _capture, child: const Text('采集当前资源占用')),
      const SizedBox(height: 8),
      FilledButton(onPressed: _busy ? null : _export,
        child: Text(_busy ? '处理中…' : '导出诊断日志')),
      const SizedBox(height: 8),
      OutlinedButton(onPressed: _busy ? null : _copy, child: const Text('复制日志')),
      TextButton(onPressed: _busy ? null : _view, child: const Text('查看日志')),
    ]),
  );
}
