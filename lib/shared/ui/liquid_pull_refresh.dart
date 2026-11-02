import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Pull-to-refresh whose ring closes as the pull completes, and only arms the
/// refresh once it is a full circle.
///
/// Material's `RefreshIndicator` cannot express this: during a drag its ring is
/// tweened to at most three quarters of a turn, and the distance that triggers a
/// refresh is a private constant. Here the sweep *is* the pull - no open arc
/// left means nothing was asked for - so releasing only refreshes when the ring
/// is shut, and pushing back unwinds it.
///
/// The ring follows the **pointer**, not the scroll deltas: on the home page a
/// pull-down first spends itself collapsing the header, and a scroll-delta
/// reading leaves the ring frozen exactly while the finger is doing the thing
/// the user meant. Tracking starts only when the gesture begins at the leading
/// edge, so scrolling through content never arms a refresh.
///
/// The disc is drawn as dark glass with layered fills and a lit rim rather than
/// a [BackdropFilter] or a blurred shadow: it repaints on every drag pixel, and
/// a per-frame blur costs exactly the frames this gesture needs to stay smooth
/// on the weakest runtime the app ships to.
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

  /// How far the finger has to travel downwards, in logical pixels, to close
  /// the ring.
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
const _retreatDuration = Duration(milliseconds: 180);

/// Dark slate body: it holds its own against a white feed and a night-mode
/// page alike, which a translucent white disc could not do on either.
const _discBody = Color(0xDD21252B);
const _check = Color(0xFF7BE38B);

