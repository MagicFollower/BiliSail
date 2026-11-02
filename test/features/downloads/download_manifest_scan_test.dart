import 'dart:convert';

import 'package:bilisail/features/downloads/domain/download_manifest_scan.dart';
import 'package:bilisail/features/downloads/domain/download_models.dart';
import 'package:flutter_test/flutter_test.dart';

const _id = '0123456789abcdef0123456789abcdef';
final _sha = 'a' * 64;

String _manifest({
  DownloadOutput output = DownloadOutput.mp4,
  int version = 3,
  int videoBytes = 4000,
  int audioBytes = 900,
  int? mergedBytes = 4900,
  String id = _id,
  String bvid = 'BV1234567890',
}) => jsonEncode({
  'version': version,
  'id': id,
  'itemKey': 'video:$bvid:1',
  'createdAtMs': 1730000000000,
  'video': {'id': bvid, 'title': '测试标题', 'author': '测试UP', 'durationMs': 60000},
  'part': {'cid': '1', 'page': 2, 'title': 'P2', 'durationMs': 60000},
  'aid': '99',
  'quality': 80,
  'codec': 'h264',
  'output': output.name,
  if (mergedBytes != null)
    'merged': {
      'fileName': output.fileName,
      'bytes': mergedBytes,
      'sha256': _sha,
    },
  'tracks': [
    {
      'kind': 'video',
      'identity': 'v1',
      'fileName': 'video.m4s',
      'codec': 'avc1.640032',
      'bandwidth': 1000,
      'bytes': videoBytes,
      'sha256': _sha,
    },
    {
      'kind': 'audio',
      'identity': 'a1',
      'fileName': 'audio.m4s',
      'codec': 'mp4a.40.2',
      'bandwidth': 200,
      'bytes': audioBytes,
      'sha256': _sha,
    },
  ],
});

final _mergedListing = {
  'media.mp4': 4900,
  'manifest.json': 120,
  'extras.json': 50,
};

void main() {
  test('imports a merged folder whose bytes match the listing', () {
    final result = parsePublishedManifest(
      manifestText: _manifest(),
      listedBytes: _mergedListing,
    );
    final manifest = result.manifest;
    expect(manifest, isNotNull, reason: result.reason);
    expect(manifest!.id, _id);
    expect(manifest.selection.output, DownloadOutput.mp4);
    expect(manifest.mergedBytes, 4900);
    expect(manifest.mergedSha256, _sha);
    expect(manifest.extrasBytes, 50);
    expect(manifest.item.part.page, 2);
    expect(manifest.item.video.title, '测试标题');
    expect(manifest.tracks.every((track) => track.complete), isTrue);
  });

  test('imports a separate-track folder and needs both files', () {
    final accepted = parsePublishedManifest(
      manifestText: _manifest(
        output: DownloadOutput.separate,
        mergedBytes: null,
      ),
      listedBytes: const {'video.m4s': 4000, 'audio.m4s': 900},
    );
    expect(accepted.manifest, isNotNull, reason: accepted.reason);
    final missingAudio = parsePublishedManifest(
      manifestText: _manifest(
        output: DownloadOutput.separate,
        mergedBytes: null,
      ),
      listedBytes: const {'video.m4s': 4000},
    );
    expect(missingAudio.reason, contains('audio.m4s'));
  });

  test('refuses a folder whose media was truncated', () {
    final result = parsePublishedManifest(
      manifestText: _manifest(),
      listedBytes: const {'media.mp4': 1200},
    );
    expect(result.manifest, isNull);
    expect(result.reason, contains('media.mp4'));
  });

  test('refuses shapes that are not ours to trust', () {
    PublishedManifestResult parse(String text, [Map<String, int>? listed]) =>
        parsePublishedManifest(
          manifestText: text,
          listedBytes: listed ?? _mergedListing,
        );

    expect(parse('not json').reason, contains('JSON'));
    expect(parse('[]').reason, contains('格式'));
    expect(
      parse(_manifest(version: 2)).reason,
      '清单版本不受支持',
      reason: 'v2 folders predate the sidecar layout',
    );
    expect(parse(_manifest(id: 'zz')).reason, contains('任务标识'));
    expect(parse(_manifest(bvid: 'BV1')).reason, contains('分 P 标识'));
    expect(parse(_manifest(mergedBytes: null)).reason, contains('合并文件'));
  });

  test('refuses a track list that does not name both media files', () {
    final broken = jsonDecode(_manifest()) as Map<String, Object?>;
    (broken['tracks']! as List<Object?>).removeAt(1);
    final result = parsePublishedManifest(
      manifestText: jsonEncode(broken),
      listedBytes: _mergedListing,
    );
    expect(result.reason, contains('轨道'));
  });

  test('drops a truncated digest instead of treating it as verified', () {
    final text = _manifest().replaceAll(_sha, 'abc');
    final result = parsePublishedManifest(
      manifestText: text,
      listedBytes: _mergedListing,
    );
    expect(result.manifest, isNotNull, reason: result.reason);
    expect(result.manifest!.mergedSha256, isNull);
    expect(
      result.manifest!.tracks.every((track) => track.sha256 == null),
      isTrue,
    );
    // Still complete: the byte match against the listing is the gate here.
    expect(result.manifest!.tracks.every((track) => track.complete), isTrue);
  });
}
