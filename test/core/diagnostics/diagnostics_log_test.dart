import 'package:bilisail/core/diagnostics/diagnostics_log.dart';
import 'package:bilisail/core/storage/app_database.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(DiagnosticsLog.reset);

  test('events keep their order and read back with their process', () async {
    final database = _database();
    final log = DiagnosticsLog(database, runId: 'r1');
    await log.note('原生 listFolders →');
    await log.note('原生 listFolders ←');
    final entries = await log.recent();
    expect(entries.map((entry) => entry.message), [
      '原生 listFolders →',
      '原生 listFolders ←',
    ]);
    expect(entries.map((entry) => entry.runId), ['r1', 'r1']);

    await log.clear();
    expect(await log.recent(), isEmpty);
  });

  test('a limit keeps the newest tail, not the oldest head', () async {
    final log = DiagnosticsLog(_database());
    for (var index = 0; index < 5; index++) {
      await log.note('事件 $index');
    }
    expect((await log.recent(limit: 2)).map((entry) => entry.message), [
      '事件 3',
      '事件 4',
    ]);
  });

  test(
    'events recorded before the database exists are flushed on install',
    () async {
      DiagnosticsLog.recordEarly('框架错误 尚未安装');
      final log = DiagnosticsLog(_database(), runId: 'r2');
      await DiagnosticsLog.install(log);
      expect((await log.recent()).map((entry) => entry.message), ['框架错误 尚未安装']);
      expect(log.runId, isNotEmpty);
    },
  );

  test(
    'the crash boundary is the newest event of the earlier process',
    () async {
      final database = _database();
      final first = DiagnosticsLog(database, runId: 'old');
      await first.note('旧进程 第一条');
      await first.note('原生 copyPublished →');
      final current = DiagnosticsLog(database, runId: 'new');
      await current.note('进程启动');
      final entries = await current.recent();
      expect(
        DiagnosticsLog.previousProcessTail(entries, 'new'),
        '原生 copyPublished →',
      );
      // A run with no older process has no crash boundary to name.
      expect(
        DiagnosticsLog.previousProcessTail(
          [
            DiagnosticsEntry(
              runId: 'only',
              at: DateTime(2026),
              message: '进程启动',
            ),
          ],
          'only',
        ),
        isNull,
      );
    },
  );

  test('scrubbing removes queries, credential shapes and opaque tokens', () {
    expect(
      DiagnosticsLog.scrub(
        'GET https://api.bilibili.com/x/player?access_key=SECRET&cid=17 失败',
      ),
      'GET https://api.bilibili.com/x/player?… 失败',
    );
    final cookie = DiagnosticsLog.scrub(
      'Cookie: bili_jct=SECRETJCT; SESSDATA=SECRETSESS',
    );
    expect(cookie, isNot(contains('SECRETJCT')));
    expect(cookie, isNot(contains('SECRETSESS')));
    expect(
      DiagnosticsLog.scrub('lease Zm9vYmFyYmF6cXV1eGNvcmdsZWV6anVua2xl'),
      'lease …',
    );
    expect(
      DiagnosticsLog.scrub('下载 media.mkv 缺失或大小与清单不符'),
      '下载 media.mkv 缺失或大小与清单不符',
    );
  });

  test('an error is described by type without its secrets', () {
    final described = DiagnosticsLog.describeError(
      StateError('https://host/path?token=SECRET'),
      StackTrace.fromString('#0  main (file:///a.dart:1:1)'),
    );
    expect(described, startsWith('StateError:'));
    expect(described, contains('https://host/path?…'));
    expect(described, isNot(contains('SECRET')));
    expect(described, contains('#0'));
  });
}

AppDatabase _database() {
  final database = AppDatabase(NativeDatabase.memory());
  addTearDown(database.close);
  return database;
}
