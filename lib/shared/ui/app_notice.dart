import 'dart:async';

import 'package:flutter/material.dart';

/// Shows one transient notice above the app's routes without blocking input.
///
/// Falls back to the nearest [ScaffoldMessenger] when no [AppNoticeHost] is
/// installed - an embedding that forgot the host should still tell the user
/// what happened instead of throwing out of the caller's tap handler.
void showAppNotice(BuildContext context, String message) {
  final host = context.findAncestorStateOfType<_AppNoticeHostState>();
  if (host != null) {
    host.show(message);
    return;
  }
  ScaffoldMessenger.maybeOf(context)
      ?.showSnackBar(SnackBar(content: Text(message)));
}

/// Install through MaterialApp.builder so dialogs and fullscreen share a host.
class AppNoticeHost extends StatefulWidget {
  const AppNoticeHost({super.key, required this.child});

  final Widget child;

  static Widget builder(BuildContext context, Widget? child) =>
      AppNoticeHost(child: child ?? const SizedBox.shrink());

  @override
  State<AppNoticeHost> createState() => _AppNoticeHostState();
}

class _AppNoticeHostState extends State<AppNoticeHost>
    with SingleTickerProviderStateMixin {
  static const _hold = Duration(milliseconds: 1500);
  static const _motion = Duration(milliseconds: 180);

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _motion,
    reverseDuration: const Duration(milliseconds: 160),
  );
  Timer? _holdTimer;
  String? _message;

  @override
  void initState() {
    super.initState();
    _controller.addStatusListener((status) {
      if (status == AnimationStatus.dismissed && mounted) {
        setState(() => _message = null);
      }
    });
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void show(String message) {
    _holdTimer?.cancel();
    final visible = _message != null && !_controller.isDismissed;
    setState(() => _message = message);
    if (visible || _reducedMotion) {
      // Re-showing replaces the text in place: replaying the entrance for
      // every notice in a burst reads as a strobe.
      _controller.value = 1;
    } else {
      _controller.forward(from: 0);
    }
    _holdTimer = Timer(_hold, retire);
  }

  /// Also the tap handler: dismissing early is the point of making it tappable.
  void retire() {
    _holdTimer?.cancel();
    if (_message == null) return;
    if (_reducedMotion) {
      setState(() => _message = null);
      return;
    }
    _controller.reverse();
  }

  bool get _reducedMotion => MediaQuery.disableAnimationsOf(context);

  @override
  Widget build(BuildContext context) {
    final message = _message;
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (message != null)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: Semantics(
                      liveRegion: true,
                      child: GestureDetector(
                        onTap: retire,
                        child: FadeTransition(
                          opacity: _controller,
                          child: SlideTransition(
                            position:
                                Tween(
                                  begin: const Offset(0, -.45),
                                  end: Offset.zero,
                                ).animate(
                                  CurvedAnimation(
                                    parent: _controller,
                                    curve: Curves.easeOutCubic,
                                  ),
                                ),
                            child: _GlassNoticeCard(message: message),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Dark glass, painted from fills rather than a [BackdropFilter]: this card
/// sits over scrolling feeds, and sampling the backdrop would re-record it on
/// every frame the user scrolls. The rim and body gradients carry the read.
class _GlassNoticeCard extends StatelessWidget {
  const _GlassNoticeCard({required this.message});

  final String message;

  static const _body = Color(0xE621252B);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [_body.withValues(alpha: .92), _body],
        ),
        border: Border.all(
          color: Colors.white.withValues(alpha: .26),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .34),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: Colors.white.withValues(alpha: .94),
            fontSize: 13,
            height: 1.4,
          ),
        ),
      ),
    );
  }
}
