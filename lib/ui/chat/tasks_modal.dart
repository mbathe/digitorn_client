import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../../services/background_service.dart';
import '../../theme/app_theme.dart';

class TasksModal {
  static void show(BuildContext context) {
    showDialog(
      context: context,
      barrierColor: Colors.black38,
      builder: (_) => const _TasksDialog(),
    );
  }
}

class _TasksDialog extends StatelessWidget {
  const _TasksDialog();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final bg = context.watch<BackgroundService>();

    return Dialog(
      backgroundColor: c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: c.border),
      ),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 440),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
              child: Row(
                children: [
                  Icon(Icons.sync_rounded, size: 18, color: c.textMuted),
                  const SizedBox(width: 8),
                  Text('Background Tasks',
                    style: GoogleFonts.inter(
                      fontSize: 16, fontWeight: FontWeight.w600, color: c.textBright)),
                  const Spacer(),
                  if (bg.tasks.isNotEmpty)
                    Text('${bg.tasks.length}',
                      style: GoogleFonts.firaCode(fontSize: 11, color: c.textMuted)),
                  const SizedBox(width: 12),
                  GestureDetector(
                    onTap: () => Navigator.pop(context),
                    child: Icon(Icons.close_rounded, size: 18, color: c.textMuted),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: c.border),

            // Tasks list
            Flexible(
              child: bg.tasks.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.check_circle_outline_rounded,
                                size: 36, color: c.textDim),
                            const SizedBox(height: 12),
                            Text('No background tasks',
                              style: GoogleFonts.inter(
                                  fontSize: 13, color: c.textMuted)),
                          ],
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      itemCount: bg.tasks.length,
                      itemBuilder: (_, i) => _TaskRow(task: bg.tasks[i], c: c),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TaskRow extends StatelessWidget {
  final BackgroundTask task;
  final AppColors c;
  const _TaskRow({required this.task, required this.c});

  @override
  Widget build(BuildContext context) {
    final (IconData icon, Color color) = switch (task.status) {
      'running'   => (Icons.sync_rounded, c.blue),
      'completed' => (Icons.check_circle_rounded, c.green),
      'failed'    => (Icons.error_rounded, c.red),
      'cancelled' => (Icons.cancel_rounded, c.textMuted),
      _           => (Icons.schedule_rounded, c.textMuted),
    };

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(task.id,
                  style: GoogleFonts.firaCode(fontSize: 12, color: c.text)),
                if (task.status.isNotEmpty)
                  Text(task.status,
                    style: GoogleFonts.inter(fontSize: 11, color: c.textMuted)),
              ],
            ),
          ),
          if (task.progress != null && task.progress! > 0)
            SizedBox(
              width: 50,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: task.progress! / 100,
                  backgroundColor: c.border,
                  valueColor: AlwaysStoppedAnimation(color),
                  minHeight: 4,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
