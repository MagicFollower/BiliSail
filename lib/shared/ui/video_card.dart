import '../../domain/user.dart';
import 'bili_icons.dart';
import 'app_cover_image.dart';
import 'bili_badges.dart';
import 'highlighted_text.dart';
import 'video_card_cover.dart';
import 'video_card_interaction_scope.dart';
import 'video_card_surface.dart';
import 'scroll_aware_hover_region.dart';
import 'video_card_feedback.dart';
import 'text_measurement_cache.dart';
export 'video_card_feedback.dart' show VideoCardFeedback;
import '../../features/video/domain/video_card_interactions.dart';
import '../../core/presentation/workspace_activity.dart';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show listEquals;

import '../../domain/video.dart';

String compactCount(int? count) {
  if (count == null) return '—';
  if (count >= 100000000) return '${(count / 100000000).toStringAsFixed(1)}亿';
  if (count >= 10000) return '${(count / 10000).toStringAsFixed(1)}万';
  return '$count';
}

String compactCountLabel(int? count, String text) {
  final value = text.trim();
  if (value.isEmpty) {
    return compactCount(count);
  }
  // Keep server-provided abbreviations; format decimal count text locally.
  final numericCount = int.tryParse(value, radix: 10);
  return numericCount == null ? text : compactCount(numericCount);
}

String durationLabel(Duration duration) {
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
}

enum VideoCardMenuAction {
  notInterested,
  watchLater,
  removeWatchLater,
  removeHistory,
}

final class VideoCardMenu {
  const VideoCardMenu({
    required this.actions,
    this.onSelected,
    this.busy = false,
  });
  final List<VideoCardMenuAction> actions;
  final ValueChanged<VideoCardMenuAction>? onSelected;
  final bool busy;
}

enum _VideoCardWidthTier {
  compact(10, 20, 14),
  medium(11, 24, 17),
  regular(12, 28, 20);

  const _VideoCardWidthTier(
    this.coverFontSize,
    this.menuButtonSize,
    this.menuIconSize,
  );

  final double coverFontSize;
  final double menuButtonSize;
  final double menuIconSize;

  static _VideoCardWidthTier fromWidth(double cardWidth) => switch (cardWidth) {
    < 180 => compact,
    < 240 => medium,
    _ => regular,
  };
}

final class VideoCard extends StatefulWidget {
  const VideoCard({
    super.key,
    required this.video,
    required this.onTap,
    this.progress,
    this.onOpenUser,
    this.showUpBadge = false,
    this.showRecommendationReason = false,
    this.highlightQuery = '',
    this.playCountText = '',
    this.danmakuCountText = '',
    this.publishText = '',
    this.publishTooltip,
    this.menu,
    this.feedback,
    this.showWatchLaterButton = true,
  });

  final ValueChanged<UserId>? onOpenUser;
  final VideoSummary video;
  final VoidCallback onTap;
  final double? progress;
  final bool showUpBadge;
  final bool showRecommendationReason;
  final String highlightQuery;
  // Counts may arrive as decimal text or server-provided abbreviations.
  final String playCountText;
  final String danmakuCountText;
  final String publishText;
  final String? publishTooltip;
  final VideoCardMenu? menu;
  final VideoCardFeedback? feedback;
  final bool showWatchLaterButton;

  // Home/history mappings may recreate a summary without changing its content.
  // Compare everything consumed by this card and its preview, not callbacks:
  // actions forward through State to the current page/query and queue.
  Object get _content => (
    video.id,
    video.title,
    video.coverUrl,
    video.author,
    video.duration,
    video.playCount,
    video.danmakuCount,
    video.publishedAt,
    video.authorAvatarUrl,
    video.authorId,
    video.recommendationReason,
    video.isFollowed,
    video.previewCid,
    video.access.kind,
    video.access.canWatch,
    video.access.canPreview,
    progress,
    onOpenUser != null,
    showUpBadge,
    showRecommendationReason,
    highlightQuery,
    playCountText,
    danmakuCountText,
    publishText,
    publishTooltip,
    showWatchLaterButton,
    menu != null,
    menu?.busy,
    menu?.onSelected != null,
    feedback != null,
    feedback?.busy,
    feedback?.onUndo != null,
  );

  @override
  State<VideoCard> createState() => _VideoCardState();
}

