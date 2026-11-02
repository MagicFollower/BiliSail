import 'dart:async';

import 'package:flutter/services.dart';

import '../../../core/diagnostics/diagnostics_log.dart';
import '../../../domain/app_failure.dart';
import '../../../domain/request_cancellation.dart';
import '../domain/download_models.dart';
import '../domain/public_download_storage.dart';

final class AndroidPublicDownloadStorage implements PublicDownloadStorage {
  const AndroidPublicDownloadStorage();
  static const _channel = MethodChannel('dev.bilisail/download_storage');

  /// Coarse round trips only. The byte traffic of a download does not come
  /// through [_call], so bracketing these keeps a row per storage operation -
  /// which is what tells a call that never returned from one that did.
  static const _traced = {
    'destination',
    'choose',
    'listFolders',
    'readText',
    'copyPublished',
    'adopt',
    'publish',
    'verify',
    'delete',
  };

  /// How long a traced call may stay outstanding before the log records that it
  /// is still waiting and asks the handler where it is. A provider that blocks
  /// is invisible from Dart otherwise: the await simply never resumes.
  static const _waitThreshold = Duration(seconds: 20);

  /// Calls whose work is bounded in bytes, so a provider that stops answering
  /// has to become a reported failure instead of a spinner that never ends.
  /// `publish` and `verify` are excluded: moving a media file legitimately takes
  /// longer than any timeout worth waiting for.
  static const _deadlineMethods = {
    'listFolders',
    'readText',
    'copyPublished',
    'adopt',
  };

  static const _deadline = Duration(seconds: 60);

  Future<T?> _call<T>(String method, [Map<String, Object?>? args]) async {
    final log = DiagnosticsLog.instance;
    final trace = log != null && _traced.contains(method);
    Timer? watchdog;
    if (trace) {
      await log.note('原生 $method →');
      watchdog = Timer(_waitThreshold, () {
        unawaited(
          lastNativeStep().then(
            (step) => log.note(
              '原生 $method 等待超过 ${_waitThreshold.inSeconds}s'
              '${step == null || step.isEmpty ? '' : '，停在：$step'}',
            ),
          ),
        );
      });
    }
    try {
      final pending = _channel.invokeMethod<T>(method, args);
      final value = _deadlineMethods.contains(method)
          ? await pending.timeout(_deadline)
          : await pending;
      if (trace) await log.note('原生 $method ←');
      return value;
    } on TimeoutException {
      if (trace) {
        await log.note('原生 $method ✗ 超时 ${_deadline.inSeconds}s');
      }
      throw const AppFailure(AppFailureKind.storage, '公共下载目录没有响应，已放弃本次操作');
    } on PlatformException catch (e) {
      if (trace) {
        await log.note('原生 $method ✗ ${e.code} ${e.message ?? ''}');
      }
      throw AppFailure(
        e.code == 'permission'
            ? AppFailureKind.permission
            : AppFailureKind.storage,
        e.message ?? '公共下载位置不可用，请重新授权或连接存储设备',
      );
    } finally {
      watchdog?.cancel();
    }
  }

