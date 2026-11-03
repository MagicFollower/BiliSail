import 'package:bilisail/app/shell.dart';
import 'package:bilisail/app/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// The liquid cards are translucent, so the shell paints one gradient behind the
/// whole Scaffold instead of sampling the backdrop per card. These two cases pin
/// both halves of that deal: the wash exists, and the Scaffold stops hiding it.
void main() {
  Future<void> mount(WidgetTester tester, {required bool liquid}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.display.size = const Size(390, 900);
    tester.view.physicalSize = const Size(390, 900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.display.resetSize);
    addTearDown(tester.view.resetPhysicalSize);
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        ShellRoute(
          builder: (context, state, child) => BiliAppShell(
            location: state.uri.toString(),
            pageBuilder: (_, tab) => SizedBox(key: ValueKey('page-${tab.id}')),
            child: child,
          ),
          routes: [
            for (final path in ['/', '/me', '/settings'])
              GoRoute(path: path, builder: (_, _) => const SizedBox()),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MaterialApp.router(
        theme: BiliTheme.light(liquidVideoCards: liquid),
        routerConfig: router,
      ),
    );
    await tester.pumpAndSettle();
  }

  /// `_liquidBackdrop` wraps the Scaffold directly, so the nearest ancestor
  /// widget is the wash itself — an unrelated `DecoratedBox` further up would
  /// make a plain `find.ancestor` assertion pass for the wrong reason.
  Widget parentOfScaffold(WidgetTester tester) {
    late Widget parent;
    tester.element(find.byType(Scaffold).first).visitAncestorElements((
      element,
    ) {
      parent = element.widget;
      return false;
    });
    return parent;
  }

  testWidgets('the boards float on a wash painted behind the Scaffold', (
    WidgetTester tester,
  ) async {
    await mount(tester, liquid: true);
    final wash =
        (parentOfScaffold(tester) as DecoratedBox).decoration as BoxDecoration;
    final gradient = wash.gradient! as LinearGradient;
    // A wash with nothing behind it is just a background, so it has to be the
    // translucent kind that lets the window tint through.
    expect(gradient.colors.every((color) => color.a > 0), isTrue);
    expect(gradient.colors.first, isNot(gradient.colors.last));
    // And the page has to stop painting its own opaque colour over it.
    expect(
      tester.widget<Scaffold>(find.byType(Scaffold).first).backgroundColor,
      Colors.transparent,
    );
  });

  testWidgets('turning the setting off leaves the page flat', (
    WidgetTester tester,
  ) async {
    await mount(tester, liquid: false);
    expect(parentOfScaffold(tester), isNot(isA<DecoratedBox>()));
    expect(
      tester.widget<Scaffold>(find.byType(Scaffold).first).backgroundColor,
      isNot(Colors.transparent),
    );
  });
}