final class _VideoCardState extends State<VideoCard> {
  static const _titleFontSize = 15.0;

  bool _hovered = false;
  bool _focused = false;
  bool _authorHovered = false;
  bool _menuFocused = false;
  bool _menuOpen = false;
  bool _addingWatchLater = false;
  int _addGeneration = 0;
  VideoCardInteractions? _interactions;
  Widget? _card;
  final _menuAnchor = GlobalKey();

  bool get _canShowMenu => switch (widget.menu) {
    final menu? =>
      widget.feedback == null &&
          !menu.busy &&
          menu.actions.isNotEmpty &&
          !_addingWatchLater,
    null => false,
  };

  void _update(VoidCallback change) => setState(() {
    _card = null;
    change();
  });

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _card = null;
    final interactions = VideoCardInteractionScope.maybeOf(context)
        ?.interactions;
    if (_interactions != interactions) {
      _interactions = interactions;
      _addGeneration++;
      _addingWatchLater = false;
    }
  }

  @override
  void didUpdateWidget(VideoCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget._content != oldWidget._content ||
        !listEquals(widget.menu?.actions, oldWidget.menu?.actions)) {
      _card = null;
    }
    if (widget.video.id != oldWidget.video.id) {
      _addGeneration++;
      _addingWatchLater = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    // The card itself is built inside a LayoutBuilder, whose builder context is
    // not this element's, so a theme change would otherwise leave the cached
    // card painted with the previous theme - the liquid-card setting toggling in
    // the settings tab would not reach the boards already on screen.
    Theme.of(context);
    return _card ??= LayoutBuilder(
      builder: (context, constraints) =>
          _buildCard(context, constraints.maxWidth),
    );
  }

  Widget _buildCard(BuildContext context, double cardWidth) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final video = widget.video;
    final playLabel = compactCountLabel(video.playCount, widget.playCountText);
    final danmakuLabel = compactCountLabel(
      video.danmakuCount,
      widget.danmakuCountText,
    );
    final textScaler = MediaQuery.textScalerOf(context);
    final surface = videoCardSurfaceOf(context);
    final glass = surface.enabled;
    // The board insets the content, so the typography step follows the room the
    // text actually has rather than the card box: a 250 board writes on 234, and
    // sizing from 250 would set more characters into a narrower line than the
    // flat card at 234 - which is how a title that used to fit two lines starts
    // ellipsizing.
    final textWidth = cardWidth - surface.inset * 2;
    final titleStyle = theme.textTheme.bodyMedium?.copyWith(
      fontSize: glass ? surface.titleFor(textWidth) : _titleFontSize,
      fontWeight: FontWeight.w500,
      height: 1.4,
    );
    final highlighted = (_hovered || _focused) && !_authorHovered;
    final progress = widget.progress;
    // The board's inner corner. `Material` takes it for its shape, and the ink
    // needs it explicitly: `InkResponse` reads its *own* `borderRadius` when it
    // clips a splash or ripple and never falls back to the parent `Material`'s,
    // so without this the press highlight is a rectangle inside a rounded board.
    final boardRadius = BorderRadius.circular(
      glass ? surface.cardRadius - 1 : 7,
    );
    return ScrollAwareHoverRegion(
      onHover: (hovered) => _update(() => _hovered = hovered),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: _boardDecoration(surface, scheme, glass),
        child: Material(
          color: Colors.transparent,
          borderRadius: boardRadius,
          clipBehavior: Clip.none,
          child: InkWell(
            borderRadius: boardRadius,
            onTap: widget.feedback == null ? () => widget.onTap() : null,
            onLongPress: widget.feedback == null ? _showMenu : null,
            hoverColor: Colors.transparent,
            hoverDuration: Duration.zero,
            onFocusChange: (value) => _update(() => _focused = value),
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                surface.inset,
                surface.inset,
                surface.inset,
                surface.bottomGap,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AspectRatio(
                    aspectRatio: 16 / 9,
                    child: switch (widget.feedback) {
                      final feedback? => VideoCardFeedbackCover(
                        feedback: VideoCardFeedback(
                          busy: feedback.busy,
                          onUndo: feedback.onUndo == null
                              ? null
                              : () => widget.feedback?.onUndo?.call(),
                        ),
                        background: video.coverUrl.isEmpty
                            ? _coverFallback(context)
                            : AppCoverImage(
                                url: video.coverUrl,
                                fit: BoxFit.cover,
                                errorBuilder: (_, _, _) =>
                                    _coverFallback(context),
                              ),
                      ),
                      null => VideoCardCover(
                        video: video,
                        // The board is 16 and the cover sits 8 inside it, so 8
                        // keeps the two corners concentric rather than fighting.
                        borderRadius: surface.coverRadius,
                        showWatchLaterButton: widget.showWatchLaterButton,
                        focused: _focused,
                        hovered: _hovered,
                        // VideoCardCover clips the complete cover and overlays.
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            if (video.coverUrl.isNotEmpty)
                              AppCoverImage(
                                url: video.coverUrl,
                                fit: BoxFit.cover,
                                excludeFromSemantics: true,
                                errorBuilder: (_, _, _) =>
                                    _coverFallback(context),
                                frameBuilder: (_, child, frame, _) =>
                                    frame != null
                                    ? child
                                    : _coverFallback(context),
                              )
                            else
                              _coverFallback(context),
                            Align(
                              alignment: Alignment.bottomCenter,
                              child: SizedBox(
                                width: double.infinity,
                                height: textScaler.scale(36) + 20,
                                child: const DecoratedBox(
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [
                                        Colors.transparent,
                                        Color(0xC4000000),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            Positioned(
                              left: 7,
                              right: 7,
                              bottom: 7,
                              child: Semantics(
                                label: glass
                                    ? '时长 ${durationLabel(video.duration)}'
                                    : '观看 $playLabel，'
                                          '弹幕 $danmakuLabel，'
                                          '时长 ${durationLabel(video.duration)}',
                                excludeSemantics: true,
                                child: _CoverMetadata(
                                  video: video,
                                  cardWidth: textWidth,
                                  playLabel: playLabel,
                                  danmakuLabel: danmakuLabel,
                                  // On the glass board the counts move into the
                                  // card's own meta line; the cover keeps only
                                  // the duration, which belongs to the image.
                                  showCounts: !glass,
                                ),
                              ),
                            ),
                            if (progress != null)
                              Align(
                                alignment: Alignment.bottomLeft,
                                child: LinearProgressIndicator(
                                  value: progress.clamp(0.0, 1.0),
                                  minHeight: 3,
                                  backgroundColor: Colors.transparent,
                                ),
                              ),
                          ],
                        ),
                      ),
                    },
                  ),
                  SizedBox(height: surface.titleGap),
                  _titleBlock(
                    glass: glass,
                    surface: surface,
                    textWidth: textWidth,
                    titleStyle: titleStyle,
                    titleColor: highlighted ? scheme.primary : scheme.onSurface,
                  ),
                  SizedBox(height: surface.metaGap),
                  _AuthorMetadata(
                    video: video,
                    merged: glass,
                    metaFontSize: surface.metaFor(textWidth),
                    playLabel: playLabel,
                    danmakuLabel: danmakuLabel,
                    onOpenUser: widget.feedback == null
                        ? widget.onOpenUser == null
                              ? null
                              : (id) => widget.onOpenUser?.call(id)
                        : null,
                    hovered: _authorHovered,
                    onHover: (value) => _update(() => _authorHovered = value),
                    showUpBadge: widget.showUpBadge,
                    reason: widget.showRecommendationReason
                        ? video.recommendationReason
                        : null,
                    showFollowed:
                        widget.showRecommendationReason &&
                        video.isFollowed == true,
                    publishText: widget.publishText,
                    publishTooltip: widget.publishTooltip,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The board under the card. Painted from a translucent body gradient, one
  /// lit hairline and a shadow — no `BackdropFilter`, because a grid would
  /// sample the backdrop for every visible card on every scrolled frame. The
  /// flat card keeps its focus-only hairline.
  BoxDecoration _boardDecoration(
    VideoCardSurface surface,
    ColorScheme scheme,
    bool glass,
  ) {
    if (!glass) {
      return BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: _focused ? scheme.primary : Colors.transparent,
        ),
      );
    }
    return BoxDecoration(
      borderRadius: BorderRadius.circular(surface.cardRadius),
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [surface.bodyTop, surface.bodyBottom],
      ),
      border: Border.all(
        color: _focused
            ? scheme.primary
            : _hovered
            ? surface.rimHover
            : surface.rim,
      ),
      boxShadow: [
        BoxShadow(
          color: surface.shadowColor,
          blurRadius: surface.shadowBlur,
          offset: surface.shadowOffset,
        ),
      ],
    );
  }

  /// Title with its menu button, pinned to two scaled lines in both skins.
  ///
  /// A grid cannot stretch a row to its tallest card instead: the card picks
  /// its typography tier from a `LayoutBuilder`, and `LayoutBuilder` refuses to
  /// report intrinsic dimensions, so `IntrinsicHeight` over a row of cards
  /// throws during layout. On the board the unused second line reads as the
  /// padding under the text rather than as a hole in a flat list.
  Widget _titleBlock({
    required bool glass,
    required VideoCardSurface surface,
    required double textWidth,
    required TextStyle? titleStyle,
    required Color titleColor,
  }) {
    final fontSize = glass ? surface.titleFor(textWidth) : _titleFontSize;
    return SizedBox(
      width: double.infinity,
      height: MediaQuery.textScalerOf(context).scale(fontSize) * 1.4 * 2 + 2,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: HighlightedText(
              widget.video.title,
              query: widget.highlightQuery,
              maxLines: 2,
              showOverflowTooltip: true,
              // Touch long-press belongs to the card's action menu when it has
              // one, so the overflow tooltip must not compete for that gesture.
              tooltipTriggerMode: widget.menu == null
                  ? TooltipTriggerMode.longPress
                  : TooltipTriggerMode.manual,
              style: titleStyle?.copyWith(color: titleColor),
            ),
          ),
          if (widget.feedback == null)
            if (widget.menu case final menu?) _menuButton(menu, textWidth),
        ],
      ),
    );
  }

  Widget _menuButton(VideoCardMenu menu, double cardWidth) {
    final tier = _VideoCardWidthTier.fromWidth(cardWidth);
    final buttonSize = Size.square(tier.menuButtonSize);
    final progressSize = tier.menuIconSize * .8;
    final touchPlatform = switch (Theme.of(context).platform) {
      TargetPlatform.android || TargetPlatform.iOS => true,
      _ => false,
    };
    final visible =
        _hovered || _focused || _menuFocused || _menuOpen || touchPlatform;
    final busy = menu.busy || _addingWatchLater;
    return Focus(
      skipTraversal: true,
      onFocusChange: (focused) => _update(() => _menuFocused = focused),
      child: Opacity(
        opacity: visible ? 1 : 0,
        child: IgnorePointer(
          ignoring: !visible,
          // A disabled nested button must consume taps rather than open video.
          child: GestureDetector(
            key: _menuAnchor,
            onTap: () {},
            excludeFromSemantics: true,
            child: IconButton(
              key: const ValueKey('video-card-title-menu'),
              onPressed: _canShowMenu ? _showMenu : null,
              icon: busy
                  ? SizedBox.square(
                      dimension: progressSize,
                      child: const CircularProgressIndicator(
                        strokeWidth: 2,
                        semanticsLabel: '操作中',
                      ),
                    )
                  : Icon(
                      Icons.more_vert,
                      size: tier.menuIconSize,
                      semanticLabel: '更多操作',
                    ),
              iconSize: tier.menuIconSize,
              style: IconButton.styleFrom(
                minimumSize: buttonSize,
                maximumSize: buttonSize,
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.standard,
                // Padded tap targets would still reserve 48px beside the title.
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showMenu() async {
    if (!_canShowMenu || _menuOpen || !WorkspaceActivity.isActive(context)) {
      return;
    }
    final menu = widget.menu;
    if (menu == null) return;
    final id = widget.video.id;
    final generation = _addGeneration;
    final interactions = _interactions;
    _update(() => _menuOpen = true);
    VideoCardMenuAction? selected;
    try {
      if (MediaQuery.sizeOf(context).width < 600) {
        var selecting = false;
        selected = await showModalBottomSheet<VideoCardMenuAction>(
          context: context,
          useSafeArea: true,
          isScrollControlled: true,
          showDragHandle: true,
          backgroundColor: Theme.of(context).colorScheme.surface,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
          ),
          clipBehavior: Clip.antiAlias,
          builder: (context) => SafeArea(
            top: false,
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final action in menu.actions)
                    ListTile(
                      leading: Icon(_menuIcon(action)),
                      title: Text(_menuLabel(action)),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      onTap: () {
                        if (selecting) return;
                        selecting = true;
                        Navigator.of(context).pop(action);
                      },
                    ),
                ],
              ),
            ),
          ),
        );
      } else {
        final overlay = Navigator.of(context).overlay;
        final anchor = _menuAnchor.currentContext?.findRenderObject();
        if (overlay == null || anchor is! RenderBox) return;
        final overlayBox = overlay.context.findRenderObject() as RenderBox;
        RelativeRect position() => RelativeRect.fromRect(
          Rect.fromPoints(
            anchor.localToGlobal(
              Offset(0, anchor.size.height),
              ancestor: overlayBox,
            ),
            anchor.localToGlobal(
              anchor.size.bottomRight(Offset.zero),
              ancestor: overlayBox,
            ),
          ),
          Offset.zero & overlayBox.size,
        );
        final initialPosition = position();
        selected = await showMenu<VideoCardMenuAction>(
          context: context,
          positionBuilder: (_, _) =>
              anchor.attached ? position() : initialPosition,
          constraints: const BoxConstraints(minWidth: 156, maxWidth: 240),
          color: Theme.of(context).colorScheme.surface,
          surfaceTintColor: Colors.transparent,
          elevation: 3,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(
              color: Theme.of(context).colorScheme.outlineVariant
                  .withValues(alpha: .6),
            ),
          ),
          items: [
            for (final action in menu.actions)
              PopupMenuItem(
                value: action,
                child: Row(
                  children: [
                    Icon(_menuIcon(action), size: 19),
                    const SizedBox(width: 10),
                    Flexible(child: Text(_menuLabel(action))),
                  ],
                ),
              ),
          ],
        );
      }
    } finally {
      if (mounted) _update(() => _menuOpen = false);
    }
    // The retained tile may now represent another account, video or action set.
    if (!mounted ||
        selected == null ||
        widget.video.id != id ||
        generation != _addGeneration ||
        interactions != _interactions ||
        !_canShowMenu ||
        !WorkspaceActivity.isActive(context) ||
        widget.menu?.actions.contains(selected) != true) {
      return;
    }
    if (selected == VideoCardMenuAction.watchLater) {
      await _addWatchLater();
    } else {
      widget.menu?.onSelected?.call(selected);
    }
  }

  static IconData _menuIcon(VideoCardMenuAction action) => switch (action) {
    VideoCardMenuAction.notInterested => Icons.not_interested_outlined,
    VideoCardMenuAction.watchLater => Icons.watch_later_outlined,
    VideoCardMenuAction.removeWatchLater ||
    VideoCardMenuAction.removeHistory => Icons.delete_outline,
  };

  static String _menuLabel(VideoCardMenuAction action) => switch (action) {
    VideoCardMenuAction.notInterested => '不感兴趣',
    VideoCardMenuAction.watchLater => '稍后再看',
    VideoCardMenuAction.removeWatchLater => '删除',
    VideoCardMenuAction.removeHistory => '删除记录',
  };

  Future<void> _addWatchLater() async {
    if (!WorkspaceActivity.isActive(context)) return;
    final scope = VideoCardInteractionScope.maybeOf(context);
    if (scope == null || _addingWatchLater) return;
    final id = widget.video.id;
    final generation = ++_addGeneration;
    _update(() => _addingWatchLater = true);
    final result = await scope.interactions.addWatchLater(id);
    if (!mounted ||
        generation != _addGeneration ||
        widget.video.id != id ||
        scope.interactions !=
            VideoCardInteractionScope.maybeOf(context)?.interactions) {
      return;
    }
    _update(() => _addingWatchLater = false);
    final message = switch (result) {
      WatchLaterResult.added || WatchLaterResult.alreadyAdded => '已加入稍后再看',
      WatchLaterResult.signIn => '请先登录后再添加稍后再看',
      WatchLaterResult.uncertain => '添加结果暂时无法确认，请在稍后再看列表核对',
      WatchLaterResult.failed => '添加失败，请稍后重试',
      WatchLaterResult.busy || WatchLaterResult.cancelled => null,
    };
    if (message != null && WorkspaceActivity.isActive(context)) {
      scope.onNotice(context, message);
    }
  }

  Widget _coverFallback(BuildContext context) => ColoredBox(
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    child: Icon(
      Icons.image_outlined,
      size: 36,
      color: Theme.of(context).colorScheme.onSurfaceVariant
          .withValues(alpha: 0.6),
    ),
  );
}

