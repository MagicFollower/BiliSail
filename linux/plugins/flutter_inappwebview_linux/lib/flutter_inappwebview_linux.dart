import 'package:flutter_inappwebview_platform_interface/flutter_inappwebview_platform_interface.dart';

/// BiliSail advertises QR login on Linux and never constructs a native WebView.
/// The inherited unsupported operations fail if the capability gate is bypassed.
final class LinuxInAppWebViewPlatform extends InAppWebViewPlatform {
  static void registerWith() {
    InAppWebViewPlatform.instance = LinuxInAppWebViewPlatform();
  }
}
