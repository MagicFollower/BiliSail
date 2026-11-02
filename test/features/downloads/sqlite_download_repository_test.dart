import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:bilisail/core/diagnostics/diagnostics_log.dart';
import 'package:bilisail/core/storage/app_database.dart';
import 'package:bilisail/domain/app_failure.dart';
import 'package:bilisail/domain/request_cancellation.dart';
import 'package:bilisail/domain/video.dart';
import 'package:bilisail/features/downloads/data/sqlite_download_repository.dart';
import 'package:bilisail/features/downloads/data/download_file_store.dart';
import 'package:bilisail/features/downloads/domain/download_repository.dart';
import 'package:bilisail/features/downloads/domain/download_muxer.dart';
import 'package:bilisail/features/downloads/domain/public_download_storage.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  late File databaseFile;
  late HttpServer server;
  late _Sources sources;
  late AppDatabase db;
  late SqliteDownloadRepository repository;
  DownloadMuxer? muxer;
  _PublicStorage? publicStorage;
  var slow = false;
  var streamSlow = false;
  var rejectAudioOnce = false;
  var videoRequests = 0;
  Future<void> Function(HttpResponse)? streamVideo;
  final media = List<int>.generate(2048, (index) => index % 256);

  Future<void> openRepository({
    DateTime Function()? clock,
    DownloadFileStore? files,
    String? directory,
  }) async {
    db = AppDatabase(NativeDatabase(databaseFile));
    repository = SqliteDownloadRepository(
      db,
      sources,
      defaultDirectory: () async => directory ?? root.path,
      files: files,
      muxer: muxer,
      publicStorage: publicStorage,
      clock: clock,
    );
    await repository.initialize();
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('bilisail_queue');
    databaseFile = File('${root.path}/downloads.sqlite');
    slow = false;
    streamSlow = false;
    rejectAudioOnce = false;
    videoRequests = 0;
    streamVideo = null;
    muxer = null;
    publicStorage = null;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      if (request.uri.path.startsWith('/video')) videoRequests++;
      if (rejectAudioOnce && request.uri.path == '/audio') {
        rejectAudioOnce = false;
        request.response.statusCode = 403;
        await request.response.close();
        return;
      }
      final range = request.headers.value(HttpHeaders.rangeHeader);
      final start = range == null
          ? 0
          : int.parse(range.substring(6, range.length - 1));
      request.response.statusCode = range == null ? 200 : 206;
      request.response.headers.contentLength = media.length - start;
      if (range != null) {
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-${media.length - 1}/${media.length}',
        );
      }
      if (slow) await Future<void>.delayed(const Duration(milliseconds: 300));
      if (streamVideo case final send?
          when request.uri.path.startsWith('/video')) {
        await send(request.response);
      } else if (streamSlow && start == 0) {
        request.response.add(media.take(512).toList());
        await request.response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 650));
        request.response.add(media.skip(512).take(512).toList());
        await request.response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 650));
        request.response.add(media.skip(1024).toList());
      } else {
        request.response.add(media.skip(start).toList());
      }
      await request.response.close();
    });
    sources = _Sources(Uri.parse('http://127.0.0.1:${server.port}'));
    await openRepository();
  });

  tearDown(() async {
    await repository.close();
    await db.close();
    await server.close(force: true);
    await root.delete(recursive: true);
  });

  test(
    'public output survives restart without hidden media or source reads',
    () async {
      await repository.close();
      await db.close();
      publicStorage = _PublicStorage();
      await openRepository();
      await repository.enqueue([item], const DownloadSelection());
      await _waitFor(repository, DownloadStatus.completed);
      await repository.close();
      final task = repository.current.tasks.single;
      expect(task.publicDestination, 'downloads');
      // Media plus the sidecars that let the folder be recognised again after
      // the app - and its private staging directory - is gone.
      expect(task.publicFiles.keys, [
        'video.m4s',
        'audio.m4s',
        'manifest.json',
        'extras.json',
      ]);
      expect(
        publicStorage!.capturedFolders.single,
        startsWith('BV1234567890-P1'),
      );
      expect(await File('${task.directory}/video.m4s').exists(), isFalse);
      expect(await File('${task.directory}/audio.m4s').exists(), isFalse);
      final requests = videoRequests;
      await db.close();
      await openRepository();
      expect(
        (await repository.offlineTask(task.id)).publicFiles,
        task.publicFiles,
      );
      expect(videoRequests, requests);
      publicStorage!.available = false;
      await expectLater(
        repository.offlineTask(task.id),
        throwsA(isA<AppFailure>()),
      );
      expect(publicStorage!.deleted, isFalse);
      publicStorage!.available = true;
      await repository.refresh();
      expect(
        (await repository.offlineTask(task.id)).status,
        DownloadStatus.completed,
      );
      await repository.remove(task.id);
      expect(
        publicStorage!.deleted,
        isFalse,
        reason: '删除任务只移除记录，公共目录里的文件归用户所有',
      );
      expect(repository.current.tasks, isEmpty);
    },
  );

  test(
    'public publication failure retains private originals for retry',
    () async {
      await repository.close();
      await db.close();
      publicStorage = _PublicStorage()..failPublish = true;
      await openRepository();
      await repository.enqueue([item], const DownloadSelection());
      await _waitFor(repository, DownloadStatus.failed);
      final task = repository.current.tasks.single;
      expect(await File('${task.directory}/video.m4s').exists(), isTrue);
      expect(task.publicFiles, isEmpty);
      publicStorage!.failPublish = false;
      publicStorage!.selected = 'content://other/tree/new';
      final requests = videoRequests;
      await repository.resume(task.id);
      await _waitFor(repository, DownloadStatus.completed);
      expect(videoRequests, requests);
      expect(repository.current.tasks.single.publicFiles.keys, [
        'video.m4s',
        'audio.m4s',
        'manifest.json',
        'extras.json',
      ]);
      expect(publicStorage!.destinations, ['downloads', 'downloads']);
    },
  );

  test(
    'scan imports a published folder once, then skips it without reading',
    () async {
      await repository.close();
      await db.close();
      publicStorage = _PublicStorage();
      await openRepository();
      final storage = publicStorage!;
      storage.folders = [
        PublishedFolder(
          key: 'Download/BiliSail/BV1234567890-P1 视频/',
          name: 'BV1234567890-P1 视频',
          files: const [
            PublishedFile(
              name: 'media.mp4',
              uri: 'content://test/media',
              bytes: 2048,
              modifiedMs: 10,
            ),
            PublishedFile(
              name: 'manifest.json',
              uri: 'content://test/manifest',
              bytes: 512,
              modifiedMs: 11,
            ),
            PublishedFile(
              name: 'extras.json',
              uri: 'content://test/extras',
              bytes: 64,
              modifiedMs: 12,
            ),
          ],
        ),
      ];
      storage.texts['content://test/manifest'] = _publishedManifest();
      const extras = '{"version":1,"comments":[],"subtitles":[],"warnings":[]}';
      storage.texts['content://test/extras'] = extras;

      final first = await repository.scanShared();
      expect(first.imported, 1, reason: '${first.reasons}');
      final task = repository.current.tasks.single;
      expect(task.status, DownloadStatus.completed);
      expect(task.item.video.title, '扫描到的视频');
      expect(task.publicFiles['media.mp4'], 'content://test/media');
      expect(task.publicFiles['extras.json'], 'content://test/extras');
      // The sidecar comes back into the private directory, which is where
      // offline playback already looks for danmaku and subtitles.
      expect(
        await File('${task.directory}/extras.json').readAsString(),
        extras,
      );
      expect(storage.adopted.single.$1, _scannedId);
      expect(storage.readRequests, hasLength(1));

      final second = await repository.scanShared();
      expect(second.unchanged, 1);
      expect(second.imported, 0);
      expect(
        storage.readRequests,
        hasLength(1),
        reason: 'the cache must skip the read, not just the insert',
      );
    },
  );

  test('scan refuses a folder whose media bytes no longer match', () async {
    await repository.close();
    await db.close();
    publicStorage = _PublicStorage();
    await openRepository();
    final storage = publicStorage!;
    storage.folders = [
      PublishedFolder(
        key: 'Download/BiliSail/truncated/',
        name: 'truncated',
        files: const [
          PublishedFile(
            name: 'media.mp4',
            uri: 'content://test/media',
            bytes: 999,
            modifiedMs: 10,
          ),
          PublishedFile(
            name: 'manifest.json',
            uri: 'content://test/manifest',
            bytes: 512,
            modifiedMs: 11,
          ),
        ],
      ),
    ];
    storage.texts['content://test/manifest'] = _publishedManifest();

    final result = await repository.scanShared();
    expect(result.imported, 0);
    expect(result.rejected, 1);
    expect(result.reasons.single, contains('media.mp4'));
    expect(repository.current.tasks, isEmpty);
    expect(storage.adopted, isEmpty);
  });

  test('scanning again right after deleting an imported task stays in-process safe', () async {
    await repository.close();
    await db.close();
    publicStorage = _PublicStorage();
    await openRepository();
    final storage = publicStorage!;
    storage.folders = [
      PublishedFolder(
        key: 'Download/BiliSail/BV1234567890-P1 视频/',
        name: 'BV1234567890-P1 视频',
        files: const [
          PublishedFile(
            name: 'media.mp4',
            uri: 'content://test/media',
            bytes: 2048,
            modifiedMs: 10,
          ),
          PublishedFile(
            name: 'manifest.json',
            uri: 'content://test/manifest',
            bytes: 512,
            modifiedMs: 11,
          ),
        ],
      ),
    ];
    storage.texts['content://test/manifest'] = _publishedManifest();

    expect((await repository.scanShared()).imported, 1);
    final task = repository.current.tasks.single;
    await repository.remove(task.id);
    expect(repository.current.tasks, isEmpty);

    // Nothing was deleted on disk - the folder and its private directory both
    // survive a removed row - so the next pass has to put the part back.
    final second = await repository.scanShared();
    expect(second.imported, 1, reason: '${second.reasons}');
    final again = repository.current.tasks.single;
    expect(again.id, task.id);
    // The row was dropped with its cache entry, so the rescan recreated a
    // private directory instead of writing into a path nothing owns.
    expect(await File('${again.directory}/.bilisail-task').exists(), isTrue);

    // And once the folder is really gone, the cache entry must not keep
    // claiming the part is still there.
    storage.folders = const [];
    final third = await repository.scanShared();
    expect(third.folders, 0);
    expect(
      (await db
              .customSelect('SELECT COUNT(*) AS count FROM download_scan_cache')
              .getSingle())
          .read<int>('count'),
      0,
    );
  });

  test('a replacing scan retires the rows of the directory we left', () async {
    await repository.close();
    await db.close();
    publicStorage = _PublicStorage();
    await openRepository();
    final storage = publicStorage!;
    PublishedFolder folder() => PublishedFolder(
      key: 'Download/BiliSail/BV1234567890-P1 视频/',
      name: 'BV1234567890-P1 视频',
      files: const [
        PublishedFile(
          name: 'media.mp4',
          uri: 'content://test/media',
          bytes: 2048,
          modifiedMs: 10,
        ),
        PublishedFile(
          name: 'manifest.json',
          uri: 'content://test/manifest',
          bytes: 512,
          modifiedMs: 11,
        ),
      ],
    );
    storage.folders = [folder()];
    storage.texts['content://test/manifest'] = _publishedManifest();
    expect((await repository.scanShared()).imported, 1);
    expect(repository.current.tasks.single.publicDestination, 'downloads');

    // The user points the app at another folder that holds nothing yet. The
    // list follows that directory instead of keeping parts it cannot open.
    storage.selected = 'file:///sdcard/BiliSail 二';
    storage.folders = const [];
    final moved = await repository.scanShared(replaceCompleted: true);
    expect(moved.imported, 0);
    expect(repository.current.tasks, isEmpty);
    expect(storage.deleted, isFalse, reason: '换目录的清场只移除记录，不删任何文件');

    // Back to a directory that does hold the part: a plain scan re-imports
    // it under the destination it was found in.
    storage.selected = 'downloads';
    storage.folders = [folder()];
    expect((await repository.scanShared()).imported, 1);
    expect(repository.current.tasks.single.publicDestination, 'downloads');
  });

  test('the scan breadcrumb names the step a failed pass did not return from', () async {
    await repository.close();
    await db.close();
    publicStorage = _PublicStorage();
    await openRepository();
    final storage = publicStorage!;
    // Traced from the first pass on, so the anchors of an import, a wedge and a
    // cache hit all land in the same durable log.
    DiagnosticsLog.install(DiagnosticsLog(db));
    storage.nativeStep = '1700000000000 copyPublished 落盘 12 字节';
    expect(await repository.lastScanStage(), isNull);

    storage.folders = [
      PublishedFolder(
        key: 'Download/BiliSail/BV1234567890-P1 视频/',
        name: 'BV1234567890-P1 视频',
        files: const [
          PublishedFile(
            name: 'media.mp4',
            uri: 'content://test/media',
            bytes: 2048,
            modifiedMs: 10,
          ),
          PublishedFile(
            name: 'manifest.json',
            uri: 'content://test/manifest',
            bytes: 512,
            modifiedMs: 11,
          ),
        ],
      ),
    ];
    storage.texts['content://test/manifest'] = _publishedManifest();
    expect(await repository.scanShared(), isA<DownloadScanResult>());
    expect(
      await repository.lastScanStage(),
      isNull,
      reason: 'a pass that finished must leave no breadcrumb',
    );

    // A step that never returns - the process-dying case - must leave the
    // name of that step behind, which is the whole point of the breadcrumb.
    storage.failList = true;
    await expectLater(repository.scanShared(), throwsStateError);
    expect(await repository.lastScanStage(), 'listFolders');

    storage.failList = false;
    final recovered = await repository.scanShared();
    expect(
      recovered.unchanged,
      1,
      reason: 'the failed pass must not have lost the cache row it already had',
    );
    expect(
      await repository.lastScanStage(),
      isNull,
      reason: 'the next completed pass clears it',
    );

    // The trace is what outlives a completed pass - the breadcrumb is cleared -
    // and it opens with where the *previous* process died inside the native
    // handler, which is the only clue a killed process leaves behind.
    final traced = (await DiagnosticsLog.instance!.recent())
        .map((entry) => entry.message)
        .toList();
    expect(traced, contains('原生上次停在 1700000000000 copyPublished 落盘 12 字节'));
    expect(traced, contains('目的地 系统下载库'));
    expect(traced.any((line) => line.startsWith('清单已读')), isTrue);
    expect(traced.any((line) => line.startsWith('清单通过')), isTrue);
    expect(traced.any((line) => line.startsWith('入库')), isTrue);
    expect(traced.any((line) => line.startsWith('缓存命中')), isTrue);
    expect(traced.last, startsWith('扫描结束'));
    DiagnosticsLog.reset();
  });

  test(
    'a second scan is refused while one is in flight and the gate is released',
    () async {
      await repository.close();
      await db.close();
      publicStorage = _PublicStorage();
      await openRepository();
      final storage = publicStorage!;
      storage.folders = [
        PublishedFolder(
          key: 'Download/BiliSail/BV1234567890-P1 视频/',
          name: 'BV1234567890-P1 视频',
          files: const [
            PublishedFile(
              name: 'media.mp4',
              uri: 'content://test/media',
              bytes: 2048,
              modifiedMs: 10,
            ),
            PublishedFile(
              name: 'manifest.json',
              uri: 'content://test/manifest',
              bytes: 512,
              modifiedMs: 11,
            ),
          ],
        ),
      ];
      storage.texts['content://test/manifest'] = _publishedManifest();
      storage.listGate = Completer<void>();
      final first = repository.scanShared();
      for (var attempt = 0; attempt < 200 && !storage.listReached; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(storage.listReached, isTrue);

      final second = await repository.scanShared();
      expect(second.alreadyRunning, isTrue);
      expect(second.summary, '上一次扫描仍在进行中，本次未启动。');

      storage.listGate!.complete();
      expect((await first).imported, 1);

      // The gate must not stay closed after a pass that threw, or every later
      // scan would report "still running" forever.
      storage.failList = true;
      await expectLater(repository.scanShared(), throwsStateError);
      storage.failList = false;
      expect((await repository.scanShared()).unchanged, 1);
    },
  );

  test(
    'download commits without media digests and keeps URL-free records',
    () async {
      await repository.enqueue([item], const DownloadSelection());
      await _waitFor(repository, DownloadStatus.completed);
      final task = repository.current.tasks.single;
      expect(task.tracks.length, 2);
      expect(task.tracks.every((track) => track.complete), isTrue);
      expect(await File('${task.directory}/video.m4s').length(), media.length);
      expect(await File('${task.directory}/audio.m4s').length(), media.length);
      expect(await File('${task.directory}/extras.json').exists(), isTrue);
      final manifest = jsonDecode(
        await File('${task.directory}/manifest.json').readAsString(),
      ) as Map<String, Object?>;
      expect(manifest['version'], 3);
      // The manifest is published into shared storage, so it must not carry
      // the account scope, a signed URL or any session data.
      expect(manifest.containsKey('scope'), isFalse);
      expect((manifest['video']! as Map)['id'], 'BV1234567890');
      expect((manifest['part']! as Map)['page'], 1);
      expect(manifest['extras'], {
        'fileName': 'extras.json',
        'bytes': await File('${task.directory}/extras.json').length(),
      });
      expect(
        (await File(
          '${task.directory}/manifest.json',
        ).readAsString()).contains('http'),
        isFalse,
      );
      final record = await db
          .customSelect('SELECT record_json FROM download_tasks')
          .getSingle();
      expect(record.read<String>('record_json').contains('http'), isFalse);
      expect((await repository.offlineTask(task.id)).id, task.id);
    },
  );

  test(
    'Android anchor supports legacy records through resume, offline and delete',
    () async {
      await repository.close();
      await db.close();
      final documents = await Directory('${root.path}/app_flutter').create();
      final alias = await Link('${root.path}/system_alias')
          .create(documents.path);
      final files = DownloadFileStore(
        trustedDocumentsDirectory: () async => documents.path,
      );
      final downloadRoot = '${documents.path}/BiliSail/offline';
      await openRepository(files: files, directory: downloadRoot);
      slow = true;
      await repository.enqueue([item], const DownloadSelection());
      await _waitFor(repository, DownloadStatus.downloading);
      final id = repository.current.tasks.single.id;
      final directory = repository.current.tasks.single.directory;
      await repository.close();
      final row = await db
          .customSelect('SELECT record_json FROM download_tasks')
          .getSingle();
      final record =
          jsonDecode(row.read<String>('record_json')) as Map<String, dynamic>;
      final legacyPath = directory.replaceFirst(documents.path, alias.path);
      record['directory'] = legacyPath;
      await db.customStatement('UPDATE download_tasks SET record_json = ?', [
        jsonEncode(record),
      ]);
      await db.close();
      await openRepository(files: files, directory: downloadRoot);
      expect(repository.current.tasks.single.status, DownloadStatus.paused);
      expect(repository.current.tasks.single.directory, legacyPath);
      slow = false;
      await repository.resume(id);
      await _waitFor(repository, DownloadStatus.completed);
      expect((await repository.offlineTask(id)).directory, legacyPath);
      expect(await File('$directory/video.m4s').length(), media.length);
    },
    skip: Platform.isWindows
        ? 'Creating Windows symlinks requires additional privileges.'
        : false,
  );

  test(
    'modified media remains playable across refresh and process restart',
    () async {
      await repository.enqueue([item], const DownloadSelection());
      await _waitFor(repository, DownloadStatus.completed);
      final id = repository.current.tasks.single.id;
      final directory = repository.current.tasks.single.directory;
      await repository.close();
      await db.close();
      await openRepository();
      expect(
        (await repository.offlineTask(id)).status,
        DownloadStatus.completed,
      );
      await File('$directory/video.m4s').writeAsBytes([1, 2, 3]);
      expect(
        (await repository.offlineTask(id)).status,
        DownloadStatus.completed,
      );
      await repository.refresh();
      await repository.close();
      await db.close();
      await openRepository();
      expect(
        (await repository.offlineTask(id)).status,
        DownloadStatus.completed,
      );
      expect(
        repository.current.tasks.single.tracks.every((t) => t.sha256 == null),
        isTrue,
      );
      await File('$directory/audio.m4s').delete();
      await expectLater(
        repository.offlineTask(id),
        throwsA(
          isA<AppFailure>().having(
            (e) => e.message,
            'missing track',
            contains('音频'),
          ),
        ),
      );
    },
  );

  test(
    'process restart pauses an in-flight task and account switch isolates it',
    () async {
      slow = true;
      await repository.enqueue([item], const DownloadSelection());
      await _waitFor(repository, DownloadStatus.downloading);
      await repository.close();
      await db.close();
      await openRepository();
      expect(repository.current.tasks.single.status, DownloadStatus.paused);
      sources.scope = 'user:2';
      sources.epoch++;
      await repository.sessionChanged();
      expect(repository.current.tasks, isEmpty);
      sources.scope = 'guest';
      sources.epoch++;
      await repository.sessionChanged();
      expect(repository.current.tasks.single.status, DownloadStatus.paused);
      slow = false;
      await repository.resume(repository.current.tasks.single.id);
      await _waitFor(repository, DownloadStatus.completed);
    },
  );

  test(
    'removing a row leaves the task files and everything beside them alone',
    () async {
      await repository.enqueue([item], const DownloadSelection());
      await _waitFor(repository, DownloadStatus.completed);
      final task = repository.current.tasks.single;
      final unrelated = File('${root.path}/keep.txt')
        ..writeAsStringSync('keep');
      await repository.remove(task.id);
      expect(repository.current.tasks, isEmpty);
      expect(
        await Directory(task.directory).exists(),
        isTrue,
        reason: '应用不再删除已下载文件',
      );
      expect(await unrelated.readAsString(), 'keep');
    },
  );

  test(
    'expired audio URL with changed identities resets both tracks',
    () async {
      rejectAudioOnce = true;
      sources.changeIdentityOnRefresh = true;
      await repository.enqueue([item], const DownloadSelection());
      await _waitFor(repository, DownloadStatus.completed);
      final task = repository.current.tasks.single;
      expect(sources.resolveCalls, 2);
      expect(videoRequests, 2);
      expect(task.tracks.map((track) => track.identity).toSet(), {
        'video:2',
        'audio:2',
      });
      expect(await repository.offlineTask(task.id), isA<DownloadTask>());
    },
  );

  test('refresh racing with remove cannot restore a deleted index', () async {
    await repository.enqueue([item], const DownloadSelection());
    await _waitFor(repository, DownloadStatus.completed);
    final id = repository.current.tasks.single.id;
    await Future.wait([repository.refresh(), repository.remove(id)]);
    expect(repository.current.tasks, isEmpty);
    expect(
      (await db
              .customSelect('SELECT COUNT(*) AS n FROM download_tasks')
              .getSingle())
          .read<int>('n'),
      0,
    );
  });

  test('account switch during removal aborts it and retains the row', () async {
    slow = true;
    await repository.enqueue([item], const DownloadSelection());
    await _waitFor(repository, DownloadStatus.downloading);
    final task = repository.current.tasks.single;
    final removal = repository.remove(task.id);
    sources.scope = 'user:2';
    sources.epoch++;
    final switchAccount = repository.sessionChanged();
    await Future.wait([removal, switchAccount]);
    expect(await Directory(task.directory).exists(), isTrue);
    sources.scope = 'guest';
    sources.epoch++;
    await repository.sessionChanged();
    expect(repository.current.tasks.single.id, task.id);
  });

  test('streaming progress publishes a nonzero transfer speed', () async {
    var now = DateTime.utc(2026, 10, 11);
    await repository.close();
    await db.close();
    await openRepository(clock: () => now);

    final nextChunks = List.generate(3, (_) => Completer<void>());
    addTearDown(() {
      for (final next in nextChunks) {
        if (!next.isCompleted) next.complete();
      }
    });
    streamVideo = (response) async {
      // flush alone does not guarantee separate client progress callbacks.
      // Wait for the client to observe each chunk before sending another.
      response.bufferOutput = false;
      for (var index = 0; index < 4; index++) {
        if (index > 0) await nextChunks[index - 1].future;
        response.add(media.skip(index * 512).take(512).toList());
        await response.flush();
      }
    };

    Future<DownloadTask> progressAt(int bytes) => repository.changes
        .firstWhere(
          (state) => state.tasks.any(
            (task) =>
                task.status == DownloadStatus.downloading &&
                task.downloadedBytes == bytes,
          ),
        )
        .then((state) => state.tasks.single)
        .timeout(const Duration(seconds: 5));

    final firstChunk = progressAt(512);
    await repository.enqueue([item], const DownloadSelection());
    expect((await firstChunk).bytesPerSecond, 0);

    now = now.add(const Duration(milliseconds: 250));
    final secondChunk = progressAt(1024);
    nextChunks[0].complete();
    expect((await secondChunk).bytesPerSecond, 0);

    now = now.add(const Duration(milliseconds: 250));
    final thirdChunk = progressAt(1536);
    nextChunks[1].complete();
    expect((await thirdChunk).bytesPerSecond, 2048);

    nextChunks[2].complete();
    await _waitFor(repository, DownloadStatus.completed);
    expect(repository.current.tasks.single.bytesPerSecond, 0);
    expect(repository.current.tasks.single.downloadedBytes, media.length * 2);
  });

  test(
    'background database failure becomes a visible recoverable error',
    () async {
      streamSlow = true;
      await repository.enqueue([item], const DownloadSelection());
      await _waitFor(repository, DownloadStatus.downloading);
      await db.close();
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (repository.current.failure == null &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(repository.current.failure?.kind, AppFailureKind.storage);
      expect(repository.current.tasks.single.status, DownloadStatus.failed);
    },
  );

  test('capacity rejection leaves a 490-item queue unchanged', () async {
    slow = true;
    await repository.enqueue([item], const DownloadSelection());
    await _waitFor(repository, DownloadStatus.downloading);
    await repository.pause(repository.current.tasks.single.id);
    final row = await db
        .customSelect('SELECT record_json FROM download_tasks')
        .getSingle();
    final template =
        jsonDecode(row.read<String>('record_json')) as Map<String, dynamic>;
    await repository.close();
    await db.transaction(() async {
      for (var cid = 2; cid <= 490; cid++) {
        final id = cid.toRadixString(16).padLeft(32, '0');
        final record = jsonDecode(jsonEncode(template)) as Map<String, dynamic>;
        record['id'] = id;
        record['directory'] = '${root.path}/fixture/$id';
        record['status'] = 'paused';
        record['tracks'] = [];
        (record['part'] as Map<String, dynamic>)['cid'] = '$cid';
        await db.customStatement(
          'INSERT INTO download_tasks(id,scope,item_key,record_json) VALUES (?,?,?,?)',
          [id, 'guest', 'video:BV1234567890:$cid', jsonEncode(record)],
        );
      }
    });
    await db.close();
    await openRepository();
    expect(repository.current.tasks.length, 490);
    final extra = List.generate(
      20,
      (index) => DownloadItem(
        video: item.video,
        part: VideoPart(
          cid: '${501 + index}',
          page: index + 1,
          title: 'Extra',
          duration: const Duration(seconds: 3),
        ),
      ),
    );
    await expectLater(
      repository.enqueue(extra, const DownloadSelection()),
      throwsA(
        isA<AppFailure>().having((e) => e.kind, 'kind', AppFailureKind.storage),
      ),
    );
    expect(repository.current.tasks.length, 490);
    expect(
      (await db
              .customSelect('SELECT COUNT(*) AS n FROM download_tasks')
              .getSingle())
          .read<int>('n'),
      490,
    );
  });

  test(
    'two simultaneous windows enqueue one task for the same content',
    () async {
      await Future.wait([
        repository.enqueue([item], const DownloadSelection()),
        repository.enqueue([item], const DownloadSelection()),
      ]);
      expect(repository.current.tasks.length, 1);
      expect(
        (await db
                .customSelect('SELECT COUNT(*) AS n FROM download_tasks')
                .getSingle())
            .read<int>('n'),
        1,
      );
    },
  );

  Future<_Muxer> useMuxer() async {
    await repository.close();
    await db.close();
    final value = _Muxer();
    muxer = value;
    await openRepository();
    return value;
  }

  for (final output in [DownloadOutput.mp4, DownloadOutput.mkv]) {
    group(output.name, () {
      final mergedSelection = DownloadSelection(output: output);

      test('public merge retries without remux', () async {
        final native = await useMuxer();
        await repository.close();
        await db.close();
        publicStorage = _PublicStorage()..failPublish = true;
        await openRepository();
        await repository.enqueue([item], mergedSelection);
        await _waitFor(repository, DownloadStatus.failed);
        final task = repository.current.tasks.single;
        expect(task.publicFiles, isEmpty);
        final mergedFile = File('${task.directory}/${output.fileName}');
        expect(await mergedFile.exists(), isTrue);
        publicStorage!.failPublish = false;
        await repository.resume(task.id);
        await _waitFor(repository, DownloadStatus.completed);
        await repository.close();
        expect(native.calls, 1);
        expect(repository.current.tasks.single.publicFiles.keys, [
          output.fileName,
          'manifest.json',
          'extras.json',
        ]);
        for (final name in ['video.m4s', 'audio.m4s', output.fileName]) {
          expect(await File('${task.directory}/$name').exists(), isFalse);
        }
        await db.close();
        await openRepository();
        expect(
          (await repository.offlineTask(task.id)).status,
          DownloadStatus.completed,
        );
      });

      test(
        'merged completion commits output and reopens after removing sources',
        () async {
          final native = await useMuxer();
          expect(repository.current.canMerge, isTrue);
          await repository.enqueue([item], mergedSelection);
          await _waitFor(repository, DownloadStatus.completed);
          await repository.close(); // Also wait for post-commit cleanup.
          final task = repository.current.tasks.single;
          expect(native.calls, 1);
          expect(native.outputs, [output]);
          expect(task.mergedMedia?.bytes, media.length * 2);
          expect(
            await File('${task.directory}/${output.fileName}').exists(),
            isTrue,
          );
          expect(await File('${task.directory}/video.m4s').exists(), isFalse);
          expect(await File('${task.directory}/audio.m4s').exists(), isFalse);
          await db.close();
          await openRepository();
          expect(
            (await repository.offlineTask(task.id)).mergedMedia?.sha256,
            task.mergedMedia?.sha256,
          );
          expect(repository.current.tasks.single.selection.output, output);
          await File('${task.directory}/${output.fileName}')
              .writeAsBytes(List.filled(media.length * 2, 0));
          expect(
            (await repository.offlineTask(task.id)).status,
            DownloadStatus.completed,
          );
        },
      );

      test('merge failure preserves originals and retry needs no new source request', () async {
        final native = (await useMuxer())..failNext = true;
        await repository.enqueue([item], mergedSelection);
        final failure = await repository.changes.firstWhere(
          (state) =>
              state.tasks.any((task) => task.status == DownloadStatus.failed),
        );
        final task = failure.tasks.single;
        expect(
          await File('${task.directory}/video.m4s').length(),
          media.length,
        );
        expect(
          await File('${task.directory}/audio.m4s').length(),
          media.length,
        );
        expect(
          await File('${task.directory}/${output.fileName}.part').exists(),
          isFalse,
        );
        final resolves = sources.resolveCalls;
        await repository.resume(task.id);
        await _waitFor(repository, DownloadStatus.completed);
        expect(native.calls, 2);
        expect(sources.resolveCalls, resolves);
        expect(videoRequests, 1);
      });

      test(
        'pause during merge waits for cancellation and removes partial output',
        () async {
          final native = (await useMuxer())..block = true;
          await repository.enqueue([item], mergedSelection);
          await native.started.future;
          final id = repository.current.tasks.single.id;
          await repository.pause(id);
          final task = repository.current.tasks.single;
          expect(task.status, DownloadStatus.paused);
          expect(task.failure, isNull);
          expect(
            await File('${task.directory}/${output.fileName}.part').exists(),
            isFalse,
          );
          expect(await File('${task.directory}/video.m4s').exists(), isTrue);
          native.block = false;
          await repository.resume(id);
          await _waitFor(repository, DownloadStatus.completed);
        },
      );

      test(
        'switching accounts during merge cannot commit into the new scope',
        () async {
          final native = (await useMuxer())..block = true;
          await repository.enqueue([item], mergedSelection);
          await native.started.future;
          final task = repository.current.tasks.single;
          sources.scope = 'user:2';
          sources.epoch++;
          await repository.sessionChanged();
          expect(repository.current.tasks, isEmpty);
          expect(
            await File('${task.directory}/${output.fileName}').exists(),
            isFalse,
          );
          expect(
            await File('${task.directory}/${output.fileName}.part').exists(),
            isFalse,
          );
          sources.scope = 'guest';
          sources.epoch++;
          await repository.sessionChanged();
          expect(repository.current.tasks.single.status, DownloadStatus.paused);
        },
      );

      test(
        'manifest-before-SQLite interruption recovers completed merged output',
        () async {
          await useMuxer();
          await repository.enqueue([item], mergedSelection);
          await _waitFor(repository, DownloadStatus.completed);
          await repository.close();
          final task = repository.current.tasks.single;
          final row = await db
              .customSelect('SELECT record_json FROM download_tasks')
              .getSingle();
          final record = jsonDecode(
            row.read<String>('record_json'),
          ) as Map<String, Object?>;
          record['status'] = 'muxing';
          await db.customStatement(
            'UPDATE download_tasks SET record_json = ?',
            [jsonEncode(record)],
          );
          await db.close();
          await openRepository();
          expect(
            (await repository.offlineTask(task.id)).status,
            DownloadStatus.completed,
          );
        },
      );

      test(
        'committed output recovers without the legacy integrity manifest',
        () async {
          final native = await useMuxer();
          await repository.enqueue([item], mergedSelection);
          await _waitFor(repository, DownloadStatus.completed);
          await repository.close();
          final task = repository.current.tasks.single;
          await File('${task.directory}/manifest.json').delete();
          final row = await db
              .customSelect('SELECT record_json FROM download_tasks')
              .getSingle();
          final record = jsonDecode(
            row.read<String>('record_json'),
          ) as Map<String, Object?>;
          record['status'] = 'muxing';
          await db.customStatement(
            'UPDATE download_tasks SET record_json = ?',
            [jsonEncode(record)],
          );
          await db.close();
          await openRepository();
          expect(
            repository.current.tasks.single.status,
            DownloadStatus.completed,
          );
          final resolves = sources.resolveCalls;
          await repository.resume(task.id);
          await _waitFor(repository, DownloadStatus.completed);
          expect(native.calls, 1);
          expect(sources.resolveCalls, resolves);
        },
      );

      test('legacy v1 record keeps separate output and unavailable mux refuses MP4', () async {
        await expectLater(
          repository.enqueue([item], mergedSelection),
          throwsA(isA<AppFailure>()),
        );
        expect(repository.current.tasks, isEmpty);
        await repository.enqueue([item], const DownloadSelection());
        await _waitFor(repository, DownloadStatus.completed);
        await repository.close();
        final row = await db
            .customSelect('SELECT record_json FROM download_tasks')
            .getSingle();
        final record =
            jsonDecode(row.read<String>('record_json')) as Map<String, Object?>;
        record['version'] = 1;
        (record['selection'] as Map<String, Object?>).remove('output');
        await db.customStatement('UPDATE download_tasks SET record_json = ?', [
          jsonEncode(record),
        ]);
        await db.close();
        await openRepository();
        final task = repository.current.tasks.single;
        expect(task.selection.output, DownloadOutput.separate);
        expect(
          (await repository.offlineTask(task.id)).status,
          DownloadStatus.completed,
        );
      });

      test(
        'startup accepts modified merged output without original tracks',
        () async {
          await useMuxer();
          await repository.enqueue([item], mergedSelection);
          await _waitFor(repository, DownloadStatus.completed);
          await repository.close();
          final task = repository.current.tasks.single;
          await File('${task.directory}/video.m4s').writeAsBytes(media);
          await File('${task.directory}/audio.m4s').writeAsBytes(media);
          await File('${task.directory}/${output.fileName}')
              .writeAsBytes(List.filled(media.length * 2, 0));
          await db.close();
          await openRepository();
          expect(
            (await repository.offlineTask(task.id)).status,
            DownloadStatus.completed,
          );
          expect(await File('${task.directory}/video.m4s').exists(), isFalse);
          expect(await File('${task.directory}/audio.m4s').exists(), isFalse);
        },
      );

      test(
        'separate and merged versions have distinct queue identities',
        () async {
          final native = (await useMuxer())..block = true;
          await repository.enqueue([item], mergedSelection);
          await native.started.future;
          await repository.enqueue([item], const DownloadSelection());
          expect(repository.current.tasks.length, 2);
          await repository.pauseAll();
        },
      );
    });
  }
}

final class _Muxer implements DownloadMuxer {
  bool failNext = false, block = false;
  int calls = 0;
  final outputs = <DownloadOutput>[];
  final started = Completer<void>();
  @override
  bool get available => true;
  @override
  Future<void> merge({
    required String videoPath,
    required String audioPath,
    required String outputPath,
    required DownloadOutput output,
    required RequestCancellation cancellation,
    required void Function(double) onProgress,
  }) async {
    calls++;
    outputs.add(output);
    await File(outputPath).writeAsBytes([1]);
    if (!started.isCompleted) started.complete();
    if (block) {
      final cancelled = Completer<void>();
      cancellation.onCancel(() {
        if (!cancelled.isCompleted) cancelled.complete();
      });
      await cancelled.future;
      throw const AppFailure(AppFailureKind.cancelled, 'cancelled');
    }
    if (failNext) {
      failNext = false;
      throw const AppFailure(AppFailureKind.storage, 'merge failed');
    }
    onProgress(0.5);
    await File(outputPath).writeAsBytes([
      ...await File(videoPath).readAsBytes(),
      ...await File(audioPath).readAsBytes(),
    ]);
    onProgress(1);
  }
}

Future<void> _waitFor(
  SqliteDownloadRepository repository,
  DownloadStatus status,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (DateTime.now().isBefore(deadline)) {
    if (repository.current.tasks.any((task) => task.status == status)) return;
    if (repository.current.tasks.any(
      (task) => task.status == DownloadStatus.failed,
    )) {
      fail('Download failed: ${repository.current.tasks.single.failure}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail(
    'Timed out waiting for $status: ${repository.current.tasks.map((t) => t.status)}',
  );
}

const _scannedId = '7d0f1a2b3c4d5e6f708192a3b4c5d6e7';

/// A v3 manifest for a merged part, matching the file listing the scan tests
/// hand back from the fake public storage.
String _publishedManifest() => jsonEncode({
  'version': 3,
  'id': _scannedId,
  'itemKey': 'video:BV1234567890:1',
  'createdAtMs': 1730000000000,
  'video': {
    'id': 'BV1234567890',
    'title': '扫描到的视频',
    'author': '扫描UP',
    'durationMs': 60000,
  },
  'part': {'cid': '1', 'page': 1, 'title': 'P1', 'durationMs': 60000},
  'aid': '99',
  'quality': 80,
  'codec': 'h264',
  'output': 'mp4',
  'merged': {'fileName': 'media.mp4', 'bytes': 2048, 'sha256': null},
  'tracks': [
    {
      'kind': 'video',
      'identity': 'v1',
      'fileName': 'video.m4s',
      'codec': 'avc1',
      'bandwidth': 1000,
      'bytes': 1200,
      'sha256': null,
    },
    {
      'kind': 'audio',
      'identity': 'a1',
      'fileName': 'audio.m4s',
      'codec': 'mp4a',
      'bandwidth': 128,
      'bytes': 848,
      'sha256': null,
    },
  ],
});

final item = DownloadItem(
  video: const VideoSummary(
    id: VideoId('BV1234567890'),
    title: 'Fixture',
    coverUrl: '',
    author: 'Author',
    duration: Duration(seconds: 3),
  ),
  part: const VideoPart(
    cid: '1',
    page: 1,
    title: 'P1',
    duration: Duration(seconds: 3),
  ),
);

final class _Sources implements DownloadSourceRepository {
  _Sources(this.base);
  final Uri base;
  String scope = 'guest';
  int epoch = 0;
  int resolveCalls = 0;
  bool changeIdentityOnRefresh = false;
  @override
  String get accountScope => scope;
  @override
  int get sessionEpoch => epoch;
  @override
  Future<List<int>> qualities(
    DownloadItem item, {
    required RequestCancellation cancellation,
  }) async => [80];
  @override
  Future<DownloadResolvedSource> resolve(
    DownloadItem item,
    DownloadSelection selection, {
    required RequestCancellation cancellation,
  }) async {
    resolveCalls++;
    final revision = changeIdentityOnRefresh && resolveCalls > 1 ? 2 : 1;
    return DownloadResolvedSource(
      video: DownloadTrackSource(
        identity: 'video:$revision',
        kind: DownloadTrackKind.video,
        urls: [base.resolve('/video$revision')],
        codec: 'avc1',
        bandwidth: 1000,
      ),
      audio: DownloadTrackSource(
        identity: 'audio:$revision',
        kind: DownloadTrackKind.audio,
        urls: [base.resolve(revision == 1 ? '/audio' : '/audio2')],
        codec: 'mp4a',
        bandwidth: 128,
      ),
      quality: 80,
      duration: const Duration(seconds: 3),
      headers: const {},
    );
  }

  @override
  Future<DownloadExtras> extras(
    DownloadItem item,
    DownloadSelection selection, {
    required RequestCancellation cancellation,
  }) async => DownloadExtras();
}

final class _PublicStorage implements PublicDownloadStorage {
  bool available = true, deleted = false, failPublish = false;
  String selected = 'downloads';
  final destinations = <String?>[];
  final Map<String, Map<String, String>> published = {};
  @override
  Future<bool> hasDestination() async => true;
  @override
  Future<bool> requestDirectoryAccess() async => true;
  @override
  Future<DownloadFolderListing> listDirectories(String? directory) async =>
      DownloadFolderListing(folders: const []);
  @override
  Future<void> chooseDestination(String directory) async {}
  @override
  Future<String> destination() async => selected;
  final capturedFolders = <String>[];

  @override
  Future<Map<String, String>> publish(
    DownloadTask task,
    Map<String, String> files, {
    required String folder,
    required RequestCancellation cancellation,
  }) async {
    capturedFolders.add(folder);
    destinations.add(task.publicDestination);
    if (failPublish) throw const AppFailure(AppFailureKind.storage, '空间不足');
    for (final source in files.values) {
      expect(await File(source).exists(), isTrue);
    }
    return published.putIfAbsent(
      task.id,
      () => {
        for (final name in files.keys) name: 'content://test/${task.id}/$name',
      },
    );
  }

  @override
  Future<void> verify(DownloadTask task) async {
    if (!available) throw const AppFailure(AppFailureKind.permission, '授权已撤销');
    expect(task.publicFiles, published[task.id]);
  }

  /// Folders the fake reports for the scan.
  List<PublishedFolder> folders = const [];
  final Map<String, String> texts = {};
  final List<String> readRequests = [];

  /// Folders the fake accepted through adopt, so a test can prove the scan
  /// claims what it imported.
  final List<(String, Map<String, String>)> adopted = [];

  /// What the fake reports as the last native step; the scan traces it, so a
  /// test can prove the marker reaches the durable log.
  String? nativeStep;

  @override
  Future<String?> lastNativeStep() async => nativeStep;

  @override
  Future<void> adoptPublishedFolder({
    required DownloadTask task,
    required String folder,
    required Map<String, String> files,
  }) async {
    if (refuseAdopt) {
      throw const AppFailure(AppFailureKind.storage, '公共文件已不可访问');
    }
    // The real channel writes the journal here, so `verify` must see the same
    // URI set afterwards - otherwise the fake diverges from the platform.
    published[task.id] = Map.of(files);
    adopted.add((task.id, files));
  }

  bool refuseAdopt = false;
  bool failList = false;

  /// When set, the listing waits on it - the shape of a call that never returns.
  /// [listReached] says the pass really got there, so a test does not have to
  /// guess how many microtasks a scan needs.
  Completer<void>? listGate;
  bool listReached = false;

  @override
  Future<List<PublishedFolder>> listPublishedFolders() async {
    if (failList) {
      // Stands in for the container killing the process mid-call.
      throw StateError('listFolders never returned');
    }
    listReached = true;
    await listGate?.future;
    return folders;
  }

  @override
  Future<void> copyPublishedSidecar({
    required String folder,
    required String uri,
    required String targetPath,
  }) async {
    final value = texts[uri];
    if (value == null) {
      throw const AppFailure(AppFailureKind.storage, '附属文件已不可读');
    }
    await File(targetPath).writeAsString(value);
  }

  @override
  Future<String> readPublishedText({
    required String folder,
    required String uri,
    int maxBytes = 262144,
  }) async {
    readRequests.add('$folder|$uri');
    final value = texts[uri];
    if (value == null) {
      throw const AppFailure(AppFailureKind.storage, '无法读取下载清单');
    }
    return value;
  }

  @override
  Future<void> delete(DownloadTask task) async {
    await verify(task);
    // Mirrors the native journal removal: a later adopt must not be compared
    // against the URIs of a deleted generation.
    published.remove(task.id);
    deleted = true;
  }
}