final class _CoverMetadata extends StatefulWidget {
  const _CoverMetadata({
    required this.video,
    required this.cardWidth,
    required this.playLabel,
    required this.danmakuLabel,
    this.showCounts = true,
  });

  final VideoSummary video;
  final double cardWidth;
  final String playLabel;
  final String danmakuLabel;

  /// False on the glass board, where the counts move into the card's meta line
  /// and only the duration stays over the image.
  final bool showCounts;

  @override
  State<_CoverMetadata> createState() => _CoverMetadataState();
}

typedef _CardTextMetricsKey = ({
  String label,
  TextStyle style,
  TextScaler textScaler,
  TextDirection direction,
  Locale? locale,
});

/// Single-line label widths for the card's two responsive rows. The grid shares
/// one cache across a row, a font change clears the local entries, and the
/// bounded LRU keeps changing labels from growing them.
mixin _MeasuresCardText<T extends StatefulWidget> on State<T> {
  static const _maximumCachedWidths = 12;
  final _textWidths = <_CardTextMetricsKey, double>{};
  TextMeasurementCache? _measurements;

  @override
  void initState() {
    super.initState();
    PaintingBinding.instance.systemFonts.addListener(_fontsChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _measurements = TextMeasurementCacheScope.maybeOf(context);
  }

  @override
  void dispose() {
    PaintingBinding.instance.systemFonts.removeListener(_fontsChanged);
    super.dispose();
  }

  void _fontsChanged() => setState(_textWidths.clear);

  double measureWidth(_CardTextMetricsKey key) {
    final cached = _textWidths.remove(key);
    if (cached != null) {
      _textWidths[key] = cached;
      return cached;
    }
    double measure() {
      final painter = TextPainter(
        text: TextSpan(text: key.label, style: key.style),
        textDirection: key.direction,
        textScaler: key.textScaler,
        locale: key.locale,
        maxLines: 1,
      );
      try {
        painter.layout();
        return painter.width;
      } finally {
        painter.dispose();
      }
    }

    final width = _measurements?.width(key, measure) ?? measure();
    if (_textWidths.length == _maximumCachedWidths) {
      _textWidths.remove(_textWidths.keys.first);
    }
    _textWidths[key] = width;
    return width;
  }
}

final class _CoverMetadataState extends State<_CoverMetadata>
    with _MeasuresCardText {
  static const _regularFontSize = 12.0;
  static const _style = TextStyle(
    color: Colors.white,
    fontSize: _regularFontSize,
    fontWeight: FontWeight.w400,
    // The cover gradient supplies contrast. Blurred glyph shadows add raster
    // work for every label in dense rows even when the cards are unchanged.
    shadows: [],
  );
  static const _iconSize = 13.0;
  static const _iconGap = 3.0;
  static const _countGap = 8.0;
  static const _durationGap = 8.0;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      // Use the whole card width so padding does not shift typography tiers.
      final fontSize = _VideoCardWidthTier.fromWidth(widget.cardWidth)
          .coverFontSize;
      final sizeFactor = fontSize / _regularFontSize;
      final style = _style.copyWith(fontSize: fontSize);
      final iconSize = _iconSize * sizeFactor;
      final iconGap = _iconGap * sizeFactor;
      final countGap = _countGap * sizeFactor;
      final durationGap = _durationGap * sizeFactor;
      final timeLabel = durationLabel(widget.video.duration);
      var effectiveStyle = DefaultTextStyle.of(context).style.merge(style);
      if (MediaQuery.boldTextOf(context)) {
        effectiveStyle = effectiveStyle.merge(
          const TextStyle(fontWeight: FontWeight.bold),
        );
      }
      final textScaler = MediaQuery.textScalerOf(context);
      final direction = Directionality.of(context);
      final locale = Localizations.maybeLocaleOf(context);
      double textWidth(String label) => measureWidth((
        label: label,
        style: effectiveStyle,
        textScaler: textScaler,
        direction: direction,
        locale: locale,
      ));

      if (!widget.showCounts) {
        // Nothing to measure: the counts live in the card's meta line now.
        return Align(
          alignment: Alignment.centerRight,
          child: Text(
            timeLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        );
      }

      // Measure the actual labels, icons and gaps before moving time below counts.
      final countsWidth =
          textWidth(widget.playLabel) +
          textWidth(widget.danmakuLabel) +
          2 * (iconSize + iconGap) +
          countGap;
      final countsFit = countsWidth <= constraints.maxWidth;
      final stacked =
          countsWidth + durationGap + textWidth(timeLabel) >
          constraints.maxWidth;
      Widget count(IconData icon, String label) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: iconSize),
          SizedBox(width: iconGap),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
        ],
      );

      final play = count(BiliIcons.playCount, widget.playLabel);
      final danmaku = count(BiliIcons.danmaku, widget.danmakuLabel);
      final counts = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          countsFit ? play : Flexible(child: play),
          SizedBox(width: countGap),
          countsFit ? danmaku : Flexible(child: danmaku),
        ],
      );
      final duration = Text(
        timeLabel,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style,
      );
      if (stacked) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            counts,
            SizedBox(height: 2 * sizeFactor),
            Align(alignment: Alignment.centerRight, child: duration),
          ],
        );
      }
      return Row(
        children: [
          Expanded(child: counts),
          SizedBox(width: durationGap),
          duration,
        ],
      );
    },
  );
}