class _LiquidPullRefreshState extends State<LiquidPullRefresh>
    with TickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );
  late final AnimationController _retreat = AnimationController(
    vsync: this,
    duration: _retreatDuration,
  );

  _Phase _phase = _Phase.idle;
  double _pulled = 0;

  /// What is painted: equal to the pull while the finger is down, and driven by
  /// [_retreat] on the way out. One value, one motion - a chase animation on
  /// top of a timed hide reads as two stages and stutters.
  double _drawn = 0;

  /// The pull height the retreat started from, so it can ease from there to 0.
  double? _retreatValue;

  double? _anchorY;
  ScrollMetrics? _metrics;
  Future<void>? _running;

  @override
  void initState() {
    super.initState();
    _retreat.addListener(_stepRetreat);
  }

  @override
  void dispose() {
    _retreat
      ..removeListener(_stepRetreat)
      ..dispose();
    _spin.dispose();
    super.dispose();
  }

  double get _progress =>
      (_pulled / widget.triggerDistance).clamp(0.0, 1.0).toDouble();

  /// No metrics yet means the page has never scrolled, i.e. it is at the top.
  bool _atLeadingEdge(ScrollMetrics? metrics) =>
      metrics == null ||
      switch (metrics.axisDirection) {
        AxisDirection.down => metrics.extentBefore == 0,
        AxisDirection.up => metrics.extentAfter == 0,
        _ => false,
      };

  bool _handleScroll(ScrollNotification notification) {
    if (widget.notificationPredicate(notification)) {
      _metrics = notification.metrics;
    }
    return false;
  }

  void _stepRetreat() {
    final from = _retreatValue;
    if (from == null) return;
    setState(() {
      _drawn = from * (1 - Curves.easeOutCubic.transform(_retreat.value));
      if (_drawn <= 0) _phase = _Phase.idle;
    });
  }

  void _onPointerDown(PointerDownEvent event) {
    if (_phase == _Phase.refreshing) return;
    _retreat.stop();
    _retreatValue = null;
    // The anchor is recorded wherever the gesture starts: a pull that begins
    // deeper in the list has not started pulling yet, and the anchor follows the
    // finger until the list runs out of scroll to give (see [_onPointerMove]).
    _anchorY = event.position.dy;
  }

  void _onPointerMove(PointerMoveEvent event) {
    final anchor = _anchorY;
    if (anchor == null || _phase == _Phase.refreshing) return;
    if (!_atLeadingEdge(_metrics)) {
      if (_pulled == 0 && _phase == _Phase.idle) {
        setState(() => _anchorY = event.position.dy);
      }
      return;
    }
    final travel = event.position.dy - anchor;
    if (travel <= 0 && _phase == _Phase.idle) return;
    setState(() {
      _pulled = math.max(0, travel);
      _drawn = _progress;
      _phase = _progress >= 1
          ? _Phase.armed
          : _progress > 0
          ? _Phase.dragging
          : _Phase.idle;
    });
  }

  /// A gesture that ends without the ring closed must still unwind: the pointer
  /// can be lifted, cancelled, or dragged off the widget's edge, and the last of
  /// those delivers no scroll notification at all.
  void _onPointerUp(PointerEvent event) {
    if (_anchorY == null) return;
    _anchorY = null;
    if (_phase == _Phase.armed) {
      _trigger();
    } else if (_phase != _Phase.idle) {
      _retreatToIdle();
    }
  }

  void _retreatToIdle() {
    if (MediaQuery.disableAnimationsOf(context)) {
      setState(() {
        _pulled = 0;
        _drawn = 0;
        _phase = _Phase.idle;
      });
      return;
    }
    _retreatValue = _drawn;
    _pulled = 0;
    _retreat
      ..value = 0
      ..forward();
  }

  Future<void> _trigger() async {
    if (_running != null) return;
    final pending = Future<void>(() => widget.onRefresh());
    _running = pending;
    setState(() {
      _phase = _Phase.refreshing;
      _drawn = 1;
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
    return Listener(
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerUp,
      child: NotificationListener<ScrollNotification>(
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
                      progress: _drawn,
                      phase: _phase,
                      spin: _spin,
                    ),
                  ),
                ),
              ),
          ],
        ),
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
    ).transform(Curves.easeOutCubic.transform(_drawn));
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
            armed: armed,
            sheen: Colors.white.withValues(alpha: 0.16),
            rim: Colors.white.withValues(alpha: 0.42),
            shadow: Colors.black.withValues(alpha: 0.42),
            track: Colors.white.withValues(alpha: 0.22),
            arc: armed ? _check : colors.primary,
            check: _check,
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
    required this.armed,
    required this.sheen,
    required this.rim,
    required this.shadow,
    required this.track,
    required this.arc,
    required this.check,
  });

  /// Null while a refresh runs: the arc then spins instead of following a pull.
  final double? progress;
  final double spin;
  final bool armed;
  final Color sheen;
  final Color rim;
  final Color shadow;
  final Color track;
  final Color arc;
  final Color check;

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
    canvas.drawCircle(center, radius, Paint()..color = _discBody);
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
          colors: [rim, rim.withValues(alpha: 0.10)],
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
    if (value != null && value > 0.03 && !armed) {
      _drawHeadArrow(canvas, center, ring.width / 2, start + sweepAngle, arc);
    }
    if (value != null && value >= 1) {
      _drawCheck(canvas, center, radius * 0.42, check);
    }
  }

  /// A chevron pointing along the direction of travel, so the open end of the
  /// ring reads as "keep going this way".
  void _drawHeadArrow(
    Canvas canvas,
    Offset center,
    double radius,
    double angle,
    Color color,
  ) {
    final size = _stroke * 1.9;
    canvas.save();
    canvas.translate(
      center.dx + radius * math.cos(angle),
      center.dy + radius * math.sin(angle),
    );
    canvas.rotate(angle + math.pi / 2);
    canvas.drawPath(
      Path()
        ..moveTo(0, size * 0.55)
        ..lineTo(-size * 0.45, -size * 0.45)
        ..lineTo(size * 0.45, -size * 0.45)
        ..close(),
      Paint()..color = color,
    );
    canvas.restore();
  }

  void _drawCheck(Canvas canvas, Offset center, double size, Color color) {
    // Two strokes, not a closed path: closing it draws a chord across the tick.
    canvas.drawPath(
      Path()
        ..moveTo(center.dx - size * 0.62, center.dy + size * 0.02)
        ..lineTo(center.dx - size * 0.16, center.dy + size * 0.5)
        ..lineTo(center.dx + size * 0.66, center.dy - size * 0.46),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.progress != progress ||
      old.spin != spin ||
      old.armed != armed ||
      old.arc != arc ||
      old.track != track ||
      old.rim != rim ||
      old.shadow != shadow ||
      old.sheen != sheen;
}
