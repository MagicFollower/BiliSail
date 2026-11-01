import '../../../domain/request_cancellation.dart';

final class AppUpdateLinks {
  static final repository = Uri.https('github.com', '/CKopoer/BiliSail');
  static final releases = Uri.https('github.com', '/CKopoer/BiliSail/releases');
}

/// Semantic version precedence, then the numeric Flutter build revision.
final class AppVersion implements Comparable<AppVersion> {
  AppVersion._(
    this.label,
    this.major,
    this.minor,
    this.patch,
    this.build,
    List<String> prerelease,
  ) : prerelease = List.unmodifiable(prerelease);

  final String label;
  final int major, minor, patch, build;
  final List<String> prerelease;

  String get baseVersion => '$major.$minor.$patch';

  static AppVersion? tryParse(String value) {
    if (value.length > 128) return null;
    final match = RegExp(
      r'^v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$',
    ).firstMatch(value);
    if (match == null) return null;
    final core = [
      for (var i = 1; i <= 3; i++) int.tryParse(match.group(i) ?? ''),
    ];
    if (core.any((part) => part == null)) return null;
    final prerelease = match.group(4)?.split('.') ?? <String>[];
    for (final part in prerelease) {
      if (RegExp(r'^\d+$').hasMatch(part) &&
          (part.length > 1 && part.startsWith('0') ||
              int.tryParse(part) == null)) {
        return null;
      }
    }
    final metadata = match.group(5);
    final numericBuild =
        metadata != null && RegExp(r'^\d+$').hasMatch(metadata);
    final build = numericBuild ? int.tryParse(metadata) : 0;
    if (build == null) return null;
    return AppVersion._(
      value.startsWith('v') ? value.substring(1) : value,
      core[0] ?? 0,
      core[1] ?? 0,
      core[2] ?? 0,
      build,
      prerelease,
    );
  }

  @override
  int compareTo(AppVersion other) {
    for (final (a, b) in [
      (major, other.major),
      (minor, other.minor),
      (patch, other.patch),
    ]) {
      final result = a.compareTo(b);
      if (result != 0) return result;
    }
    if (prerelease.isEmpty != other.prerelease.isEmpty) {
      return prerelease.isEmpty ? 1 : -1;
    }
    for (var i = 0; i < prerelease.length && i < other.prerelease.length; i++) {
      final a = prerelease[i], b = other.prerelease[i];
      final aNumber = int.tryParse(a), bNumber = int.tryParse(b);
      final result = aNumber != null && bNumber != null
          ? aNumber.compareTo(bNumber)
          : aNumber != null
          ? -1
          : bNumber != null
          ? 1
          : a.compareTo(b);
      if (result != 0) return result;
    }
    final length = prerelease.length.compareTo(other.prerelease.length);
    return length != 0 ? length : build.compareTo(other.build);
  }
}

final class AppReleaseAsset {
  const AppReleaseAsset({
    required this.name,
    required this.sizeBytes,
    required this.url,
  });

  final String name;
  final int sizeBytes;
  final Uri url;
}

/// One update request as it actually happened, shown in the release prompt so a
/// reported result is auditable without capturing the network.
final class UpdateCheckReport {
  const UpdateCheckReport({
    required this.endpoint,
    required this.requestHeaders,
    required this.prereleaseChannelIncluded,
    this.statusCode,
    this.responseBytes,
    this.elapsed,
    this.candidates = 0,
    this.skippedDrafts = 0,
    this.skippedPrereleases = 0,
    this.skippedUnversionedTags = 0,
  });

  final Uri endpoint;
  final Map<String, String> requestHeaders;
  final bool prereleaseChannelIncluded;
  final int? statusCode;
  final int? responseBytes;
  final Duration? elapsed;
  final int candidates;
  final int skippedDrafts;
  final int skippedPrereleases;
  final int skippedUnversionedTags;

  /// Plain text for the clipboard, so a user can paste the exact request record
  /// into an issue report.
  String toPlainText({String? installedLabel, AppVersion? selected}) {
    final headers = requestHeaders.entries
        .map((entry) => '${entry.key}: ${entry.value}')
        .join('\n');
    return [
      '请求 GET $endpoint',
      '请求头',
      headers,
      '状态码 ${statusCode ?? '未知（未走真实网络）'}',
      '响应 ${responseBytes ?? 0} 字节',
      '耗时 ${elapsed == null ? '未记录' : '${(elapsed!.inMilliseconds / 1000).toStringAsFixed(2)} 秒'}',
      '预发布通道 ${prereleaseChannelIncluded ? '包含' : '排除'}',
      '候选 $candidates 条：草稿 $skippedDrafts、预发布 $skippedPrereleases、'
          '非版本标签 $skippedUnversionedTags 已排除',
      '本机版本 ${installedLabel ?? '未知'}',
      '选中版本 ${selected?.label ?? '无'}',
    ].join('\n');
  }
}

final class AppRelease {
  const AppRelease({
    required this.version,
    required this.url,
    this.notes = '',
    this.prerelease = false,
    this.publishedAt,
    this.assets = const [],
    this.report,
  });
  final AppVersion version;
  final Uri url;
  final String notes;
  final bool prerelease;

  /// UTC publication time from the host; null when the response omitted it.
  final DateTime? publishedAt;
  final List<AppReleaseAsset> assets;

  /// Diagnostics of the request that produced this release. Absent when a
  /// release was built without a transport round trip, such as in tests.
  final UpdateCheckReport? report;
}

abstract interface class AppUpdateRepository {
  Future<AppVersion> installedVersion();
  Future<AppRelease?> latestRelease(
    RequestCancellation cancellation, {
    bool includePrereleases = false,
  });
}

abstract interface class UpdateCheckStore {
  /// Persist the local calendar day before the automatic network attempt.
  Future<bool> claimStartupDay(String day);
  Future<bool> claimAutomaticPrompt(AppVersion version);
}
