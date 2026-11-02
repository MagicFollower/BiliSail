/// One-line, human-readable form of a stored public download destination.
///
/// The stored value is whatever the platform persisted, and none of the three
/// shapes is something a user can read: the legacy MediaStore mode is the
/// literal sentinel `downloads`, a chosen folder is a `file:` URI, and a SAF
/// grant is a `content://…/tree/…` URI whose document id is not a path. This
/// keeps the labels here so the settings dialog and any later import surface
/// describe the same location the same way.
String describeDownloadDestination(String? destination) {
  final value = destination?.trim() ?? '';
  if (value.isEmpty) return '未选择';
  if (value == _mediaStoreSentinel) return '系统下载目录（Download/BiliSail）';
  final uri = Uri.tryParse(value);
  if (uri == null) return value;
  if (uri.scheme == 'file') return _displayPath(_decode(uri.path));
  if (uri.scheme == 'content') return _describeTree(uri);
  return value;
}

const _mediaStoreSentinel = 'downloads';

/// `Uri.path` is percent-encoded, and `Uri.parse` itself escapes non-ASCII -
/// so a folder named 下载 reaches us as `%E4%B8%8B%E8%BD%BD` and must be
/// decoded before a user sees it. Decoding is done here rather than with
/// `Uri.toFilePath()` because that also rewrites separators for the host
/// platform, and this string is a label, not a path we operate on.
String _decode(String encoded) {
  try {
    return Uri.decodeComponent(encoded);
  } on Object catch (error) {
    // A stray `%` raises ArgumentError and non-UTF-8 bytes raise
    // FormatException; neither is worth failing a label over, but anything
    // else is a real bug and must surface.
    if (error is! ArgumentError && error is! FormatException) rethrow;
    return encoded;
  }
}

/// Strips the `file://` artifact and the leading slash Windows paths get from
/// URI parsing, which is the difference between `/C:/Users/x` and `C:/Users/x`.
String _displayPath(String path) {
  final windows = RegExp(r'^/([A-Za-z]:)').firstMatch(path);
  return windows == null ? path : path.substring(1);
}

String _describeTree(Uri uri) {
  final segments = uri.pathSegments;
  final treeIndex = segments.lastIndexOf('tree');
  if (treeIndex < 0 || treeIndex == segments.length - 1) return '已授权的文件夹';
  // Uri.pathSegments is already percent-decoded; decoding again is a no-op for
  // anything without a `%`, and covers a provider that escapes twice.
  final documentId = _decode(segments[segments.length - 1]);
  final separator = documentId.indexOf(':');
  if (separator < 0) return documentId;
  final volume = documentId.substring(0, separator);
  final rest = documentId.substring(separator + 1);
  final owner = volume == 'primary' ? '内部存储' : '存储卷 $volume';
  return rest.isEmpty ? owner : '$owner/$rest';
}
