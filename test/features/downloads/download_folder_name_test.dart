import 'dart:convert';

import 'package:bilisail/features/downloads/domain/download_folder_name.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('names the folder after the bvid, part and title', () {
    expect(
      downloadFolderName(videoId: 'BV1gDEUuUZA', page: 3, title: '测试视频'),
      'BV1gDEUuUZA-P3 测试视频',
    );
  });

  test('falls back to the bare part id when nothing readable survives', () {
    expect(
      downloadFolderName(videoId: 'BV1gDEUuUZA', page: 1, title: ' /// '),
      'BV1gDEUuUZA-P1',
    );
  });

  test('replaces separators and collapses the whitespace they leave', () {
    expect(
      downloadFolderName(
        videoId: 'BV1gDEUuUZA',
        page: 1,
        title: 'a/b\\c:d*e?f"g<h>i|j\nk',
      ),
      'BV1gDEUuUZA-P1 a b c d e f g h i j k',
    );
  });

  test('never ends in a dot or space a provider would silently trim', () {
    expect(
      downloadFolderName(videoId: 'BV1gDEUuUZA', page: 1, title: 'x. '),
      'BV1gDEUuUZA-P1 x',
    );
  });

  test('caps a multi-byte title by bytes without cutting a code point', () {
    final name = downloadFolderName(
      videoId: 'BV1gDEUuUZA',
      page: 12,
      title: '标' * 300,
    );
    expect(utf8.encode(name).length, lessThanOrEqualTo(160));
    expect(name.startsWith('BV1gDEUuUZA-P12 '), isTrue);
    expect(
      name.runes.any((rune) => rune >= 0xD800 && rune <= 0xDFFF),
      isFalse,
      reason: 'a split code point would leave a lone surrogate',
    );
  });

  test('leaves room inside 200 bytes for the platform collision suffix', () {
    final name = downloadFolderName(
      videoId: 'BV1gDEUuUZA',
      page: 1,
      title: 'y' * 400,
    );
    expect(utf8.encode('$name-99').length, lessThanOrEqualTo(200));
  });
}
