import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../../domain/app_failure.dart';
import '../../../domain/request_cancellation.dart';
import '../domain/app_update.dart';

typedef ReleaseFetcher = Future<String> Function(
  RequestCancellation cancellation,
);

final class GitHubUpdateRepository implements AppUpdateRepository {
  GitHubUpdateRepository({
    required this.versionLoader,
    this.fetcher,
    this.timeout = const Duration(seconds: 12),
  });

  final Future<AppVersion> Function() versionLoader;
  final ReleaseFetcher? fetcher;
  final Duration timeout;
  final Set<HttpClient> _clients = {};
  bool _closed = false;
  static const maxResponseBytes = 2 * 1024 * 1024;

  /// The exact request the transport performs, reused for the shown record so
  /// the two can never drift apart.
  static final endpoint = Uri.https(
    'api.github.com',
    '/repos/CKopoer/BiliSail/releases',
    {'per_page': '100'},
  );

  /// Public metadata only: no account cookie, token or CSRF value is attached.
  static const requestHeaders = {
    'user-agent': 'BiliSail-update-check',
    'accept': 'application/vnd.github+json',
    'x-github-api-version': '2026-03-10',
  };

  @override
  Future<AppVersion> installedVersion() => versionLoader();

  @override
  Future<AppRelease?> latestRelease(
    RequestCancellation cancellation, {
    bool includePrereleases = false,
  }) async {
    _checkCancellation(cancellation);
    final response = fetcher == null
        ? await _fetch(cancellation)
        : _RawUpdateResponse(body: await fetcher!.call(cancellation));
    _checkCancellation(cancellation);
    final release = _parse(
      response.body,
      includePrereleases: includePrereleases,
    );
    final found = release.release;
    if (found == null) return null;
    return AppRelease(
      version: found.version,
      url: found.url,
      notes: found.notes,
      prerelease: found.prerelease,
      publishedAt: found.publishedAt,
      assets: found.assets,
      report: UpdateCheckReport(
        endpoint: endpoint,
        requestHeaders: requestHeaders,
        prereleaseChannelIncluded: includePrereleases,
        statusCode: response.statusCode,
        responseBytes: response.bytes,
        elapsed: response.elapsed,
        candidates: release.candidates,
        skippedDrafts: release.skippedDrafts,
        skippedPrereleases: release.skippedPrereleases,
        skippedUnversionedTags: release.skippedUnversionedTags,
      ),
    );
  }

  void _checkCancellation(RequestCancellation cancellation) {
    if (_closed || cancellation.isCancelled) {
      throw const AppFailure(AppFailureKind.cancelled, '更新检查已取消');
    }
  }

  Future<_RawUpdateResponse> _fetch(RequestCancellation cancellation) async {
    // Dedicated public transport: no Bilibili Cookie, token, redirects or retry.
    final client = HttpClient()..connectionTimeout = timeout;
    _clients.add(client);
    cancellation.onCancel(() => client.close(force: true));
    final watch = Stopwatch()..start();
    try {
      return await (() async {
        final request = await client.getUrl(endpoint);
        _checkCancellation(cancellation);
        request.followRedirects = false;
        for (final entry in requestHeaders.entries) {
          request.headers.set(entry.key, entry.value);
        }
        final response = await request.close();
        if (response.statusCode == 403 || response.statusCode == 429) {
          throw const AppFailure(
            AppFailureKind.rateLimited,
            'GitHub 请求受限，请稍后重试',
          );
        }
        if (response.statusCode != 200) {
          throw const AppFailure(AppFailureKind.network, '无法获取 GitHub 更新信息');
        }
        if (response.contentLength > maxResponseBytes) {
          throw const AppFailure(AppFailureKind.protocol, '更新信息超过容量限制');
        }
        final bytes = <int>[];
        await for (final chunk in response) {
          _checkCancellation(cancellation);
          if (bytes.length + chunk.length > maxResponseBytes) {
            throw const AppFailure(AppFailureKind.protocol, '更新信息超过容量限制');
          }
          bytes.addAll(chunk);
        }
        // The capacity guards above see the compressed length; the reported
        // figure is the decoded body the user is actually shown.
        return _RawUpdateResponse(
          body: utf8.decode(bytes),
          statusCode: response.statusCode,
          bytes: bytes.length,
          elapsed: watch.elapsed,
        );
      })().timeout(timeout);
    } on AppFailure {
      rethrow;
    } on TimeoutException {
      _checkCancellation(cancellation);
      throw const AppFailure(AppFailureKind.timeout, '检查更新超时，请稍后重试');
    } on FormatException {
      throw const AppFailure(AppFailureKind.protocol, '更新信息格式异常');
    } on IOException {
      _checkCancellation(cancellation);
      throw const AppFailure(AppFailureKind.network, '检查更新失败，请检查网络连接');
    } finally {
      client.close(force: true);
      _clients.remove(client);
    }
  }

  static AppRelease? parseReleases(
    String body, {
    bool includePrereleases = false,
  }) => _parse(body, includePrereleases: includePrereleases).release;

