import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Pull-to-refresh whose ring closes as the pull completes, and only arms the
/// refresh once it is a full circle.
///
/// Material's `RefreshIndicator` cannot express this: during a drag its ring is
/// tweened to at most three quarters of a turn, and the distance that triggers a
/// refresh is a private constant. Here the sweep *is* the pull - no open arc
/// left means nothing was asked for - so releasing only refreshes when the ring
/// is shut, and pushing back up unwinds it.
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
    this.triggerDistance = 140,
    this.settleOffset = 44,
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

const _diameter = 46.0;
const _stroke = 3.5;

/// How long the drawn ring takes to catch up with the finger. Short enough to
/// stay under the fingertip, long enough that a fast flick reads as travel
/// rather than a stack of snapshots.
const _follow = Duration(milliseconds: 110);

class _LiquidPullRefreshState extends State<LiquidPullRefresh>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  _Phase _phase = _Phase.idle;
  double _pulled = 0;
  Future<void>? _running;
  Timer? _retreat;

  @override
  void dispose() {
    _retreat?.cancel();
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

  /// Signed travel toward or away from closing the ring, on either channel a
  /// gesture arrives through: the overscroll delta while the list is pinned at
  /// its edge, and the scroll delta once the finger pushes it away from that
  /// edge. Both follow the axis the way `RefreshIndicator` reads it - on a
  /// downward list a pull-down delta arrives negative - so pushing back up
  /// unwinds the ring instead of winding it further.
  double _travel(AxisDirection axis, double delta) => switch (axis) {
    AxisDirection.down => -delta,
    AxisDirection.up => delta,
    _ => 0,
  };

  void _addTravel(double travel) {
    final next = math.max(0.0, _pulled + travel);
    if (next == _pulled) return;
    setState(() {
      _pulled = next;
      _phase = _progress >= 1 ? _Phase.armed : _Phase.dragging;
    });
  }

  bool _handleScroll(ScrollNotification notification) {
    if (!widget.notificationPredicate(notification)) return false;
    // A running refresh owns the indicator; a second gesture must not fight it.
    if (_phase == _Phase.refreshing) return false;
    if (notification is OverscrollNotification &&
        notification.dragDetails != null &&
        _atLeadingEdge(notification.metrics)) {
      // Undamped finger travel: [triggerDistance] is the distance the user
      // actually pulls, not a fraction of it.
      _addTravel(
        _travel(notification.metrics.axisDirection, notification.overscroll),
      );
    } else if (notification is ScrollUpdateNotification &&
        notification.dragDetails != null &&
        _phase != _Phase.idle &&
        notification.scrollDelta != null) {
      // Deliberately not gated on the leading edge: pushing back from a partial
      // pull scrolls the list normally, and that displacement is what should
      // take the ring back down.
      _addTravel(
        _travel(notification.metrics.axisDirection, notification.scrollDelta!),
      );
    } else if (notification is ScrollEndNotification && _phase != _Phase.idle) {
      // Handled before the drag-details gate: a fling ends without them, and
      // leaving the ring half drawn would strand the indicator on screen.
      if (_phase == _Phase.armed) {
        _trigger();
      } else {
        _retreatToIdle();
      }
    }
    return false;
  }

  /// Lets the ring unwind on screen instead of vanishing at the release point.
  void _retreatToIdle() {
    setState(() {
      _pulled = 0;
      _phase = _Phase.dragging;
    });
    _retreat?.cancel();
    _retreat = Timer(_follow * 2, () {
      if (!mounted) return;
      setState(() => _phase = _Phase.idle);
    });
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
        if (mounted) _retreatToIdle();
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
            // The drawn ring chases the finger over a short ease; the semantics
            // still report the real pull, not the smoothed value.
            TweenAnimationBuilder(
              tween: Tween(begin: 0.0, end: _progress),
              duration: _follow,
              curve: Curves.easeOutCubic,
              builder: (context, drawn, _) => Positioned(
                top: _discTop(drawn),
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
                      progress: drawn,
                      phase: _phase,
                      spin: _spin,
                    ),
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
  double _discTop(double drawn) {
    final settled = widget.edgeOffset + widget.settleOffset - _diameter / 2;
    if (_phase == _Phase.refreshing || _phase == _Phase.armed) return settled;
    return Tween(
      begin: widget.edgeOffset - _diameter / 2,
      end: settled,
    ).transform(Curves.easeOutCubic.transform(drawn));
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
    final armed = phase == _Phase.armed;
    return SizedBox(
      width: _diameter,
      height: _diameter,
      child: AnimatedBuilder(
        animation: spinning ? spin : kAlwaysCompleteAnimation,
        builder: (context, _) => CustomPaint(
          painter: _RingPainter(
            progress: spinning ? null : progress,
            spin: spinning ? spin.value : 0,
            // A body that opposes the page behind it is what makes the disc read
            // as glass at all: a white sheen over a light feed disappears.
            body: dark
                ? Colors.white.withValues(alpha: 0.24)
                : Colors.black.withValues(alpha: 0.46),
            sheen: Colors.white.withValues(alpha: dark ? 0.26 : 0.38),
            rim: Colors.white.withValues(alpha: dark ? 0.55 : 0.88),
            shadow: Colors.black.withValues(alpha: dark ? 0.50 : 0.30),
            track: (dark ? Colors.white : Colors.black).withValues(alpha: 0.34),
            arc: armed ? colors.tertiaryContainer : colors.primary,
            head: armed ? colors.onTertiaryContainer : colors.primary,
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
    required this.body,
    required this.sheen,
    required this.rim,
    required this.shadow,
    required this.track,
    required this.arc,
    required this.head,
  });

  /// Null while a refresh runs: the arc then spins instead of following a pull.
  final double? progress;
  final double spin;
  final Color body;
  final Color sheen;
  final Color rim;
  final Color shadow;
  final Color track;
  final Color arc;
  final Color head;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width / 2 - _stroke - 1;
    final disc = Rect.fromCircle(center: center, radius: radius);
    // Contact shadow as a gradient halo: a blurred circle would cost a
    // saveLayer on every frame the finger moves.
    canvas.drawCircle(
      center,
      radius + 5,
      Paint()
        ..shader = RadialGradient(
          colors: [shadow, shadow.withValues(alpha: 0)],
          stops: const [0.72, 1.0],
        ).createShader(Rect.fromCircle(center: center, radius: radius + 5)),
    );
    canvas.drawCircle(center, radius, Paint()..color = body);
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.7, -0.8),
          colors: [sheen, sheen.withValues(alpha: 0)],
          stops: const [0.0, 0.85],
        ).createShader(disc),
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [rim, rim.withValues(alpha: 0.12)],
        ).createShader(disc),
    );
    final ring = Rect.fromCircle(center: center, radius: radius - _stroke);
    canvas.drawCircle(
      ring.center,
      ring.width / 2,
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
    if (value != null && value > 0.02) {
      // A lit head keeps the leading edge readable over any page colour.
      final r = ring.width / 2;
      canvas.drawCircle(
        Offset(
          center.dx + r * math.cos(start + sweepAngle),
          center.dy + r * math.sin(start + sweepAngle),
        ),
        _stroke * 0.85,
        Paint()..color = head,
      );
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.progress != progress ||
      old.spin != spin ||
      old.arc != arc ||
      old.head != head ||
      old.track != track ||
      old.body != body ||
      old.rim != rim ||
      old.shadow != shadow ||
      old.sheen != sheen;
}
