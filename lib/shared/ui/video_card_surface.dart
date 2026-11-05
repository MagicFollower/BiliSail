import 'package:flutter/material.dart';

/// Painted "liquid glass" tokens for the video card and the grids that host it.
///
/// Carried on the theme so one setting reaches every list that reuses the card
/// without threading a parameter through each grid, list and preview.
///
/// The board is painted from fills, a lit rim and a shadow — never a
/// `BackdropFilter`. A grid would sample the backdrop once per visible card per
/// scrolled frame, the same reason the notice card and the pull-refresh ring are
/// painted (`docs/decisions.md` D74, D77). Where a runtime cannot composite
/// glass over scrolling content, the setting installs [VideoCardSurface.flat]
/// and the card keeps its original flat layout.
@immutable
final class VideoCardSurface extends ThemeExtension<VideoCardSurface> {
  const VideoCardSurface({
    this.enabled = false,
    this.cardRadius = 8,
    this.coverRadius = 6,
    this.inset = 0,
    this.titleGap = 9,
    this.metaGap = 6,
    this.bottomGap = 1,
    this.bodyTop = const Color(0x00000000),
    this.bodyBottom = const Color(0x00000000),
    this.rim = const Color(0x00000000),
    this.rimHover = const Color(0x00000000),
    this.shadowColor = const Color(0x00000000),
    this.shadowBlur = 0,
    this.shadowOffset = Offset.zero,
    this.titleSizes = const (compact: 15, medium: 15, regular: 15),
    this.metaSizes = const (compact: 12, medium: 12, regular: 12),
    this.backdropTop = const Color(0x00000000),
    this.backdropBottom = const Color(0x00000000),
  });

  /// Every token at the values the flat card already uses, so a disabled
  /// surface is not a second style but the absence of one.
  static const flat = VideoCardSurface();

  final bool enabled;

  /// Board and cover corners. The cover sits inside [inset], so its radius
  /// stays smaller than the board's to keep the two curves concentric.
  final double cardRadius, coverRadius, inset;

  /// Cover → title, title → meta and meta → board bottom.
  final double titleGap, metaGap, bottomGap;

  /// Board fill (top-left to bottom-right) and its hairline rim.
  final Color bodyTop, bodyBottom, rim, rimHover;

  /// The lift under the board. Blur is paid once per repaint of a card's own
  /// layer, not per frame the list scrolls.
  final Color shadowColor;
  final double shadowBlur;
  final Offset shadowOffset;

  /// Typography per card-width tier, matching the cover label tiers in
  /// `video_card.dart` so a narrow card shrinks title and meta together.
  final ({double compact, double medium, double regular}) titleSizes;
  final ({double compact, double medium, double regular}) metaSizes;

  /// The page wash the boards float on. A flat `surface` gives a translucent
  /// card nothing to read against, so the treatment owns both layers.
  final Color backdropTop, backdropBottom;

  bool get hasBackdrop => enabled && backdropTop.a > 0 && backdropBottom.a > 0;

  double titleFor(double cardWidth) => switch (cardWidth) {
    < 180 => titleSizes.compact,
    < 240 => titleSizes.medium,
    _ => titleSizes.regular,
  };

  double metaFor(double cardWidth) => switch (cardWidth) {
    < 180 => metaSizes.compact,
    < 240 => metaSizes.medium,
    _ => metaSizes.regular,
  };

  @override
  VideoCardSurface copyWith({
    bool? enabled,
    double? cardRadius,
    double? coverRadius,
    double? inset,
    double? titleGap,
    double? metaGap,
    double? bottomGap,
    Color? bodyTop,
    Color? bodyBottom,
    Color? rim,
    Color? rimHover,
    Color? shadowColor,
    double? shadowBlur,
    Offset? shadowOffset,
    ({double compact, double medium, double regular})? titleSizes,
    ({double compact, double medium, double regular})? metaSizes,
    Color? backdropTop,
    Color? backdropBottom,
  }) => VideoCardSurface(
    enabled: enabled ?? this.enabled,
    cardRadius: cardRadius ?? this.cardRadius,
    coverRadius: coverRadius ?? this.coverRadius,
    inset: inset ?? this.inset,
    titleGap: titleGap ?? this.titleGap,
    metaGap: metaGap ?? this.metaGap,
    bottomGap: bottomGap ?? this.bottomGap,
    bodyTop: bodyTop ?? this.bodyTop,
    bodyBottom: bodyBottom ?? this.bodyBottom,
    rim: rim ?? this.rim,
    rimHover: rimHover ?? this.rimHover,
    shadowColor: shadowColor ?? this.shadowColor,
    shadowBlur: shadowBlur ?? this.shadowBlur,
    shadowOffset: shadowOffset ?? this.shadowOffset,
    titleSizes: titleSizes ?? this.titleSizes,
    metaSizes: metaSizes ?? this.metaSizes,
    backdropTop: backdropTop ?? this.backdropTop,
    backdropBottom: backdropBottom ?? this.backdropBottom,
  );

