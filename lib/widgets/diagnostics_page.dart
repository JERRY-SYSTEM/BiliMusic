import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/diagnostic_log.dart';

class DiagnosticsPage extends StatefulWidget {
  const DiagnosticsPage({super.key});
  @override
  State<DiagnosticsPage> createState() => _DiagnosticsPageState();
}

class _DiagnosticsPageState extends State<DiagnosticsPage> {
  bool _busy = false;
  Future<void> _export() async {
    setState(() => _busy = true);
    try {
      final text = await DiagnosticLog.exportText();
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
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('导出失败：${DiagnosticLog.redact('$error')}')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('诊断日志')),
    body: ListView(padding: const EdgeInsets.all(20), children: [
      const Text('日志会自动记录后台切换、封面加载和缓存扫描。复现问题后，先标记故障，再导出日志；导出前请保持应用运行。'),
      const SizedBox(height: 16),
      OutlinedButton(onPressed: _busy ? null : () {
        DiagnosticLog.event('user.problem_observed');
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已标记当前故障时间')));
      }, child: const Text('标记刚刚出现的问题')),
      const SizedBox(height: 8),
      FilledButton(onPressed: _busy ? null : _export,
        child: Text(_busy ? '正在导出…' : '导出诊断日志')),
    ]),
  );
}
