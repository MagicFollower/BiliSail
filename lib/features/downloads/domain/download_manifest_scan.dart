import 'dart:convert';

import '../../../domain/video.dart';
import '../../../domain/video_codec.dart';
import 'download_models.dart';

/// A published manifest that parsed cleanly and agreed with the files the
/// platform actually listed next to it.
final class PublishedManifest {
  PublishedManifest({
    required this.id,
    required this.item,
    required this.selection,
    required List<DownloadTrackProgress> tracks,
    required this.mergedBytes,
    required this.mergedSha256,
    required this.createdAt,
    required Map<String, int> mediaBytes,
    required this.extrasBytes,
  }) : tracks = List.unmodifiable(tracks),
       mediaBytes = Map.unmodifiable(mediaBytes);

  final String id;
  final DownloadItem item;
  final DownloadSelection selection;
  final List<DownloadTrackProgress> tracks;
  final int? mergedBytes;
  final String? mergedSha256;
  final DateTime createdAt;

  /// Media file name → bytes the folder must hold. Re-checked on every scan.
  final Map<String, int> mediaBytes;
  final int? extrasBytes;
}

/// Either a manifest to import, or why this folder is not ours to import.
final class PublishedManifestResult {
  const PublishedManifestResult.accepted(PublishedManifest this.manifest)
    : reason = null;
  const PublishedManifestResult.refused(String this.reason) : manifest = null;

  final PublishedManifest? manifest;
  final String? reason;
}

final RegExp _idPattern = RegExp(r'^[0-9a-f]{32}$');
final RegExp _cidPattern = RegExp(r'^[1-9][0-9]*$');

/// Rebuilds a queue row from a published `manifest.json`.
///
/// The byte comparison against [listedBytes] is what makes it safe to run this
/// without asking: a folder whose media was truncated, replaced or hand-edited
/// is refused with a reason instead of being imported as playable. Nothing here
/// touches the network, the database or a platform channel, so it also runs in
/// an isolate over hundreds of folders.
PublishedManifestResult parsePublishedManifest({
  required String manifestText,
  required Map<String, int> listedBytes,
}) {
  final Object? decoded;
  try {
    decoded = jsonDecode(manifestText);
  } on FormatException {
    return const PublishedManifestResult.refused('清单不是有效的 JSON');
  }
  if (decoded is! Map<String, Object?>) {
    return const PublishedManifestResult.refused('清单格式无效');
  }
  final manifest = decoded;
  if (manifest['version'] != 3) {
    return const PublishedManifestResult.refused('清单版本不受支持');
  }
  final id = manifest['id'];
  if (id is! String || !_idPattern.hasMatch(id)) {
    return const PublishedManifestResult.refused('清单任务标识无效');
  }
  final video = _map(manifest['video']);
  final part = _map(manifest['part']);
  if (video == null || part == null) {
    return const PublishedManifestResult.refused('清单缺少视频信息');
  }
  final bvid = video['id'];
  final title = video['title'];
  final author = video['author'];
  final cid = part['cid'];
  final page = part['page'];
  if (bvid is! String ||
      !VideoId(bvid).isValid ||
      title is! String ||
      author is! String ||
      cid is! String ||
      !_cidPattern.hasMatch(cid) ||
      page is! int ||
      page < 1) {
    return const PublishedManifestResult.refused('清单视频或分 P 标识无效');
  }
  final outputName = manifest['output'];
  final output = DownloadOutput.values
      .where((item) => item.name == outputName)
      .firstOrNull;
  if (output == null) {
    return const PublishedManifestResult.refused('清单保存格式无效');
  }
  final codecName = manifest['codec'];
  final codec = VideoCodecPreference.values
      .where((item) => item.name == codecName)
      .firstOrNull;
  if (codec == null) {
    return const PublishedManifestResult.refused('清单编码无效');
  }
  final quality = manifest['quality'];
  if (quality is! int || quality <= 0) {
    return const PublishedManifestResult.refused('清单清晰度无效');
  }
  final createdAtMs = manifest['createdAtMs'];
  if (createdAtMs is! int) {
    return const PublishedManifestResult.refused('清单缺少创建时间');
  }
  final tracks = _tracks(manifest['tracks']);
  if (tracks == null) {
    return const PublishedManifestResult.refused('清单轨道信息无效');
  }
  final mediaBytes = <String, int>{};
  int? mergedBytes;
  String? mergedSha256;
  if (output == DownloadOutput.separate) {
    for (final track in tracks) {
      mediaBytes[track.fileName] = track.bytes;
    }
    if (!mediaBytes.containsKey('video.m4s') ||
        !mediaBytes.containsKey('audio.m4s')) {
      return const PublishedManifestResult.refused('清单轨道与分轨文件不符');
    }
  } else {
    final merged = _map(manifest['merged']);
    if (merged == null) {
      return const PublishedManifestResult.refused('清单缺少合并文件信息');
    }
    final bytes = merged['bytes'];
    if (bytes is! int || bytes <= 0) {
      return const PublishedManifestResult.refused('清单合并文件信息无效');
    }
    mediaBytes[output.fileName] = bytes;
    mergedBytes = bytes;
    mergedSha256 = _digest(merged['sha256']);
  }
  for (final entry in mediaBytes.entries) {
    if (listedBytes[entry.key] != entry.value) {
      return PublishedManifestResult.refused('${entry.key} 缺失或大小与清单不符');
    }
  }
  final partTitle = part['title'];
  final aid = manifest['aid'];
  return PublishedManifestResult.accepted(
    PublishedManifest(
      id: id,
      item: DownloadItem(
        video: VideoSummary(
          id: VideoId(bvid),
          title: title,
          coverUrl: '',
          author: author,
          duration: _duration(video['durationMs']),
        ),
        part: VideoPart(
          cid: cid,
          page: page,
          title: partTitle is String ? partTitle : '',
          duration: _duration(part['durationMs']),
        ),
        aid: aid is String ? aid : null,
      ),
      selection: DownloadSelection(
        quality: quality,
        codec: codec,
        output: output,
      ),
      tracks: tracks,
      mergedBytes: mergedBytes,
      mergedSha256: mergedSha256,
      createdAt: DateTime.fromMillisecondsSinceEpoch(createdAtMs),
      mediaBytes: mediaBytes,
      extrasBytes: listedBytes['extras.json'],
    ),
  );
}

