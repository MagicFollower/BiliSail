import 'dart:async';

import 'package:bili_player/src/android_output_release.dart';
import 'package:flutter_test/flutter_test.dart';

/// Drives the coordinator without a native player: every native touch point is
/// an injected closure, so the required order, each bounded escape hatch and the
/// confirmation the caller depends on are observable as an event log.
void main() {
  final stalls = <String>[];

  tearDown(() => stalls.clear());

  test(
    'detaches the surface, then stops the core, then reads the output',
    () async {
      final events = <String>[];
      final released = await releaseAndroidOutput(
        detachSurface: () async => events.add('detach'),
        stop: () async => events.add('stop'),
        readCurrentOutput: () async {
          events.add('read');
          return 'null';
        },
        wait: (delay) async => events.add('wait'),
        activeOutputs: const {'gpu', 'gpu-next'},
      );
      expect(events, ['detach', 'stop', 'read']);
      expect(released, isTrue);
    },
  );

  test('keeps polling until the core drops its gpu output', () async {
    final outputs = ['gpu', 'gpu', 'null'].iterator;
    final reads = <String>[];
    var waits = 0;
    final released = await releaseAndroidOutput(
      detachSurface: () async {},
      stop: () async {},
      readCurrentOutput: () async {
        outputs.moveNext();
        reads.add(outputs.current);
        return outputs.current;
      },
      wait: (_) async => waits++,
      releaseBudget: const Duration(milliseconds: 60),
      poll: const Duration(milliseconds: 20),
    );
    expect(reads, ['gpu', 'gpu', 'null']);
    expect(waits, 2);
    expect(released, isTrue);
  });

  test('a stuck core still reaches the output check', () async {
    final events = <String>[];
    final released = await releaseAndroidOutput(
      detachSurface: () async => events.add('detach'),
      stop: () => Completer<void>().future,
      readCurrentOutput: () async {
        events.add('read');
        return 'null';
      },
      wait: (_) async => events.add('wait'),
      stopBudget: const Duration(milliseconds: 5),
      onStage: stalls.add,
    );
    expect(events, ['detach', 'read']);
    expect(stalls, ['stop']);
    expect(released, isTrue);
  });

  test(
    'an output the core never releases bounds the wait and reports unconfirmed',
    () async {
      var reads = 0;
      var waits = 0;
      final released = await releaseAndroidOutput(
        detachSurface: () async {},
        stop: () async {},
        readCurrentOutput: () async {
          reads++;
          return 'gpu-next';
        },
        wait: (_) async => waits++,
        releaseBudget: const Duration(milliseconds: 60),
        poll: const Duration(milliseconds: 20),
        onStage: stalls.add,
      );
      expect(reads, 3);
      expect(waits, 3);
      expect(stalls, ['output']);
      // Unconfirmed: the caller must leave the parked surface to the plugin's
      // fallback instead of retiring it while libmpv may still own it.
      expect(released, isFalse);
    },
  );

  test('an unreadable output is not retried', () async {
    var reads = 0;
    final released = await releaseAndroidOutput(
      detachSurface: () async {},
      stop: () async {},
      readCurrentOutput: () async {
        reads++;
        throw StateError('disposed');
      },
      wait: (_) async {},
      onStage: stalls.add,
    );
    expect(reads, 1);
    expect(stalls, ['read']);
    expect(released, isFalse);
  });

  test('a surface detach is awaited before the core is touched', () async {
    final gate = Completer<void>();
    var stopped = false;
    final pending = releaseAndroidOutput(
      detachSurface: () => gate.future,
      stop: () async => stopped = true,
      readCurrentOutput: () async => 'null',
      wait: (_) async {},
    );
    await Future<void>.delayed(Duration.zero);
    expect(stopped, isFalse);
    gate.complete();
    expect(await pending, isTrue);
    expect(stopped, isTrue);
  });
}
