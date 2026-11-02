import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Small, explicit SQL schema. No credentials or signed media URLs belong here.
class AppDatabase extends GeneratedDatabase {
  AppDatabase(super.executor);

  static Future<AppDatabase> open() async {
    final directory = await getApplicationSupportDirectory();
    await directory.create(recursive: true);
    return AppDatabase(
      NativeDatabase.createInBackground(
        File(p.join(directory.path, 'bilisail.sqlite')),
      ),
    );
  }

  @override
  int get schemaVersion => 6;

  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];

  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => const [];

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (migrator) async {
      await customStatement('''CREATE TABLE settings (
        key TEXT NOT NULL PRIMARY KEY,
        value TEXT NOT NULL
      )''');
      await customStatement('''CREATE TABLE playback_progress (
        scope TEXT NOT NULL,
        bvid TEXT NOT NULL,
        cid TEXT NOT NULL,
        title TEXT NOT NULL,
        cover_url TEXT NOT NULL,
        author TEXT NOT NULL,
        duration_ms INTEGER NOT NULL,
        part_title TEXT NOT NULL,
        part_number INTEGER NOT NULL,
        position_ms INTEGER NOT NULL,
        updated_at_ms INTEGER NOT NULL,
        pgc_episode_id TEXT,
        PRIMARY KEY (scope, bvid, cid)
      )''');
      await customStatement(
        'CREATE INDEX progress_scope_time ON playback_progress(scope, updated_at_ms DESC)',
      );
      await _createDownloads();
      await _createScanCache();
    },
    onUpgrade: (migrator, from, to) async {
      if (to != schemaVersion) {
        throw StateError('Unsupported database migration $from → $to');
      }
      // Steps chain: a v1 database still has to gain the PGC column, the
      // download tables and the scan cache in that order.
      if (from == 1) {
        await customStatement(
          'ALTER TABLE playback_progress ADD COLUMN pgc_episode_id TEXT',
        );
      }
      if (from <= 2) {
        await _createDownloads();
      }
      if (from <= 3) {
        await _createScanCache();
      }
      if (from == 5) {
        // v5 carried a diagnostics event trace for one crash hunt; nothing
        // writes it any more, so an upgrade only has to drop it.
        await customStatement('DROP TABLE IF EXISTS diagnostics_events');
      }
    },
  );

  Future<void> _createDownloads() async {
    await customStatement('''CREATE TABLE download_tasks (
      id TEXT NOT NULL PRIMARY KEY,
      scope TEXT NOT NULL,
      item_key TEXT NOT NULL,
      record_json TEXT NOT NULL
    )''');
    await customStatement(
      'CREATE INDEX download_tasks_scope ON download_tasks(scope)',
    );
  }

  /// Folders the offline scan has already looked at.
  ///
  /// `manifest_bytes` and `manifest_modified_ms` together are the cheap change
  /// detector: when both match the previous visit and the task row is still
  /// there, the scan skips reading that manifest at all. That is what keeps
  /// opening the downloads tab fast once the shared folder holds many parts.
  Future<void> _createScanCache() async {
    await customStatement('''CREATE TABLE download_scan_cache (
      folder_key TEXT NOT NULL PRIMARY KEY,
      task_id TEXT NOT NULL,
      manifest_bytes INTEGER NOT NULL,
      manifest_modified_ms INTEGER NOT NULL,
      scanned_at_ms INTEGER NOT NULL
    )''');
    await customStatement(
      'CREATE INDEX download_scan_cache_task ON download_scan_cache(task_id)',
    );
  }

  Future<String?> readSetting(String key) async {
    final row = await customSelect(
      'SELECT value FROM settings WHERE key = ?',
      variables: [Variable<String>(key)],
    ).getSingleOrNull();
    return row?.read<String>('value');
  }

  Future<void> writeSetting(String key, String value) => customStatement(
    'INSERT INTO settings(key,value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value',
    [key, value],
  );

  Future<void> clearPrivateHistory(String scope) async {
    await customStatement('DELETE FROM playback_progress WHERE scope = ?', [
      scope,
    ]);
    await customStatement('DELETE FROM settings WHERE key = ?', [
      'search_history.v1.$scope',
    ]);
  }
}
