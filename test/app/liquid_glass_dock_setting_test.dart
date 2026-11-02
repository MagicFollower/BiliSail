import 'package:bilisail/app/shell.dart';
import 'package:bilisail/app/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:liquid_dock_navi/liquid_dock_navi.dart';

void main() {
  /// Mounts the narrow layout, where the setting has something to switch: the
  /// wide layout keeps its sidebar either way.
  Future<GoRouter> mount(WidgetTester tester, {required bool glass}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.display.size = const Size(390, 900);
    tester.view.physicalSize = const Size(390, 900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.display.resetSize);
    addTearDown(tester.view.resetPhysicalSize);
    final router = GoRouter(
      initialLocation: '/settings',
      routes: [
        ShellRoute(
          builder: (context, state, child) => BiliAppShell(
            location: state.uri.toString(),
            liquidGlassDock: glass,
            pageBuilder: (_, tab) => SizedBox(key: ValueKey('page-${tab.id}')),
            child: child,
          ),
          routes: [
            for (final path in ['/', '/me', '/settings', '/downloads'])
              GoRoute(path: path, builder: (_, _) => const SizedBox()),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MaterialApp.router(theme: BiliTheme.light(), routerConfig: router),
    );
    await tester.pumpAndSettle();
    return router;
  }

  testWidgets('the glass dock is the default bottom bar', (tester) async {
    await mount(tester, glass: true);
    expect(find.byType(LiquidDockNavi), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    // The dock carries the two entries the narrow layout has no toolbar for.
    final bar = find.byKey(const ValueKey('workspace-bottom-navigation'));
    expect(find.descendant(of: bar, matching: find.text('历史')), findsOneWidget);
    expect(find.descendant(of: bar, matching: find.text('下载')), findsOneWidget);
  });

  testWidgets('turning the setting off restores the Material bar', (
    tester,
  ) async {
    final router = await mount(tester, glass: false);
    expect(find.byType(LiquidDockNavi), findsNothing);
    expect(find.byType(NavigationBar), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('workspace-bottom-home')));
    await tester.pumpAndSettle();
    expect(router.routeInformationProvider.value.uri.path, '/');
  });

  testWidgets('the Material bar leaves queue pages without a selection', (
    tester,
  ) async {
    final router = await mount(tester, glass: false);
    // Upstream's bar has no downloads destination, so the queue page shows the
    // all-unselected strip instead of borrowing another section's highlight.
    router.go('/downloads');
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsNothing);
    expect(
      find.byKey(const ValueKey('workspace-bottom-navigation')),
      findsOneWidget,
    );
  });
}