  /// Theme transitions step rather than interpolate: a lerped radius or shadow
  /// would repaint every card in every grid for the length of the animation.
  @override
  VideoCardSurface lerp(ThemeExtension<VideoCardSurface>? other, double t) {
    if (other is! VideoCardSurface) return this;
    return t < 0.5 ? this : other;
  }

  /// Value equality, which the card's own caches depend on. `MaterialApp`
  /// animates theme changes, and every frame of that animation is a *new*
  /// `ThemeData` whose `extensions` map holds a new instance of this class.
  /// Without `==` those instances never compare equal, so `ThemeData.==` reports
  /// a theme change on each frame and the cover's cached widget - along with the
  /// hover preview sitting inside it - is rebuilt ~20 times per transition.
  ({
    bool enabled,
    double cardRadius,
    double coverRadius,
    double inset,
    double titleGap,
    double metaGap,
    double bottomGap,
    Color bodyTop,
    Color bodyBottom,
    Color rim,
    Color rimHover,
    Color shadowColor,
    double shadowBlur,
    Offset shadowOffset,
    ({double compact, double medium, double regular}) titleSizes,
    ({double compact, double medium, double regular}) metaSizes,
    Color backdropTop,
    Color backdropBottom,
  })
  get _key => (
    enabled: enabled,
    cardRadius: cardRadius,
    coverRadius: coverRadius,
    inset: inset,
    titleGap: titleGap,
    metaGap: metaGap,
    bottomGap: bottomGap,
    bodyTop: bodyTop,
    bodyBottom: bodyBottom,
    rim: rim,
    rimHover: rimHover,
    shadowColor: shadowColor,
    shadowBlur: shadowBlur,
    shadowOffset: shadowOffset,
    titleSizes: titleSizes,
    metaSizes: metaSizes,
    backdropTop: backdropTop,
    backdropBottom: backdropBottom,
  );

  @override
  bool operator ==(Object other) =>
      other is VideoCardSurface && other._key == _key;

  @override
  int get hashCode => _key.hashCode;

  @override
  String toString() =>
      'VideoCardSurface(${enabled ? 'glass' : 'flat'}, radius: $cardRadius, '
      'inset: $inset, title: $titleSizes, meta: $metaSizes)';
}

/// The card surface for this context. A list mounted without [BiliTheme] (a
/// bare `MaterialApp` in a test or a preview) gets the flat card rather than an
/// invented style.
VideoCardSurface videoCardSurfaceOf(BuildContext context) =>
    Theme.of(context).extension<VideoCardSurface>() ?? VideoCardSurface.flat;

/// The corner a board painted from [surface] draws with, and the corner its
/// ink must be clipped to. `InkResponse` reads its *own* `borderRadius` and
/// never falls back to a parent `Material`, so a caller that paints a board and
/// leaves the ink square gets a rectangle poking out of a rounded board
/// (`docs/decisions.md` F82).
double liquidBoardRadius(VideoCardSurface surface) =>
    surface.enabled ? surface.cardRadius : 8;

/// The corner for ink inside a board: one pixel in from [liquidBoardRadius],
/// so the highlight stops at the rim instead of pressing over it.
double liquidInkRadius(VideoCardSurface surface) =>
    liquidBoardRadius(surface) - 1;

/// The board itself: a translucent body gradient, one lit hairline and a
/// shadow. Painted only — never a `BackdropFilter`, for the reason on
/// [VideoCardSurface].
///
/// A flat surface is an empty decoration on the same node, not an absent node.
/// Returning the child unwrapped when the setting is off would swap the widget
/// type in that slot and rebuild the subtree under it, which is how toggling
/// the setting threw every page back to the top (F82).
///
/// [flat] is the region's own look before boards existed. The video card has
/// none (it was flat by origin), but the playback page's collection panel was
/// already a filled `surfaceContainerLow` block — switching the setting off must
/// return it to that, not to an unpainted area.
BoxDecoration liquidBoardDecoration({
  required VideoCardSurface surface,
  required ColorScheme scheme,
  bool focused = false,
  bool hovered = false,
  BoxDecoration? flat,
}) {
  if (!surface.enabled) {
    return flat ??
        BoxDecoration(
          borderRadius: BorderRadius.circular(liquidBoardRadius(surface)),
          border: Border.all(
            color: focused ? scheme.primary : Colors.transparent,
          ),
        );
  }
  return BoxDecoration(
    borderRadius: BorderRadius.circular(liquidBoardRadius(surface)),
    gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [surface.bodyTop, surface.bodyBottom],
    ),
    border: Border.all(
      color: focused
          ? scheme.primary
          : hovered
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
