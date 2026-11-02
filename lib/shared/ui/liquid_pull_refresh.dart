import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Pull-to-refresh whose ring closes as the pull completes, and only arms the
/// refresh once it is a full circle.
///
/// Material's `RefreshIndicator` cannot express this: during a drag its ring is
/// tweened to at most three quarters of a turn, and the distance that triggers a
/// refresh is a private constant. Here the sweep *is* the pull - no open arc
/// left means nothing was asked for - so releasing only refreshes when the ring
/// is shut, and releasing early springs back without a request.
///
/// The disc is drawn as frosted glass with layered fills and a lit rim rather
/// than a [BackdropFilter] or a blurred shadow: it repaints on every drag pixel,
/// and a per-frame blur costs exactly the frames this gesture needs to stay
/// smooth on the weakest runtime the app ships to.
class LiquidPullRefresh extends StatefulWidget {
  const LiquidPullRefresh({
    super.key,
    required this.onRefresh,
    required this.child,
    this.triggerDistance = 96,
    this.settleOffset = 40,
    this.edgeOffset = 0,
    this.notificationPredicate = defaultScrollNotificationPredicate,
    this.semanticsLabel = '下拉刷新',
  });

  final Future<void> Function() onRefresh;
  final Widget child;

  /// How far the finger has to pull, in logical pixels, to close the ring.
  final double triggerDistance;

  /// How far from the edge the disc rests while a refresh runs.
  final double settleOffset;

  /// How far below the top edge the disc starts counting from.
  final double edgeOffset;

  final ScrollNotificationPredicate notificationPredicate;
  final String semanticsLabel;

  @override
  State<LiquidPullRefresh> createState() => _LiquidPullRefreshState();
}

enum _Phase { idle, dragging, armed, refreshing }

const _diameter = 44.0;
const _stroke = 3.0;

class _LiquidPullRefreshState extends State<LiquidPullRefresh>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  _Phase _phase = _Phase.idle;
  double _pulled = 0;
  Future<void>? _running;

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  /// 0 while the pull is still short, 1 once the ring is shut.
  double get _progress =>
      (_pulled / widget.triggerDistance).clamp(0.0, 1.0).toDouble();

  bool _atLeadingEdge(ScrollMetrics metrics) => switch (metrics.axisDirection) {
    AxisDirection.down => metrics.extentBefore == 0,
    AxisDirection.up => metrics.extentAfter == 0,
    _ => false,
  };

  bool _handleScroll(ScrollNotification notification) {
    if (!widget.notificationPredicate(notification)) return false;
    // A running refresh owns the indicator; a second gesture must not fight it.
    if (_phase == _Phase.refreshing) return false;
    if (notification is OverscrollNotification &&
        notification.dragDetails != null &&
        _atLeadingEdge(notification.metrics)) {
      // Raw finger travel, undamped: [triggerDistance] is the distance the user
      // actually pulls, not a fraction of it.
      setState(() {
        _pulled += notification.overscroll.abs();
        _phase = _progress >= 1 ? _Phase.armed : _Phase.dragging;
      });
    } else if (notification is ScrollEndNotification && _phase != _Phase.idle) {
      // Handled before the drag-details gate: a fling ends without them, and
      // leaving the ring half drawn would strand the indicator on screen.
      if (_phase == _Phase.armed) {
        _trigger();
      } else {
        setState(() {
          _pulled = 0;
          _phase = _Phase.idle;
        });
      }
    }
    return false;
  }

  Future<void> _trigger() async {
    if (_running != null) return;
    final pending = Future<void>(() => widget.onRefresh());
    _running = pending;
    setState(() {
      _phase = _Phase.refreshing;
      _pulled = widget.triggerDistance;
    });
    if (!MediaQuery.disableAnimationsOf(context)) {
      _spin.repeat();
    }
    try {
      await pending;
    } finally {
      // A newer refresh, or a detached tree, owns the indicator now.
      if (_running == pending) {
        _running = null;
        _spin.stop();
        if (mounted) {
          setState(() {
            _phase = _Phase.idle;
            _pulled = 0;
          });
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: _handleScroll,
      child: Stack(
        children: [
          widget.child,
          if (_phase != _Phase.idle)
            Positioned(
              top: _discTop(),
              left: 0,
              right: 0,
              child: Center(
                child: Semantics(
                  label: widget.semanticsLabel,
                  value: switch (_phase) {
                    _Phase.armed => '松手刷新',
                    _Phase.refreshing => '正在刷新',
                    _ => '${(_progress * 100).round()}%',
                  },
                  child: _GlassRing(
                    progress: _progress,
                    phase: _phase,
                    spin: _spin,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Rides in from above the edge as the pull grows and lands on
  /// [LiquidPullRefresh.settleOffset] exactly when the ring closes, so arming
  /// does not move the disc.
  double _discTop() {
    final settled = widget.edgeOffset + widget.settleOffset - _diameter / 2;
    if (_phase == _Phase.refreshing || _phase == _Phase.armed) return settled;
    return Tween(
      begin: widget.edgeOffset - _diameter / 2,
      end: settled,
    ).transform(Curves.easeOutCubic.transform(_progress));
  }
}

class _GlassRing extends StatelessWidget {
  const _GlassRing({
    required this.progress,
    required this.phase,
    required this.spin,
  });

  final double progress;
  final _Phase phase;

  /// Drives the travelling arc while a refresh runs. A drag repaints from its
  /// own [State.setState], so it never subscribes to this animation.
  final Animation<double> spin;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final spinning = phase == _Phase.refreshing;
    return SizedBox(
      width: _diameter,
      height: _diameter,
      child: AnimatedBuilder(
        animation: spinning ? spin : kAlwaysCompleteAnimation,
        builder: (context, _) => CustomPaint(
          painter: _RingPainter(
            progress: spinning ? null : progress,
            spin: spinning ? spin.value : 0,
            track: (dark ? Colors.white : Colors.black).withValues(alpha: 0.16),
            arc: phase == _Phase.armed ? colors.tertiary : colors.primary,
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.progress,
    required this.spin,
    required this.track,
    required this.arc,
  });

  /// Null while a refresh runs: the arc then spins instead of following a pull.
  final double? progress;
  final double spin;
  final Color track;
  final Color arc;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width / 2 - _stroke;
    final disc = Rect.fromCircle(center: center, radius: radius + 4);
    canvas.drawCircle(
      center,
      radius + 4,
      Paint()
        ..shader = RadialGradient(
          center: Alignment.topLeft,
          colors: [
            Colors.white.withValues(alpha: 0.30),
            Colors.white.withValues(alpha: 0.10),
          ],
        ).createShader(disc),
    );
    canvas.drawCircle(
      center,
      radius + 4,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Colors.white.withValues(alpha: 0.38),
    );
    final ring = Rect.fromCircle(center: center, radius: radius);
    canvas.drawCircle(
      ring.center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _stroke
        ..color = track,
    );
    final value = progress;
    // A refresh shows a quarter turn travelling round; a pull shows exactly the
    // fraction of the ring the finger has earned.
    final sweepAngle = value == null ? math.pi / 2 : value * math.pi * 2;
    final start = value == null
        ? spin * math.pi * 2 - math.pi / 2
        : -math.pi / 2;
    canvas.drawArc(
      ring,
      start,
      sweepAngle,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _stroke
        ..strokeCap = StrokeCap.round
        ..color = arc,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.progress != progress ||
      old.spin != spin ||
      old.arc != arc ||
      old.track != track;
}
