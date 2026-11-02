import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Pull-to-refresh whose ring closes as the pull completes, and only arms the
/// refresh once it is a full circle.
///
/// Material's `RefreshIndicator` cannot express this: during a drag its ring is
/// tweened to at most three quarters of a turn, and the distance that triggers a
/// refresh is a private constant. Here the sweep *is* the pull - no open arc
/// left means nothing was asked for - so releasing only refreshes when the ring
/// is shut.
///
/// The ring follows the **pointer**, not the scroll deltas: on the home page a
/// pull-down first spends itself collapsing the header, and a scroll-delta
/// reading leaves the ring frozen exactly while the finger is doing the thing
/// the user meant. Tracking starts only when the gesture begins at the leading
/// edge, so scrolling through content never arms a refresh.
///
/// Progress ratchets. Moving back up does not unwind the ring, because a pull
/// that has to be judged twice - once going down, once coming back - reads as
/// the indicator fighting the finger. What the ring reached is what releasing
/// gets.
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

/// Dark slate body: it holds its own against a white feed and a night-mode
/// page alike, which a translucent white disc could not do on either.
const _discBody = Color(0xDD21252B);

/// Both the earned arc and the tick that replaces it, so "how much is left"
/// and "this is enough" are the same colour.
const _green = Color(0xFF7BE38B);

class _LiquidPullRefreshState extends State<LiquidPullRefresh>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  _Phase _phase = _Phase.idle;
  double _pulled = 0;
  double? _anchorY;
  ScrollMetrics? _metrics;
  Future<void>? _running;

  @override
  void dispose() {
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

  void _onPointerDown(PointerDownEvent event) {
    if (_phase == _Phase.refreshing) return;
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
      _pulled = math.max(_pulled, travel);
      _phase = _progress >= 1
          ? _Phase.armed
          : _progress > 0
          ? _Phase.dragging
          : _Phase.idle;
    });
  }

  /// A gesture that ends without the ring closed must still clear: the pointer
  /// can be lifted, cancelled, or dragged off the widget's edge, and the last of
  /// those delivers no scroll notification at all.
  void _onPointerUp(PointerEvent event) {
    if (_anchorY == null) return;
    _anchorY = null;
    if (_phase == _Phase.armed) {
      _trigger();
    } else if (_phase != _Phase.idle) {
      _reset();
    }
  }

  void _reset() {
    setState(() {
      _pulled = 0;
      _phase = _Phase.idle;
    });
  }

  Future<void> _trigger() async {
    if (_running != null) return;
    final pending = Future<void>(() => widget.onRefresh());
    _running = pending;
    setState(() => _phase = _Phase.refreshing);
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
        if (mounted) _reset();
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
                      progress: _phase == _Phase.refreshing ? null : _progress,
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
    ).transform(Curves.easeOutCubic.transform(_progress));
  }
}

class _GlassRing extends StatelessWidget {
  const _GlassRing({required this.progress, required this.spin});

  /// Null while a refresh runs: the arc then travels instead of following a pull.
  final double? progress;

  /// Drives the travelling arc. A drag repaints from its own [State.setState],
  /// so it never subscribes to this animation.
  final Animation<double> spin;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _diameter,
      height: _diameter,
      child: AnimatedBuilder(
        animation: progress == null ? spin : kAlwaysCompleteAnimation,
        builder: (context, _) => CustomPaint(
          painter: _RingPainter(
            progress: progress,
            spin: progress == null ? spin.value : 0,
            sheen: Colors.white.withValues(alpha: 0.16),
            rim: Colors.white.withValues(alpha: 0.42),
            shadow: Colors.black.withValues(alpha: 0.42),
            track: Colors.white.withValues(alpha: 0.22),
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
    required this.sheen,
    required this.rim,
    required this.shadow,
    required this.track,
  });

  final double? progress;
  final double spin;
  final Color sheen;
  final Color rim;
  final Color shadow;
  final Color track;

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
    canvas.drawArc(
      ring,
      value == null ? spin * math.pi * 2 - math.pi / 2 : -math.pi / 2,
      value == null ? math.pi / 2 : value * math.pi * 2,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _stroke
        ..strokeCap = StrokeCap.round
        ..color = _green,
    );
    if (value != null && value >= 1) {
      _drawCheck(canvas, center, radius * 0.42);
    }
  }

  void _drawCheck(Canvas canvas, Offset center, double size) {
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
        ..color = _green,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.progress != progress ||
      old.spin != spin ||
      old.track != track ||
      old.rim != rim ||
      old.shadow != shadow ||
      old.sheen != sheen;
}