/// The card's metadata line.
///
/// Flat (`merged == false`) builds badges, author on the left and publish date
/// on the right, exactly as before, so switching the board off returns the card
/// to the layout it had.
///
/// Merged — the glass board's single line `UP主 · ▶播放 · 💬弹幕 · 时间` — is
/// measured before it is built: a 140px card cannot hold all four, so segments
/// drop from the right in that order and the author takes whatever is left and
/// ellipsizes. Guessing from the character count would ellipsize the numbers
/// instead, which is the one part of the line that carries no other cue.
final class _AuthorMetadata extends StatefulWidget {
  const _AuthorMetadata({
    required this.video,
    required this.onOpenUser,
    required this.hovered,
    required this.onHover,
    required this.showUpBadge,
    required this.reason,
    required this.showFollowed,
    required this.publishText,
    required this.publishTooltip,
    this.merged = false,
    this.metaFontSize = 12,
    this.playLabel = '',
    this.danmakuLabel = '',
  });
  final VideoSummary video;
  final ValueChanged<UserId>? onOpenUser;
  final bool hovered;
  final ValueChanged<bool> onHover;
  final bool showUpBadge;
  final String? reason;
  final bool showFollowed;
  final String publishText;
  final String? publishTooltip;
  final bool merged;
  final double metaFontSize;
  final String playLabel, danmakuLabel;

