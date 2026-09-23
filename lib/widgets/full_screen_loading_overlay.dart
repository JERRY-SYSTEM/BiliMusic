import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Blocks the whole app while a long-running import/sync operation is active.
class FullScreenLoadingOverlay extends StatelessWidget {
  const FullScreenLoadingOverlay({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Positioned.fill(
        child: Stack(
          fit: StackFit.expand,
          children: [
            const ModalBarrier(
              dismissible: false,
              color: Color(0x99000000),
            ),
            Center(
              child: Card(
                color: context.palette.backgroundElevated,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 28,
                    vertical: 24,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(
                        color: context.palette.accent,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        message,
                        style: TextStyle(color: context.palette.textPrimary),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      );
}
