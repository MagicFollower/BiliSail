import 'dart:async';

/// Video outputs that still hold a native Android window.
const androidActiveVideoOutputs = {'gpu', 'gpu-next'};

/// Releases the Android video output in the order the native plugin cannot.
///
/// The pinned plugin frees `android.view.Surface` and its texture entry inside
/// `Player.dispose()`, while libmpv destroys its own video output on the core
/// thread and `mpv_terminate_destroy` runs later on an unawaitable timer. Both
/// sides then rely on independently hard-coded delays. This sequence replaces
/// that guess with the two facts the application can actually observe: the
/// texture has left the element tree, and the core no longer reports a GPU
/// output. Nothing here is fatal — every step is bounded and a miss only falls
/// back to the previous behaviour, because the caller still disposes the player.
///
/// Returns whether libmpv was observed to drop its output, so the caller can
/// tell a confirmed hand-over from a timed-out one. Nothing here is fatal and
/// the caller always proceeds to dispose the player afterwards.
Future<bool> releaseAndroidOutput({
  required Future<void> Function() detachSurface,
  required Future<void> Function() stop,
  required Future<String?> Function() readCurrentOutput,
  required Future<void> Function(Duration delay) wait,
  Duration stopBudget = const Duration(seconds: 3),
  Duration releaseBudget = const Duration(milliseconds: 600),
  Duration poll = const Duration(milliseconds: 20),
  Set<String> activeOutputs = androidActiveVideoOutputs,
  void Function(String stage)? onStage,
}) async {
  await detachSurface();

  try {
    await stop().timeout(stopBudget);
  } on Object {
    onStage?.call('stop');
  }

  var waited = Duration.zero;
  while (waited < releaseBudget) {
    final String? output;
    try {
      output = await readCurrentOutput();
    } on Object {
      onStage?.call('read');
      return false;
    }
    if (output == null || !activeOutputs.contains(output)) return true;
    await wait(poll);
    waited += poll;
  }
  onStage?.call('output');
  return false;
}