Map<String, Object?>? _map(Object? value) =>
    value is Map<String, Object?> ? value : null;

/// Both DASH tracks, or null when the list is malformed. The manifest is only
/// ever written for a task with exactly one video and one audio track, and each
/// entry must name the file it describes, because that name is what the scan
/// compares against the folder listing.
List<DownloadTrackProgress>? _tracks(Object? value) {
  if (value is! List<Object?> || value.length != 2) return null;
  final tracks = <DownloadTrackProgress>[];
  for (final entry in value) {
    final track = _map(entry);
    if (track == null) return null;
    final kindName = track['kind'];
    final kind = DownloadTrackKind.values
        .where((item) => item.name == kindName)
        .firstOrNull;
    if (kind == null) return null;
    final fileName = track['fileName'];
    final identity = track['identity'];
    final codec = track['codec'];
    final bandwidth = track['bandwidth'];
    final bytes = track['bytes'];
    final expected = kind == DownloadTrackKind.video
        ? 'video.m4s'
        : 'audio.m4s';
    if (fileName != expected ||
        identity is! String ||
        codec is! String ||
        bandwidth is! int ||
        bytes is! int ||
        bytes <= 0) {
      return null;
    }
    tracks.add(
      DownloadTrackProgress(
        kind: kind,
        identity: identity,
        fileName: expected,
        codec: codec,
        bandwidth: bandwidth,
        bytes: bytes,
        totalBytes: bytes,
        sha256: _digest(track['sha256']),
        committed: true,
      ),
    );
  }
  if (tracks.map((track) => track.kind).toSet().length != 2) return null;
  return tracks;
}

/// A digest is optional metadata: accept it only in full, never a truncated
/// string that would look like a verified checksum.
String? _digest(Object? value) =>
    value is String && value.length == 64 ? value : null;

Duration _duration(Object? milliseconds) =>
    milliseconds is int && milliseconds > 0
    ? Duration(milliseconds: milliseconds)
    : Duration.zero;