  @override
  State<_AuthorMetadata> createState() => _AuthorMetadataState();
}

final class _AuthorMetadataState extends State<_AuthorMetadata>
    with _MeasuresCardText {
  /// A count the server did not send renders as `—`, which reads as noise
  /// inside a text line rather than as a number on the cover.
  static bool _hasCount(String label) =>
      label.trim().isNotEmpty && label.trim() != '—';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final video = widget.video;
    final id = video.authorId;
    final openUser = widget.onOpenUser;
    final date = video.publishedAt?.toLocal();
    final dateText = date == null
        ? widget.publishText
        : date.year == DateTime.now().year
        ? '${date.month}-${date.day}'
        : '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    final reasonText = widget.reason?.trim() ?? '';
    final labels = [
      if (reasonText.isNotEmpty) reasonText,
      if (widget.showFollowed && !const {'已关注', '新关注'}.contains(reasonText))
        '已关注',
    ];
    final author = ScrollAwareHoverRegion(
      onHover: widget.onHover,
      child: InkWell(
        onTap: id != null && id.isValid && openUser != null
            ? () => openUser(id)
            : null,
        hoverColor: Colors.transparent,
        hoverDuration: Duration.zero,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.showUpBadge) ...[
              const BiliUpBadge(size: 16),
              const SizedBox(width: 4),
            ],
            Flexible(
              child: Text(
                video.author,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: widget.hovered ? scheme.primary : null,
                  fontSize: widget.merged ? widget.metaFontSize : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
    Widget badge(String text) => Tooltip(
      message: text,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(
            0xFFFF7F50,
          ).withValues(alpha: theme.brightness == Brightness.dark ? .18 : .1),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, color: Color(0xFFFF7F50)),
          ),
        ),
      ),
    );
    Widget badgesBox(double cap) => ConstrainedBox(
      constraints: BoxConstraints(maxWidth: cap),
      child: labels.length == 1
          ? badge(labels.single)
          : Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [for (final label in labels) badge(label)],
            ),
    );
    final published = Text(
      dateText,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.bodySmall?.copyWith(
        fontSize: widget.merged ? widget.metaFontSize : null,
      ),
    );
    final publishedNode = widget.publishTooltip == null
        ? published
        : Tooltip(message: widget.publishTooltip!, child: published);
    if (!widget.merged) {
      return LayoutBuilder(
        builder: (context, constraints) => Row(
          children: [
            if (labels.isNotEmpty) ...[
              badgesBox(constraints.maxWidth * .35),
              const SizedBox(width: 6),
            ],
            Expanded(
              child: Align(alignment: Alignment.centerLeft, child: author),
            ),
            if (dateText.isNotEmpty) ...[
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: constraints.maxWidth * .4,
                ),
                child: publishedNode,
              ),
            ],
          ],
        ),
      );
    }

    final style = (theme.textTheme.bodySmall ?? const TextStyle()).copyWith(
      fontSize: widget.metaFontSize,
    );
    final iconSize = widget.metaFontSize;
    final iconGap = widget.metaFontSize * .2;
    final separatorGap = widget.metaFontSize * .4;
    final direction = Directionality.of(context);
    final locale = Localizations.maybeLocaleOf(context);
    final textScaler = MediaQuery.textScalerOf(context);
    double width(String label, [TextStyle? override]) => measureWidth((
      label: label,
      style: override ?? style,
      textScaler: textScaler,
      direction: direction,
      locale: locale,
    ));
    final separatorWidth = width('·') + separatorGap * 2;

    // The dot is punctuation for the eye; read aloud it would be a separate
    // segment between every pair of the line's values.
    Widget separator() => ExcludeSemantics(
      child: Text('·', style: style.copyWith(color: scheme.outlineVariant)),
    );
    Widget count(IconData icon, String label, String semantics) => Semantics(
      label: semantics,
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: iconSize, color: style.color),
          SizedBox(width: iconGap),
          Text(label, maxLines: 1, style: style),
        ],
      ),
    );

    // Left to right is also the priority order: 时间 drops before 弹幕, and 弹幕
    // before 播放.
    final items = <({double width, Widget node})>[
      if (_hasCount(widget.playLabel))
        (
          width: width(widget.playLabel) + iconSize + iconGap + separatorWidth,
          node: count(
            BiliIcons.playCount,
            widget.playLabel,
            '观看 ${widget.playLabel}',
          ),
        ),
      if (_hasCount(widget.danmakuLabel))
        (
          width:
              width(widget.danmakuLabel) + iconSize + iconGap + separatorWidth,
          node: count(
            BiliIcons.danmaku,
            widget.danmakuLabel,
            '弹幕 ${widget.danmakuLabel}',
          ),
        ),
      if (dateText.isNotEmpty)
        (width: width(dateText) + separatorWidth, node: publishedNode),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth;
        final badgeWidth = labels.isEmpty
            ? 0.0
            : (width(labels.join('    '), const TextStyle(fontSize: 11)) +
                          labels.length * 8)
                      .clamp(0, available * .35) +
                  6;
        var room = available - badgeWidth;
        if (room <= 0) {
          return Row(children: [if (labels.isNotEmpty) badgesBox(available)]);
        }
        // The counts are why the line is merged, so they are kept ahead of the
        // author, which only has to truncate: a segment survives while it fits
        // in what a three-character name still leaves over. Right-most items
        // drop first, so 时间 goes before 弹幕 before 播放.
        final kept = <Widget>[];
        var budget = room - widget.metaFontSize * 3;
        for (final item in items) {
          if (item.width > budget) break;
          budget -= item.width;
          kept.add(item.node);
        }
        return Row(
          children: [
            if (labels.isNotEmpty) ...[
              badgesBox(available * .35),
              const SizedBox(width: 6),
            ],
            Flexible(
              child: Align(alignment: Alignment.centerLeft, child: author),
            ),
            for (final node in kept) ...[
              SizedBox(width: separatorGap),
              separator(),
              SizedBox(width: separatorGap),
              node,
            ],
          ],
        );
      },
    );
  }
}
