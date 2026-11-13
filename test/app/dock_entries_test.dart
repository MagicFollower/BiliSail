import 'package:bilisail/app/shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_dock_navi/liquid_dock_navi.dart';

void main() {
  testWidgets(
    'dock history and downloads entries stay on the glass bar when enabled',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var location = '/';
      late StateSetter setOuterState;
      Widget buildShell() => MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            setOuterState = setState;
            return BiliAppShell(
              location: location,
              // 显式开启「底部显示历史和下载」，验证开启时两个入口在玻璃底栏上。
              dockShowHistoryDownloads: true,
              child: const SizedBox.expand(),
            );
          },
        ),
      );
      await tester.pumpWidget(buildShell());
      await tester.pumpAndSettle();
      LiquidDockNavi widget() =>
          tester.widget<LiquidDockNavi>(find.byType(LiquidDockNavi));
      int indexFor(String label) {
        final w = widget();
        return w.items.indexWhere((item) => item.label == label);
      }

      // Home starts selected.
      expect(find.byType(LiquidDockNavi), findsOneWidget);
      expect(indexFor('首页'), 0);

      // Switching to history keeps the glass dock and highlights history.
      setOuterState(() => location = '/history');
      await tester.pumpAndSettle();
      expect(find.byType(LiquidDockNavi), findsOneWidget);
      expect(find.text('历史'), findsOneWidget);
      expect(widget().currentIndex, indexFor('历史'));

      // Switching to downloads keeps the glass dock and highlights downloads.
      setOuterState(() => location = '/downloads');
      await tester.pumpAndSettle();
      expect(find.byType(LiquidDockNavi), findsOneWidget);
      expect(find.text('下载'), findsOneWidget);
      expect(widget().currentIndex, indexFor('下载'));

      // Back to home.
      setOuterState(() => location = '/');
      await tester.pumpAndSettle();
      expect(widget().currentIndex, indexFor('首页'));
    },
  );

  testWidgets('dock omits history and downloads by default', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var location = '/';
    late StateSetter setOuterState;
    Widget buildShell() => MaterialApp(
      home: StatefulBuilder(
        builder: (context, setState) {
          setOuterState = setState;
          // 不传 dockShowHistoryDownloads，使用默认值 false。
          return BiliAppShell(
            location: location,
            child: const SizedBox.expand(),
          );
        },
      ),
    );
    await tester.pumpWidget(buildShell());
    await tester.pumpAndSettle();
    LiquidDockNavi widget() =>
        tester.widget<LiquidDockNavi>(find.byType(LiquidDockNavi));
    int indexFor(String label) {
      final w = widget();
      return w.items.indexWhere((item) => item.label == label);
    }

    // 默认底栏只有首页/动态/我的/设置，不含历史与下载入口。
    expect(find.byType(LiquidDockNavi), findsOneWidget);
    expect(indexFor('首页'), 0);
    expect(find.text('历史'), findsNothing);
    expect(find.text('下载'), findsNothing);

    // /history 没有独立入口，像 Material 底栏那样高亮「我的」。
    setOuterState(() => location = '/history');
    await tester.pumpAndSettle();
    expect(find.byType(LiquidDockNavi), findsOneWidget);
    expect(find.text('历史'), findsNothing);
    expect(widget().currentIndex, indexFor('我的'));

    // /downloads 没有目的地，回退未选中扁条（与消息页一致）。
    setOuterState(() => location = '/downloads');
    await tester.pumpAndSettle();
    expect(find.byType(LiquidDockNavi), findsNothing);
    expect(
      find.byKey(const ValueKey('workspace-bottom-navigation')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
