import 'package:bilisail/features/downloads/domain/download_destination_label.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('says nothing is chosen when the platform has no destination yet', () {
    expect(describeDownloadDestination(null), '未选择');
    expect(describeDownloadDestination(''), '未选择');
    expect(describeDownloadDestination('   '), '未选择');
  });

  test('names the legacy MediaStore sentinel as a real folder', () {
    expect(
      describeDownloadDestination('downloads'),
      '系统下载目录（Download/BiliSail）',
    );
  });

  test('turns an Android file URI into the path a user recognises', () {
    expect(
      describeDownloadDestination('file:///storage/emulated/0/Download/TV'),
      '/storage/emulated/0/Download/TV',
    );
  });

  test('drops the slash URI parsing puts in front of a drive letter', () {
    expect(
      describeDownloadDestination('file:///C:/Users/x/Downloads/BiliSail'),
      'C:/Users/x/Downloads/BiliSail',
    );
  });

  test('decodes a SAF tree id instead of printing content://', () {
    expect(
      describeDownloadDestination(
        'content://com.android.externalstorage.documents/'
        'tree/primary%3ADownload%2FBiliSail',
      ),
      '内部存储/Download/BiliSail',
    );
  });

  test('labels a removable volume and the bare tree root', () {
    expect(
      describeDownloadDestination(
        'content://com.android.externalstorage.documents/tree/1F2E-3D%3AMovies',
      ),
      '存储卷 1F2E-3D/Movies',
    );
    expect(
      describeDownloadDestination(
        'content://com.android.externalstorage.documents/tree/primary%3A',
      ),
      '内部存储',
    );
  });

  test('decodes Chinese folder names in file: and SAF destinations', () {
    // Two shapes reach us: Android's Uri.fromFile keeps the raw characters,
    // while Uri.parse escapes non-ASCII into percent form.
    expect(
      describeDownloadDestination('file:///storage/emulated/0/Download/下载'),
      '/storage/emulated/0/Download/下载',
    );
    expect(
      describeDownloadDestination(
        'file:///storage/emulated/0/Download/%E4%B8%8B%E8%BD%BD',
      ),
      '/storage/emulated/0/Download/下载',
    );
    expect(
      describeDownloadDestination(
        'content://com.android.externalstorage.documents/'
        'tree/primary%3ADownload%2F%E4%B8%8B%E8%BD%BD',
      ),
      '内部存储/Download/下载',
    );
  });

  test('falls back without throwing on shapes it does not own', () {
    expect(describeDownloadDestination('not a uri'), 'not a uri');
    // An invalid escape makes Uri.decodeComponent raise ArgumentError, which
    // must degrade to showing the id, not to a broken settings page.
    expect(
      describeDownloadDestination(
        'content://com.android.externalstorage.documents/tree/primary%3A100%zz',
      ),
      '内部存储/100%zz',
    );
    expect(
      describeDownloadDestination('content://com.example.provider/document/x'),
      '已授权的文件夹',
    );
    expect(
      describeDownloadDestination('https://example.com/download'),
      'https://example.com/download',
    );
  });
}
