import 'package:bilisail/app/theme.dart';
import 'package:bilisail/shared/ui/video_card_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The single source of board geometry that the video card, the playback page's
/// author header, its collection/parts block and every comment row read. The
/// tokens are taken from [BiliTheme] rather than re-typed here, so a change to
/// the theme moves the expectation with it instead of turning this suite into a
/// second copy of the numbers.
void main() {
  final theme = BiliTheme.light();
  final glass = theme.extension<VideoCardSurface>()!;
  final flat = VideoCardSurface.flat;
  final scheme = theme.colorScheme;

  test('the theme installs a glass surface', () {
    // Guards the rest of this file: if the theme stopped carrying the
    // extension, every case below would silently compare against a flat board.
    expect(glass.enabled, isTrue);
    expect(flat.enabled, isFalse);
  });

  test('a board paints fill, rim and lift at the board corner', () {
    final board = liquidBoardDecoration(surface: glass, scheme: scheme);
    expect(board.borderRadius, BorderRadius.circular(liquidBoardRadius(glass)));
    expect(board.gradient, isA<LinearGradient>());
    expect((board.gradient as LinearGradient?)!.colors, [
      glass.bodyTop,
      glass.bodyBottom,
    ]);
    expect(board.border!.top.color, glass.rim);
    expect(board.boxShadow!.single.color, glass.shadowColor);
    expect(board.boxShadow!.single.blurRadius, glass.shadowBlur);
  });

  test('focus and hover step the rim, not the shape', () {
    expect(
      liquidBoardDecoration(
        surface: glass,
        scheme: scheme,
        focused: true,
      ).border!.top.color,
      scheme.primary,
    );
    expect(
      liquidBoardDecoration(
        surface: glass,
        scheme: scheme,
        hovered: true,
      ).border!.top.color,
      glass.rimHover,
    );
  });

  test(
    'a region with its own previous look keeps it when the setting is off',
    () {
      // The collection block was a filled `surfaceContainerLow` panel before
      // boards existed. Returning an empty decoration here would restyle it
      // instead of switching the treatment off.
      final own = BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(6),
      );
      final off = liquidBoardDecoration(
        surface: flat,
        scheme: scheme,
        flat: own,
      );
      expect(off, same(own));
      expect(
        liquidBoardDecoration(
          surface: glass,
          scheme: scheme,
          flat: own,
        ).gradient,
        isNotNull,
      );
    },
  );

  test('a region that was unstyled gains nothing when the setting is off', () {
    final off = liquidBoardDecoration(surface: flat, scheme: scheme);
    expect(off.gradient, isNull);
    expect(off.color, isNull);
    expect(off.boxShadow, isNull);
    expect(off.border!.top.color, isNot(scheme.primary));
    expect(
      liquidBoardDecoration(
        surface: flat,
        scheme: scheme,
        focused: true,
      ).border!.top.color,
      scheme.primary,
    );
  });

  test('ink sits one pixel inside the drawn corner in both skins', () {
    // `InkResponse` never falls back to a parent `Material` for its clip, so a
    // square highlight pokes out of a rounded board (docs/decisions.md F82).
    expect(liquidInkRadius(glass), liquidBoardRadius(glass) - 1);
    expect(liquidInkRadius(flat), liquidBoardRadius(flat) - 1);
    expect(liquidBoardRadius(glass), glass.cardRadius);
    expect(liquidBoardRadius(flat), 8);
  });
}
