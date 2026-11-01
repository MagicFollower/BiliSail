import 'package:bilisail/core/platform/app_icon_service.dart';
import 'package:bilisail/domain/app_icon.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const service = NativeAppIconService();
  final calls = <MethodCall>[];
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeAppIconService.channel, (call) async {
          calls.add(call);
          return call.method == 'getIcon' ? 'bilibili' : null;
        });
  });
  tearDown(() {
    calls.clear();
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeAppIconService.channel, null);
  });

  test(
    'android restores the enabled launcher alias without re-applying it',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(service.surface, AppIconSurface.launcher);
      expect(
        await service.restore(AppIconPreference.bilisail),
        AppIconPreference.bilibili,
      );
      expect(calls.map((call) => call.method), ['getIcon']);
      await service.apply(AppIconPreference.bilisail);
      // The alias carries its own mipmap artwork: only the name crosses.
      expect(calls.last.arguments, {'icon': 'bilisail'});
    },
  );
  test(
    'unsupported platforms keep the saved preference and refuse to apply',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.fuchsia;
      expect(service.surface, AppIconSurface.unsupported);
      expect(
        await service.restore(AppIconPreference.bilibili),
        AppIconPreference.bilibili,
      );
      expect(calls, isEmpty);
      expect(
        () => service.apply(AppIconPreference.bilisail),
        throwsUnsupportedError,
      );
    },
  );
}
