import 'dart:async';

import 'package:bilisail/shared/ui/liquid_pull_refresh.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> mount(
    WidgetTester tester, {
    required Future<void> Function() onRefresh,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LiquidPullRefresh(
            onRefresh: onRefresh,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                for (var i = 0; i < 40; i++)
                  SizedBox(height: 60, child: Text('行 $i')),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Pulls and keeps the finger down. The ring only exists mid-gesture, so any
  /// helper that releases the pointer would already be back to idle when it
  /// returns.
  Future<TestGesture> pull(WidgetTester tester, double distance) async {
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(ListView)),
    );
    await gesture.moveBy(Offset(0, distance));
    await tester.pump();
    return gesture;
  }

  /// Releases and lets the overscroll spring-back finish: the scroll end - and
  /// therefore the trigger - arrives a few frames after the finger lifts.
  Future<void> lift(WidgetTester tester, TestGesture gesture) async {
    await gesture.up();
    for (var frame = 0; frame < 20; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  String? semanticsValue(WidgetTester tester) => tester
      .widgetList<Semantics>(find.byType(Semantics))
      .map((widget) => widget.properties.value)
      .where((value) => value != null && value != '')
      .cast<String>()
      .lastOrNull;

  testWidgets('a short pull reports an open ring and refreshes nothing', (
    tester,
  ) async {
    var calls = 0;
    await mount(tester, onRefresh: () async => calls++);
    final gesture = await pull(tester, 40);
    await tester.pump();
    expect(calls, 0);
    final value = semanticsValue(tester);
    expect(value, isNotNull);
    // The pull reads as the fraction still owed, so an early release is legible
    // before it happens rather than a spinner that hides the distance.
    expect(int.parse(value!.replaceAll('%', '')), inInclusiveRange(1, 99));
    await lift(tester, gesture);
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(semanticsValue(tester), isNull);
  });

  testWidgets('the ring closes at the trigger distance and arms the refresh', (
    tester,
  ) async {
    var calls = 0;
    final release = Completer<void>();
    await mount(
      tester,
      onRefresh: () {
        calls++;
        return release.future;
      },
    );
    final gesture = await pull(tester, 200);
    await tester.pump();
    expect(semanticsValue(tester), '松手刷新');
    expect(
      calls,
      0,
      reason: 'arming is not triggering: the finger is still down',
    );
    // The running ring spins on purpose, so `pumpAndSettle` would never settle;
    // `lift` advances a fixed number of frames instead, enough for the scroll
    // end to arrive and the trigger to fire.
    await lift(tester, gesture);
    expect(calls, 1);
    expect(semanticsValue(tester), '正在刷新');
    release.complete();
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(semanticsValue(tester), isNull);
  });

  testWidgets('pushing back up unwinds the ring and disarms it', (
    tester,
  ) async {
    var calls = 0;
    await mount(tester, onRefresh: () async => calls++);
    final gesture = await pull(tester, 200);
    expect(semanticsValue(tester), '松手刷新');
    // Travelling back must subtract: an absolute delta would keep winding the
    // ring up and arm a refresh the user just walked away from.
    await gesture.moveBy(const Offset(0, -120));
    await tester.pump();
    final value = semanticsValue(tester);
    expect(value, isNot('松手刷新'));
    expect(int.parse(value!.replaceAll('%', '')), inInclusiveRange(1, 99));
    await lift(tester, gesture);
    expect(calls, 0);
  });

  testWidgets('a gesture during a running refresh starts no second one', (
    tester,
  ) async {
    var calls = 0;
    final release = Completer<void>();
    await mount(
      tester,
      onRefresh: () {
        calls++;
        return release.future;
      },
    );
    final first = await pull(tester, 200);
    await lift(tester, first);
    expect(calls, 1);
    final second = await pull(tester, 200);
    await lift(tester, second);
    expect(calls, 1);
    release.complete();
    await tester.pumpAndSettle();
    expect(calls, 1);
  });

  testWidgets('reduce motion still refreshes and keeps the ring still', (
    tester,
  ) async {
    final release = Completer<void>();
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: MaterialApp(
          home: Scaffold(
            body: LiquidPullRefresh(
              onRefresh: () => release.future,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  for (var i = 0; i < 40; i++)
                    SizedBox(height: 60, child: Text('行 $i')),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    final gesture = await pull(tester, 200);
    await gesture.up();
    await tester.pump();
    expect(semanticsValue(tester), '正在刷新');
    release.complete();
    await tester.pumpAndSettle();
    expect(semanticsValue(tester), isNull);
  });
}
