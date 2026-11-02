import '../../../domain/request_cancellation.dart';
import 'download_models.dart';

final class DownloadFolder {
  const DownloadFolder({required this.path, required this.name});
  final String path;
  final String name;
}

final class DownloadFolderListing {
  DownloadFolderListing({
    this.directory,
    this.parent,
    required List<DownloadFolder> folders,
    this.truncated = false,
  }) : folders = List.unmodifiable(folders);
  final DownloadFolder? directory;
  final String? parent;
  final List<DownloadFolder> folders;
  final bool truncated;
}

/// One file inside a published per-part folder, as the platform sees it.
final class PublishedFile {
  const PublishedFile({
    required this.name,
    required this.uri,
    required this.bytes,
    required this.modifiedMs,
  });
  final String name, uri;
  final int bytes, modifiedMs;
}

/// A folder in the shared download location that carries our own manifest.
///
/// [key] is the platform's stable identity for that folder - an absolute path,
/// a MediaStore relative path, or a SAF document id - and is what the scan
/// cache is keyed by. It is opaque to Dart and must never be shown raw.
final class PublishedFolder {
  PublishedFolder({
    required this.key,
    required this.name,
    required List<PublishedFile> files,
  }) : files = List.unmodifiable(files);
  final String key, name;
  final List<PublishedFile> files;

  PublishedFile? named(String name) =>
      files.where((file) => file.name == name).firstOrNull;
}

/// Selected shared folders and legacy provider URIs retain private staging.
abstract interface class PublicDownloadStorage {
  Future<bool> hasDestination();
  Future<bool> requestDirectoryAccess();
  Future<DownloadFolderListing> listDirectories(String? directory);
  Future<void> chooseDestination(String directory);
  Future<String> destination();

  /// Copies [files] (media plus sidecars) into the destination under the
  /// readable per-part [folder]. The platform layer owns uniqueness: it may
  /// append a `-2` style suffix, so callers must not assume the name survived
  /// verbatim — identity lives in the published `manifest.json`.
  Future<Map<String, String>> publish(
    DownloadTask task,
    Map<String, String> files, {
    required String folder,
    required RequestCancellation cancellation,
  });
  Future<void> verify(DownloadTask task);
  Future<void> delete(DownloadTask task);

  /// Lists the published per-part folders in the shared location.
  ///
  /// Only folders holding our own `manifest.json` come back, and the listing is
  /// one level deep: the scan must never walk a user's unrelated subtree.
  Future<List<PublishedFolder>> listPublishedFolders();

  /// Where this platform's native storage handler last reached, kept outside the
  /// process so it survives being killed. It is the only trace left of a pass
  /// that died inside a provider call, where no reply and no Dart error arrive.
  /// A storage with no native side answers null.
  Future<String?> lastNativeStep();

  /// Reads one small published text file, re-checking that it really is a child
  /// of [folder] and that its name is a manifest or the danmaku/subtitle sidecar.
  Future<String> readPublishedText({
    required String folder,
    required String uri,
    int maxBytes = 262144,
  });

  /// Re-adopts a published folder the scan found, so the platform journal,
  /// verification, playback URIs and deletion all treat it as ours again.
  /// Throws when any [files] URI no longer resolves inside that folder.
  Future<void> adoptPublishedFolder({
    required DownloadTask task,
    required String folder,
    required Map<String, String> files,
  });

  /// Streams a published sidecar back into the task's private directory, so an
  /// imported part keeps its danmaku and subtitles without re-downloading them.
  Future<void> copyPublishedSidecar({
    required String folder,
    required String uri,
    required String targetPath,
  });
}
