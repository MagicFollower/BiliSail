import 'package:bilisail/app/shell.dart';
import 'package:bilisail/app/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// The liquid cards are translucent, so the shell paints one gradient behind the
/// whole Scaffold instead of sampling the backdrop per card. These cases pin the
/// wash, the transparent Scaffold that lets it through, and the element shape
/// that must not change when the setting flips.
void main() {
  const listKey = ValueKey('page-list');

  Future<GoRouter> mount(WidgetTester tester) async {
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
            // The app's own path: pages come from `pageBuilder` inside the
            // shell's retained tab views, not from the router child.
            pageBuilder: (_, tab) => tab.location.path == '/'
                ? ListView(
                    key: listKey,
                    children: [
                      for (var index = 0; index < 40; index++)
                        SizedBox(height: 60, child: Text('条目 $index')),
                    ],
                  )
                : SizedBox(key: ValueKey('page-${tab.id}')),
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
    return router;
  }

  /// Only the theme changes between calls: the router and its page tree stay the
  /// same, so a reset scroll offset can only come from the shell's own subtree.
  Future<void> pumpTheme(
    WidgetTester tester,
    GoRouter router, {
    required bool liquid,
  }) async {
    await tester.pumpWidget(
      MaterialApp.router(
        theme: BiliTheme.light(liquidVideoCards: liquid),
        routerConfig: router,
      ),
    );
    await tester.pumpAndSettle();
  }

  double scrollOffset(WidgetTester tester) => tester
      .state<ScrollableState>(
        find.descendant(
          of: find.byKey(listKey),
          matching: find.byType(Scrollable),
        ),
      )
      .position
      .pixels;

  /// `_liquidBackdrop` wraps the Scaffold directly, so the nearest ancestor
  /// widget is the wash itself — an unrelated `DecoratedBox` further up would
  /// make a plain `find.ancestor` assertion pass for the wrong reason.
  BoxDecoration wash(WidgetTester tester) {
    late Widget parent;
    tester.element(find.byType(Scaffold).first).visitAncestorElements((
      element,
    ) {
      parent = element.widget;
      return false;
    });
    return (parent as DecoratedBox).decoration as BoxDecoration;
  }

  testWidgets('the boards float on a wash painted behind the Scaffold', (
    WidgetTester tester,
  ) async {
    final router = await mount(tester);
    await pumpTheme(tester, router, liquid: true);
    final gradient = wash(tester).gradient! as LinearGradient;
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
    final router = await mount(tester);
    await pumpTheme(tester, router, liquid: false);
    // The wrapper stays in the tree on purpose (see the next case); what has to
    // disappear is the painting.
    expect(wash(tester).gradient, isNull);
    expect(wash(tester).color, isNull);
    expect(
      tester.widget<Scaffold>(find.byType(Scaffold).first).backgroundColor,
      isNot(Colors.transparent),
    );
  });

  testWidgets('toggling the board leaves the page scrolled where it was', (
    WidgetTester tester,
  ) async {
    final router = await mount(tester);
    await pumpTheme(tester, router, liquid: true);
    await tester.drag(find.byKey(listKey), const Offset(0, -300));
    await tester.pumpAndSettle();
    final before = scrollOffset(tester);
    expect(before, greaterThan(0));

    await pumpTheme(tester, router, liquid: false);
    // Returning a bare `Scaffold` when the wash is off and a `DecoratedBox`
    // around it when on changes the widget type at that slot, which discards the
    // whole shell subtree - and with it every page's scroll position. The wash
    // therefore always wraps, and only its decoration changes.
    expect(scrollOffset(tester), closeTo(before, 1));
  });
}
