import 'package:bilisail/app/theme.dart';
import 'package:bilisail/domain/video.dart';
import 'package:bilisail/shared/ui/video_card.dart';
import 'package:bilisail/shared/ui/video_card_cover.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The video card on its painted glass board (`liquidVideoCards`, on by default)
/// against the same card with the setting off. The flat cases are here so the
/// switch is provably a return to the previous layout, not a new default with a
/// decorative name.
void main() {
  const longTitle = '这是一个需要两行才放得下的视频标题';
  const shortTitle = '短标题';
  const authorName = '测试UP';
  const dateLabel = '3-5';

  // The merged meta line is fitted by measured width, and the default test font
  // draws every glyph one em wide, which would not describe the real fit.
  setUpAll(() async {
    await (FontLoader('HarmonyOS Sans')..addFont(
          rootBundle.load(
            'assets/fonts/harmonyos_sans/HarmonyOS_Sans_SC_Regular.ttf',
          ),
        ))
        .load();
    await (FontLoader(
      'BiliIcons',
    )..addFont(rootBundle.load('assets/fonts/biliicon.ttf'))).load();
  });

  VideoSummary video({
    String title = longTitle,
    String author = authorName,
    int? plays = 21000,
    int? danmaku = 36,
  }) => VideoSummary(
    id: const VideoId('BV1234567890'),
    title: title,
    coverUrl: '',
    author: author,
    duration: const Duration(seconds: 20),
    playCount: plays,
    danmakuCount: danmaku,
    // Same-year dates render as `M-D`, so the label stays stable whenever this
    // suite runs.
    publishedAt: DateTime(DateTime.now().year, 3, 5),
  );

  Future<void> show(
    WidgetTester tester, {
    required bool liquid,
    required VideoSummary item,
    double width = 320,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: BiliTheme.light(liquidVideoCards: liquid),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: VideoCard(video: item, onTap: () {}),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  BoxDecoration board(WidgetTester tester) =>
      tester
              .widget<AnimatedContainer>(
                find
                    .descendant(
                      of: find.byType(VideoCard),
                      matching: find.byType(AnimatedContainer),
                    )
                    .first,
              )
              .decoration!
          as BoxDecoration;

  double coverRadius(WidgetTester tester) =>
      tester.widget<VideoCardCover>(find.byType(VideoCardCover)).borderRadius;

  List<BoxShadow> shadows(BoxDecoration board) =>
      board.boxShadow ?? const <BoxShadow>[];

  double fontSizeOf(WidgetTester tester, String text) =>
      tester.widget<Text>(find.text(text).first).style?.fontSize ?? -1;

  testWidgets(
    'the board is painted from a translucent fill, a lit rim and a lift',
    (WidgetTester tester) async {
      await show(tester, liquid: true, item: video());
      final glass = board(tester);
      expect(glass.borderRadius, BorderRadius.circular(16));
      final fill = glass.gradient! as LinearGradient;
      // Translucent, or the wash behind it is pointless and this is a plain card.
      expect(fill.colors.first.a, greaterThan(0));
      expect(fill.colors.first.a, lessThan(1));
      expect(fill.colors.last.a, lessThan(fill.colors.first.a));
      expect((glass.border! as Border).top.color.a, greaterThan(0));
      final lift = shadows(glass);
      expect(lift, hasLength(1));
      // The shadow falls below the board: that is what makes it read as floating.
      expect(lift.single.blurRadius, greaterThan(0));
      expect(lift.single.offset.dy, greaterThan(0));
      // The cover sits inside the board's inset, so its corner is the concentric
      // 8, not the flat card's 6.
      expect(coverRadius(tester), 8);
    },
  );

  testWidgets('turning the setting off restores the unpainted card', (
    WidgetTester tester,
  ) async {
    await show(tester, liquid: false, item: video());
    final flat = board(tester);
    expect(flat.gradient, isNull);
    expect(shadows(flat), isEmpty);
    expect(flat.borderRadius, BorderRadius.circular(8));
    expect(coverRadius(tester), 6);
  });

  testWidgets(
    'counts join the author line and the cover keeps only the duration',
    (WidgetTester tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await show(tester, liquid: true, item: video());
        final authorY = tester.getCenter(find.text(authorName)).dy;
        // The judgment is the line, not the label: on the flat card the counts sit
        // over the image, well above the author.
        expect(tester.getCenter(find.text('2.1万')).dy, closeTo(authorY, 2));
        expect(tester.getCenter(find.text('36')).dy, closeTo(authorY, 2));
        expect(tester.getCenter(find.text(dateLabel)).dy, closeTo(authorY, 2));
        // The card is one tap target, so a screen reader gets a single merged
        // label. `bySemanticsLabel` matches a String exactly, hence RegExp.
        expect(find.bySemanticsLabel(RegExp('观看 2\\.1万')), findsOneWidget);
        expect(find.bySemanticsLabel(RegExp('时长 00:20')), findsOneWidget);
        // The cover used to announce all three counts; on the board it keeps only
        // the duration, so the joined string must be gone.
        expect(find.bySemanticsLabel(RegExp('观看 2\\.1万，弹幕')), findsNothing);
        // The separator dots are decoration, not something to read out.
        expect(find.bySemanticsLabel(RegExp('·')), findsNothing);

        await show(tester, liquid: false, item: video());
        expect(
          tester.getCenter(find.text('2.1万')).dy,
          lessThan(tester.getCenter(find.text(authorName)).dy - 20),
        );
        expect(
          find.bySemanticsLabel(RegExp('观看 2\\.1万，弹幕 36，时长 00:20')),
          findsOneWidget,
        );
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets('a count the server did not send leaves the line', (
    WidgetTester tester,
  ) async {
    await show(tester, liquid: true, item: video(plays: null, danmaku: null));
    // `—` reads as noise inside a text line; over the image it is a placeholder.
    expect(find.text('—'), findsNothing);
    expect(find.text(authorName), findsOneWidget);
    expect(find.text(dateLabel), findsOneWidget);

    await show(tester, liquid: false, item: video(plays: null, danmaku: null));
    expect(find.text('—'), findsNWidgets(2));
  });

  testWidgets('a narrow board sheds 时间 before 弹幕 before 播放', (
    WidgetTester tester,
  ) async {
    final item = video(author: '一个相当长的UP主名称需要被省略');
    await show(tester, liquid: true, item: item, width: 150);
    expect(find.text('2.1万'), findsOneWidget);
    expect(find.text(dateLabel), findsNothing);
    expect(tester.takeException(), isNull);

    await show(tester, liquid: true, item: item, width: 320);
    expect(find.text('2.1万'), findsOneWidget);
    expect(find.text('36'), findsOneWidget);
    expect(find.text(dateLabel), findsOneWidget);
  });

  testWidgets('title and meta step down together with the card width tier', (
    WidgetTester tester,
  ) async {
    for (final (width, title, meta) in const [
      (150.0, 13.0, 10.0),
      (200.0, 14.0, 11.0),
      (320.0, 15.0, 12.0),
    ]) {
      await show(tester, liquid: true, item: video(), width: width);
      expect(fontSizeOf(tester, longTitle), title, reason: 'title at $width');
      expect(fontSizeOf(tester, authorName), meta, reason: 'meta at $width');
    }
    // The flat card keeps the single 15px title it always drew.
    await show(tester, liquid: false, item: video(), width: 150);
    expect(fontSizeOf(tester, longTitle), 15);
  });

  testWidgets(
    'boards stay two title lines tall so a grid row keeps one bottom edge',
    (WidgetTester tester) async {
      Future<double> height(String title) async {
        await show(tester, liquid: true, item: video(title: title));
        return tester.getSize(find.byType(VideoCard)).height;
      }

      // A row cannot be stretched to its tallest card instead: the card picks its
      // typography tier from a `LayoutBuilder`, and `LayoutBuilder` refuses to
      // report intrinsic dimensions, so `IntrinsicHeight` over a row of cards
      // throws during layout. On the board the spare line reads as padding.
      expect(await height(shortTitle), await height(longTitle));
    },
  );
}