  /// Where the previous process left the native side, or the step it is in right
  /// now. Kept in preferences, so it survives being killed.
  @override
  Future<String?> lastNativeStep() async {
    try {
      return await _channel.invokeMethod<String>('lastNativeStep');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  Map<String, Object?> _task(DownloadTask task) => {
    'id': task.id,
    'scope': task.scope,
    'destination': task.publicDestination,
    'uris': task.publicFiles,
  };

  @override
  Future<bool> hasDestination() async =>
      await _call<bool>('hasDestination') ?? false;

  @override
  Future<bool> requestDirectoryAccess() async =>
      await _call<bool>('requestAccess') ?? false;

  @override
  Future<DownloadFolderListing> listDirectories(String? directory) async {
    final value = await _call<Map<Object?, Object?>>('listDirectories', {
      'directory': directory,
    });
    DownloadFolder folder(Object? item) {
      if (item case {'path': final String path, 'name': final String name}) {
        return DownloadFolder(path: path, name: name);
      }
      throw const AppFailure(AppFailureKind.storage, '文件夹信息无效');
    }

    if (value case {'folders': final List<Object?> folders}) {
      return DownloadFolderListing(
        directory: value['directory'] == null
            ? null
            : folder(value['directory']),
        parent: value['parent'] as String?,
        folders: folders.map(folder).toList(),
        truncated: value['truncated'] == true,
      );
    }
    throw const AppFailure(AppFailureKind.storage, '无法读取文件夹');
  }

  @override
  Future<void> chooseDestination(String directory) =>
      _call<void>('choose', {'directory': directory});

  @override
  Future<String> destination() async {
    final value = await _call<String>('destination');
    if (value == null) {
      throw const AppFailure(AppFailureKind.permission, '请先选择公共下载保存位置');
    }
    return value;
  }

  @override
  Future<Map<String, String>> publish(
    DownloadTask task,
    Map<String, String> files, {
    required String folder,
    required RequestCancellation cancellation,
  }) async {
    var finished = false;
    cancellation.onCancel(() {
      if (!finished) {
        unawaited(_call<void>('cancel', _task(task)).catchError((Object _) {}));
      }
    });
    try {
      if (cancellation.isCancelled) {
        throw const AppFailure(AppFailureKind.cancelled, '保存已取消');
      }
      final result = await _call<Map<Object?, Object?>>('publish', {
        ..._task(task),
        'folder': folder,
        'files': files,
      });
      return result!.cast<String, String>();
    } finally {
      finished = true;
    }
  }

  @override
  Future<void> verify(DownloadTask task) => _call<void>('verify', _task(task));
  @override
  Future<void> delete(DownloadTask task) => _call<void>('delete', _task(task));

  @override
  Future<List<PublishedFolder>> listPublishedFolders() async {
    final destination = await this.destination();
    final value = await _call<Map<Object?, Object?>>('listFolders', {
      'destination': destination,
    });
    if (value?['folders'] case final List<Object?> folders) {
      return [
        for (final folder in folders)
          if (folder case {
            'key': final String key,
            'name': final String name,
            'files': final List<Object?> files,
          })
            PublishedFolder(
              key: key,
              name: name,
              files: [
                for (final file in files)
                  if (file case {
                    'name': final String fileName,
                    'uri': final String uri,
                    'bytes': final int bytes,
                    'modifiedMs': final int modifiedMs,
                  })
                    PublishedFile(
                      name: fileName,
                      uri: uri,
                      bytes: bytes,
                      modifiedMs: modifiedMs,
                    ),
              ],
            ),
      ];
    }
    throw const AppFailure(AppFailureKind.storage, '无法读取下载目录');
  }

  @override
  Future<String> readPublishedText({
    required String folder,
    required String uri,
    int maxBytes = 262144,
  }) async {
    final destination = await this.destination();
    final value = await _call<String>('readText', {
      'destination': destination,
      'folder': folder,
      'uri': uri,
      'maxBytes': maxBytes,
    });
    if (value == null) {
      throw const AppFailure(AppFailureKind.storage, '无法读取下载清单');
    }
    return value;
  }

  @override
  Future<void> adoptPublishedFolder({
    required DownloadTask task,
    required String folder,
    required Map<String, String> files,
  }) async {
    final destination = await this.destination();
    await _call<void>('adopt', {
      ..._task(task),
      'destination': destination,
      'folder': folder,
      'files': files,
    });
  }

  @override
  Future<void> copyPublishedSidecar({
    required String folder,
    required String uri,
    required String targetPath,
  }) async {
    final destination = await this.destination();
    await _call<void>('copyPublished', {
      'destination': destination,
      'folder': folder,
      'uri': uri,
      'targetPath': targetPath,
    });
  }
}
