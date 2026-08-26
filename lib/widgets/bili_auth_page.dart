import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../services/bili_auth_service.dart';
import '../theme/app_theme.dart';

class BiliAuthPage extends StatefulWidget {
  const BiliAuthPage({super.key});

  @override
  State<BiliAuthPage> createState() => _BiliAuthPageState();
}

class _BiliAuthPageState extends State<BiliAuthPage> {
  final controller = BiliAuthController.instance;

  @override
  void initState() {
    super.initState();
    controller.addListener(_changed);
    if (controller.status == BiliQrStatus.idle) {
      unawaited(controller.startQrLogin());
    }
  }

  @override
  void dispose() {
    controller.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    if (controller.status == BiliQrStatus.success) {
      Navigator.of(context).pop();
    } else {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final qr = controller.qrSession;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(title: const Text('登录 B 站'), backgroundColor: Colors.transparent),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Column(children: [
              Container(
                width: 280,
                height: 280,
                color: Colors.white,
                padding: const EdgeInsets.all(18),
                child: qr?.url.isNotEmpty == true
                    ? QrImageView(data: qr!.url, size: 240)
                    : Center(child: controller.status == BiliQrStatus.loading ? const CircularProgressIndicator() : const Icon(Icons.qr_code_2_rounded, size: 80, color: Colors.black45)),
              ),
              const SizedBox(height: 20),
              Text(_statusText, style: const TextStyle(color: AppColors.textSecondary), textAlign: TextAlign.center),
              const SizedBox(height: 20),
              FilledButton(onPressed: controller.status == BiliQrStatus.loading ? null : controller.startQrLogin, child: Text(qr == null ? '获取二维码' : '重新获取')),
              if (controller.session?.isLoggedIn == true) ...[
                const SizedBox(height: 24),
                Text(controller.session?.uname ?? '已登录', style: const TextStyle(color: AppColors.textPrimary)),
                TextButton(onPressed: controller.logout, child: const Text('退出登录')),
              ],
            ]),
          ),
        ),
      ),
    );
  }

  String get _statusText => switch (controller.status) {
        BiliQrStatus.loading => '正在获取二维码…',
        BiliQrStatus.waitingForScan => '请使用 B 站 App 扫码登录',
        BiliQrStatus.waitingForConfirm => '已扫码，请在手机上确认登录',
        BiliQrStatus.expired => '二维码已失效，请重新获取',
        BiliQrStatus.failure => controller.message ?? '登录失败，请重试',
        BiliQrStatus.success => '登录成功',
        BiliQrStatus.idle => '扫码后即可登录',
      };
}