  /// Parses the candidate list and counts why each row was rejected, so the
  /// prompt can show the whole decision instead of only its conclusion.
  static _ParsedReleases _parse(
    String body, {
    required bool includePrereleases,
  }) {
    try {
      if (utf8.encode(body).length > maxResponseBytes) {
        throw const FormatException();
      }
      final Object? decoded = jsonDecode(body);
      if (decoded is! List<Object?> || decoded.length > 100) {
        throw const FormatException();
      }
      AppRelease? newest;
      var skippedDrafts = 0;
      var skippedPrereleases = 0;
      var skippedUnversionedTags = 0;
      for (final item in decoded) {
        if (item is! Map<String, Object?> ||
            item['draft'] is! bool ||
            item['prerelease'] is! bool ||
            item['tag_name'] is! String) {
          throw const FormatException();
        }
        if (item['draft'] == true) {
          skippedDrafts++;
          continue;
        }
        // GitHub release flags determine eligibility, not the tag spelling.
        if (!includePrereleases && item['prerelease'] == true) {
          skippedPrereleases++;
          continue;
        }
        final tag = item['tag_name'];
        if (tag is! String) throw const FormatException();
        final version = AppVersion.tryParse(tag);
        // Unrelated/non-version tags are not update candidates.
        if (version == null) {
          skippedUnversionedTags++;
          continue;
        }
        final urlText = item['html_url'];
        final url = urlText is String ? Uri.tryParse(urlText) : null;
        if (url == null ||
            url.scheme != 'https' ||
            url.host != 'github.com' ||
            url.port != 443 ||
            url.userInfo.isNotEmpty ||
            url.hasQuery ||
            url.hasFragment ||
            url.pathSegments.length != 5 ||
            url.pathSegments.take(4).join('/') !=
                'CKopoer/BiliSail/releases/tag' ||
            url.pathSegments.last != tag) {
          throw const FormatException();
        }
        final notes = item['body'];
        if (notes != null && notes is! String) throw const FormatException();
        final text = notes is String ? notes : '';
        final publishedValue = item['published_at'];
        if (publishedValue != null && publishedValue is! String) {
          throw const FormatException();
        }
        final publishedText = publishedValue as String?;
        final rows = item['assets'];
        if (rows != null && rows is! List<Object?>) {
          throw const FormatException();
        }
        final release = AppRelease(
          version: version,
          prerelease: item['prerelease'] == true,
          url: url,
          notes: text.length > 12000
              ? '${text.substring(0, 12000)}\n…完整说明请查看 Release 页面'
              : text,
          publishedAt: publishedText == null || publishedText.length > 40
              ? null
              : DateTime.tryParse(publishedText),
          assets: _assets(rows, tag),
        );
        if (newest == null || version.compareTo(newest.version) > 0) {
          newest = release;
        }
      }
      if (newest == null &&
          decoded.isNotEmpty &&
          decoded.any(
            (item) =>
                item is Map<String, Object?> &&
                item['draft'] == false &&
                (includePrereleases || item['prerelease'] == false),
          )) {
        throw const FormatException();
      }
      return _ParsedReleases(
        release: newest,
        candidates: decoded.length,
        skippedDrafts: skippedDrafts,
        skippedPrereleases: skippedPrereleases,
        skippedUnversionedTags: skippedUnversionedTags,
      );
    } on FormatException {
      throw const AppFailure(AppFailureKind.protocol, 'GitHub 更新信息格式异常');
    }
  }

  /// Attachments are informational, so a malformed row is dropped instead of
  /// failing the whole check; every retained URL must stay inside this
  /// project's own release download tree.
  static List<AppReleaseAsset> _assets(Object? rows, String tag) {
    if (rows is! List<Object?> || rows.length > 64) return const [];
    final result = <AppReleaseAsset>[];
    for (final row in rows) {
      if (row is! Map<String, Object?>) continue;
      final name = row['name'];
      final size = row['size'];
      if (name is! String || name.isEmpty || name.length > 200) continue;
      if (size is! int || size < 0 || size > 1 << 40) continue;
      final urlText = row['browser_download_url'];
      final url = urlText is String ? Uri.tryParse(urlText) : null;
      if (url == null ||
          url.scheme != 'https' ||
          url.host != 'github.com' ||
          url.port != 443 ||
          url.userInfo.isNotEmpty ||
          url.hasQuery ||
          url.hasFragment ||
          url.pathSegments.length < 6 ||
          url.pathSegments.take(5).join('/') !=
              'CKopoer/BiliSail/releases/download/$tag' ||
          url.pathSegments[5].isEmpty) {
        continue;
      }
      result.add(AppReleaseAsset(name: name, sizeBytes: size, url: url));
    }
    return List.unmodifiable(result);
  }

  void close() {
    _closed = true;
    for (final client in _clients) {
      client.close(force: true);
    }
    _clients.clear();
  }
}

/// Transport side of one check. Absent fields mean the body came from an
/// injected fetcher, so no real request was made to describe.
final class _RawUpdateResponse {
  const _RawUpdateResponse({
    required this.body,
    this.statusCode,
    this.bytes,
    this.elapsed,
  });

  final String body;
  final int? statusCode;
  final int? bytes;
  final Duration? elapsed;
}

final class _ParsedReleases {
  const _ParsedReleases({
    required this.release,
    required this.candidates,
    required this.skippedDrafts,
    required this.skippedPrereleases,
    required this.skippedUnversionedTags,
  });

  final AppRelease? release;
  final int candidates;
  final int skippedDrafts;
  final int skippedPrereleases;
  final int skippedUnversionedTags;
}
