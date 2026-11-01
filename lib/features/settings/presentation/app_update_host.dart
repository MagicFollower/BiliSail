import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/platform/external_links.dart';
import '../../../shared/ui/app_dialog.dart';
import '../../../shared/ui/app_network_image.dart';
import '../../../shared/ui/app_notice.dart';
import '../application/app_update_controller.dart';
import '../domain/app_update.dart';

/// Process-level prompt host: independent of the selected workspace tab.
final class AppUpdateHost extends ConsumerStatefulWidget {
  const AppUpdateHost({
    super.key,
    required this.navigatorKey,
    required this.child,
  });
  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  @override
  ConsumerState<AppUpdateHost> createState() => _AppUpdateHostState();
}

final class _AppUpdateHostState extends ConsumerState<AppUpdateHost> {
  bool _scheduled = false, _showing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(
          ref.read(appUpdateControllerProvider.notifier).checkOnStartup(),
        );
      }
    });
  }

  void _schedulePrompt() {
    if (_scheduled || _showing) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (mounted) unawaited(_showPrompt());
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _openNotesLink(
    BuildContext context,
    Uri releaseUrl,
    String? href,
  ) async {
    final target = href == null ? null : Uri.tryParse(href);
    if (target == null) return;
    final uri = releaseUrl.resolveUri(target);
    if (!isAllowedWebLink(uri)) return;
    var opened = false;
    try {
      opened = await ref
          .read(webLinkOpenerProvider)(uri)
          .timeout(const Duration(seconds: 12));
    } on Exception {
      opened = false;
    }
    if (context.mounted && !opened) {
      showAppNotice(context, '无法打开浏览器，请稍后重试');
    }
  }

  Future<void> _showPrompt() async {
    final dialogContext = widget.navigatorKey.currentState?.overlay?.context;
    if (dialogContext == null || _showing) return;
    final controller = ref.read(appUpdateControllerProvider.notifier);
    final release = controller.takePendingRelease();
    if (release == null) return;
    _showing = true;
    try {
      final openRelease = await showAppDialog<bool>(
        context: dialogContext,
        builder: (context) => _UpdatePromptDialog(
          release: release,
          installedLabel: ref.read(installedAppVersionProvider).value?.label,
          onOpenNotesLink: (releaseUrl, href) =>
              _openNotesLink(dialogContext, releaseUrl, href),
        ),
      );
      if (openRelease == true && mounted) {
        final opened = await controller.openRelease(release);
        if (!opened && dialogContext.mounted) {
          showAppNotice(dialogContext, '无法打开浏览器，请在关于页查看 GitHub 地址');
        }
      }
    } finally {
      _showing = false;
      if (mounted &&
          ref.read(appUpdateControllerProvider).pendingRelease != null) {
        _schedulePrompt();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(appUpdateControllerProvider, (_, next) {
      if (next.pendingRelease != null) _schedulePrompt();
    });
    return widget.child;
  }
}

/// Release details plus the record of the request that produced them, so a
/// reported update is verifiable without capturing the network.
final class _UpdatePromptDialog extends StatelessWidget {
  const _UpdatePromptDialog({
    required this.release,
    required this.installedLabel,
    required this.onOpenNotesLink,
  });

  final AppRelease release;
  final String? installedLabel;
  final Future<void> Function(Uri releaseUrl, String? href) onOpenNotesLink;

  @override
  Widget build(BuildContext context) {
    final report = release.report;
    final publishedAt = release.publishedAt;
    return AlertDialog(
      title: Text('发现新版本 ${release.version.label}'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (release.prerelease) ...[
                const Text('这是预览版本，功能仍在完善中。'),
                const SizedBox(height: 12),
              ],
              _row(context, '本机版本', installedLabel ?? '未知'),
              _row(
                context,
                '发布时间',
                publishedAt == null ? '响应未提供' : _formatLocal(publishedAt),
              ),
              _row(context, 'Release 页面', release.url.toString()),
              if (release.assets.isNotEmpty)
                _row(context, '附件', _assetSummary(release.assets)),
              const SizedBox(height: 8),
              if (release.notes.trim().isEmpty)
                const SelectableText('新版本已发布，可前往 Release 页面查看详情并下载。')
              else
                MarkdownBody(
                  data: release.notes,
                  selectable: true,
                  fitContent: false,
                  styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context))
                      .copyWith(
                        a: TextStyle(
                          color: Theme.of(context).colorScheme.primary,
                          decoration: TextDecoration.underline,
                        ),
                        tableColumnWidth: const IntrinsicColumnWidth(),
                      ),
                  onTapLink: (_, href, _) =>
                      unawaited(onOpenNotesLink(release.url, href)),
                  imageBuilder: (uri, title, alt) {
                    final url = release.url.resolveUri(uri);
                    final fallback = Text(alt ?? title ?? '图片加载失败');
                    // Remote notes must not read local files or app assets.
                    if (!isAllowedWebLink(url)) return fallback;
                    return AppNetworkImage(
                      url: url.toString(),
                      fit: BoxFit.contain,
                      semanticLabel: alt ?? title,
                      errorBuilder: (_, _, _) => fallback,
                    );
                  },
                ),
              if (report != null) ...[
                const SizedBox(height: 4),
                ExpansionTile(
                  shape: const Border(),
                  collapsedShape: const Border(),
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: const EdgeInsets.only(bottom: 4),
                  title: const Text('查看本次请求详情'),
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _row(context, '请求', 'GET ${report.endpoint}'),
                          _row(context, '请求头', _headerSummary(report)),
                          _row(
                            context,
                            '状态码',
                            report.statusCode == null
                                ? '未记录（未走真实网络）'
                                : '${report.statusCode}',
                          ),
                          _row(
                            context,
                            '响应大小',
                            report.responseBytes == null
                                ? '未记录'
                                : '${report.responseBytes} 字节（解码后）',
                          ),
                          _row(context, '耗时', _elapsedLabel(report.elapsed)),
                          _row(
                            context,
                            '预发布通道',
                            report.prereleaseChannelIncluded ? '包含' : '排除',
                          ),
                          _row(
                            context,
                            '候选统计',
                            '${report.candidates} 条：草稿 ${report.skippedDrafts}、'
                                '预发布 ${report.skippedPrereleases}、'
                                '非版本标签 ${report.skippedUnversionedTags} 已排除',
                          ),
                        ],
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () async {
                          await Clipboard.setData(
                            ClipboardData(
                              text: report.toPlainText(
                                installedLabel: installedLabel,
                                selected: release.version,
                              ),
                            ),
                          );
                          if (context.mounted) {
                            showAppNotice(context, '请求详情已复制到剪贴板');
                          }
                        },
                        icon: const Icon(Icons.copy_all, size: 17),
                        label: const Text('复制请求详情'),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('稍后再说'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('前往 Release'),
        ),
      ],
    );
  }

  Widget _row(BuildContext context, String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 80,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: SelectableText(value, style: const TextStyle(fontSize: 12)),
        ),
      ],
    ),
  );

  static String _assetSummary(List<AppReleaseAsset> assets) => assets
      .map((asset) => '${asset.name}（${_sizeLabel(asset.sizeBytes)}）')
      .join('\n');

  static String _headerSummary(UpdateCheckReport report) => report
      .requestHeaders
      .entries
      .map((entry) => '${entry.key}: ${entry.value}')
      .join('\n');

  static String _elapsedLabel(Duration? elapsed) => elapsed == null
      ? '未记录'
      : '${(elapsed.inMilliseconds / 1000).toStringAsFixed(2)} 秒';

  static String _sizeLabel(int bytes) {
    if (bytes >= 1 << 20) {
      return '${(bytes / (1 << 20)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1 << 10) {
      return '${(bytes / (1 << 10)).toStringAsFixed(1)} KB';
    }
    return '$bytes B';
  }

  static String _formatLocal(DateTime time) {
    final local = time.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}
