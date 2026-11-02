import 'dart:io';

import 'package:drift/drift.dart';

import '../storage/app_database.dart';

/// One recorded event, newest last when a page is rendered.
final class DiagnosticsEntry {
  const DiagnosticsEntry({
    required this.runId,
    required this.at,
    required this.message,
  });

  final String runId;
  final DateTime at;
  final String message;
}

/// A durable event trace for devices that give the app no log channel.
///
/// On the HarmonyOS Android-compatibility container a defect shows up only as
/// the app closing: there is no adb, no logcat, and everything kept in memory
/// or in `debugPrint` dies with the process. Rows live in SQLite, so the last
/// events of the crashed process are still readable after it restarts, and the
/// viewer in 设置 → 关于 is the only way to see them.
///
/// Never throws. A diagnostic that can break the thing it observes is worse
/// than no diagnostic, so a failing insert is dropped silently.
final class DiagnosticsLog {
  DiagnosticsLog(this._database, {String? runId, DateTime Function()? clock})
    : runId =
          runId ?? '$pid-${DateTime.now().millisecondsSinceEpoch}',
      _clock = clock ?? DateTime.now;

  /// Rows kept after a start-up trim. The trace is a sliding window, not a log
  /// archive; unbounded growth would cost storage on a phone.
  static const retentionRows = 3000;

  static DiagnosticsLog? _instance;

  /// Null until [install] runs, which keeps every call site a no-op in tests
  /// and in code paths that reach the database before `main` finished.
  static DiagnosticsLog? get instance => _instance;

  static final List<String> _early = [];

  /// Clears the process-wide recorder. Tests use it so a queued early event
  /// cannot leak into the next case.
  static void reset() {
    _instance = null;
    _early.clear();
  }

  static Future<void> install(DiagnosticsLog log) async {
    _instance = log;
    final pending = List<String>.of(_early);
    _early.clear();
    for (final message in pending) {
      await log.note(message);
    }
  }

  /// Records a message before the database exists, such as a framework error
  /// thrown while startup is still wiring dependencies.
  static void recordEarly(String message) {
    final log = _instance;
    if (log == null) {
      if (_early.length < 64) _early.add(message);
      return;
    }
    log.note(message);
  }

  final AppDatabase _database;
  final DateTime Function() _clock;
  final String runId;

  /// Drops events older than the retention window. Called once at start-up so
  /// the insert path stays a single statement.
  Future<void> trim() => _run(
    'DELETE FROM diagnostics_events WHERE id < '
    '(SELECT MAX(id) - ? FROM diagnostics_events)',
    [retentionRows],
  );

  Future<void> note(String message) => _insert(message);

  /// The error text is safe to show: URLs lose their query, and anything that
  /// looks like a credential or a long opaque token is collapsed. Network
  /// failures reach here with the failing request in hand, and this table is
  /// readable long after the app was shared as a screenshot.
  static String describeError(Object error, StackTrace? stack) {
    final buffer = StringBuffer('${error.runtimeType}: ${scrub('$error')}');
    if (stack != null) {
      final frames = stack
          .toString()
          .split('\n')
          .where((line) => line.trim().startsWith('#'))
          .take(6)
          .map(scrub)
          .join(' | ');
      if (frames.isNotEmpty) buffer.write(' @$frames');
    }
    return buffer.toString();
  }

  static final _urlQuery = RegExp(
    r'(https?://[^\s?]+)\?[^\s]*',
    caseSensitive: false,
  );
  static final _credential = RegExp(
    r'(access_key|session_id|sessdata|bili_jct|dedeuserid|refresh_token|token|cookie|qid|qr[ _-]?code|bufpvid)[=:][^\s,;)}]*',
    caseSensitive: false,
  );
  static final _opaque = RegExp(r'[A-Za-z0-9+/=_\-]{24,}');

  /// Scrubs a free-text fragment before it can be shown or stored.
  static String scrub(String value) {
    var text = value.replaceAllMapped(
      _urlQuery,
      (match) => '${match.group(1)}?…',
    );
    text = text.replaceAll(_credential, '');
    text = text.replaceAll(_opaque, '…');
    if (text.length > 400) text = '${text.substring(0, 400)}…';
    return text;
  }

  /// Oldest first, so a page reads top-down like a log.
  Future<List<DiagnosticsEntry>> recent({int limit = 500}) async {
    try {
      final rows = await _database
          .customSelect(
            'SELECT run_id, at_ms, message FROM diagnostics_events '
            'ORDER BY id DESC LIMIT ?',
            variables: [Variable<int>(limit)],
          )
          .get();
      return rows.reversed
          .map(
            (row) => DiagnosticsEntry(
              runId: row.read<String>('run_id'),
              at: DateTime.fromMillisecondsSinceEpoch(row.read<int>('at_ms')),
              message: row.read<String>('message'),
            ),
          )
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> clear() => _run('DELETE FROM diagnostics_events', const []);

  Future<void> _insert(String message) => _run(
    'INSERT INTO diagnostics_events(run_id,at_ms,message) VALUES (?,?,?)',
    [runId, _clock().millisecondsSinceEpoch, scrub(message)],
  );

  Future<void> _run(String sql, List<Object?> variables) async {
    try {
      await _database.customStatement(sql, variables);
    } catch (_) {
      // A device whose storage is broken must keep working without a trace.
    }
  }

  /// Text as the viewer shows it: one line per event, a blank line between
  /// processes so the boundary of a crash is visible.
  static String render(List<DiagnosticsEntry> entries) {
    final buffer = StringBuffer();
    String? run;
    for (final entry in entries) {
      if (entry.runId != run) {
        if (buffer.isNotEmpty) buffer.write('\n');
        run = entry.runId;
      }
      buffer.writeln(
        '${entry.at.toString().substring(2, 14)}  ${entry.message}',
      );
    }
    return buffer.toString();
  }
}
