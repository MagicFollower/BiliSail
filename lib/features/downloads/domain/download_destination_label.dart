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
  if (uri.scheme == 'file') return _displayPath(uri.path);
  if (uri.scheme == 'content') return _describeTree(uri);
  return value;
}

const _mediaStoreSentinel = 'downloads';

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
  // Uri.pathSegments is already percent-decoded, so a SAF document id like
  // `primary%3ADownload%2FBiliSail` arrives as `primary:Download/BiliSail`.
  final documentId = segments[segments.length - 1];
  final separator = documentId.indexOf(':');
  if (separator < 0) return documentId;
  final volume = documentId.substring(0, separator);
  final rest = documentId.substring(separator + 1);
  final owner = volume == 'primary' ? '内部存储' : '存储卷 $volume';
  return rest.isEmpty ? owner : '$owner/$rest';
}
