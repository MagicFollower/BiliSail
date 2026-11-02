import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../shared/ui/app_dialog.dart';
import 'diagnostics_log.dart';

/// The reader for [DiagnosticsLog]: the only way to see what the app did on a
/// device that closes without a word and gives no log channel.
///
/// Everything here is local. Nothing is uploaded, and the stored text is
/// scrubbed of URL queries and credential-shaped fragments before it is written.
Future<void> showDiagnosticsLogDialog(BuildContext context) {
  return showAppDialog<void>(
    context: context,
    builder: (dialogContext) => const _DiagnosticsLogDialog(),
  );
}

final class _DiagnosticsLogDialog extends StatefulWidget {
  const _DiagnosticsLogDialog();

  @override
  State<_DiagnosticsLogDialog> createState() => _DiagnosticsLogDialogState();
}

final class _DiagnosticsLogDialogState extends State<_DiagnosticsLogDialog> {
  int _generation = 0;

  @override
  Widget build(BuildContext context) {
    final log = DiagnosticsLog.instance;
    if (log == null) {
      return const AlertDialog(title: Text('诊断日志'), content: Text('日志尚未就绪。'));
    }
    return AlertDialog(
      title: const Text('诊断日志'),
      content: SizedBox(
        width: 620,
        height: 420,
        child: FutureBuilder<List<DiagnosticsEntry>>(
          future: log.recent(limit: 600),
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            final entries = snapshot.data ?? const <DiagnosticsEntry>[];
            if (entries.isEmpty) {
              return const Center(child: Text('暂无记录。'));
            }
            final tail = DiagnosticsLog.previousProcessTail(entries, log.runId);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tail == null ? '本进程之前没有别的进程记录，说明还没崩过。' : '上一个进程停在：$tail'),
                const SizedBox(height: 8),
                Text('共 ${entries.length} 条，按时间从上到下；每个进程以「进程启动」分隔。'),
                const SizedBox(height: 8),
                Expanded(
                  child: ListView.builder(
                    key: ValueKey(_generation),
                    itemCount: entries.length,
                    itemBuilder: (context, index) {
                      final entry = entries[index];
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 1),
                        child: SelectableText(
                          '${_time(entry.at)}  ${entry.message}',
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                            height: 1.3,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            final text = DiagnosticsLog.render(await log.recent(limit: 600));
            await Clipboard.setData(ClipboardData(text: text));
            if (context.mounted) {
              ScaffoldMessenger.of(context)
                  .showSnackBar(const SnackBar(content: Text('已复制诊断日志')));
            }
          },
          child: const Text('复制全部'),
        ),
        TextButton(
          onPressed: () async {
            await log.clear();
            setState(() => _generation++);
          },
          child: const Text('清空'),
        ),
        TextButton(
          onPressed: () => setState(() => _generation++),
          child: const Text('刷新'),
        ),
      ],
    );
  }

  static String _time(DateTime at) => at.toString().substring(5, 19);
}
