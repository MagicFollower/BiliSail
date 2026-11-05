import '../../../domain/user.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/video.dart';
import '../../../shared/ui/network_avatar.dart';
import '../../../shared/ui/video_card.dart';
import '../../../shared/ui/video_card_surface.dart';
import '../../../shared/ui/user_follow_button.dart';
import '../application/video_author_controller.dart';
import '../domain/video_author_repository.dart';
import 'video_staff_panel.dart';

final class VideoAuthorHeader extends ConsumerWidget {
  const VideoAuthorHeader({
    super.key,
    required this.video,
    this.onLogin,
    this.onOpenUser,
  });
  final VideoDetail video;
  final VoidCallback? onLogin;
  final ValueChanged<UserId>? onOpenUser;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (video.staff.isNotEmpty) {
      return _board(
        context,
        VideoStaffPanel(
          key: ValueKey(video.summary.id),
          members: video.staff,
          onLogin: onLogin,
          onOpenUser: onOpenUser,
        ),
      );
    }
    final mid = video.authorMid;
    final provider = mid == null
        ? null
        : videoAuthorControllerProvider(VideoAuthorId(mid));
    final state = provider == null ? null : ref.watch(provider);
    final author = state?.author;
    final theme = Theme.of(context);
    final surface = videoCardSurfaceOf(context);
    final button = state == null || state.isSelf || mid == null
        ? null
        : UserFollowButton(
            id: UserId(mid),
            onLogin: onLogin,
            compact: true,
            showMessage: false,
          );
    final userId = UserId.tryParse(video.authorMid) ?? video.summary.authorId;
    final identity = InkWell(
      // Ink does not inherit the board's corner; without this the highlight is a
      // rectangle inside a rounded board (docs/decisions.md F82).
      borderRadius: BorderRadius.circular(liquidInkRadius(surface)),
      onTap: userId?.isValid == true && onOpenUser != null
          ? () => onOpenUser!(userId!)
          : null,
      child: Row(
        children: [
          NetworkAvatar(
            url: video.summary.authorAvatarUrl,
            name: video.summary.author,
            radius: 21,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  video.summary.author,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: 3),
                Text(
                  '${compactCount(author?.followerCount)}粉丝 · '
                  '${compactCount(author?.likeCount)}获赞',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
    return _board(
      context,
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              // Large text keeps the statistics legible without squeezing the button.
              if (button == null) return identity;
              if (constraints.maxWidth < 300 ||
                  MediaQuery.textScalerOf(context).scale(14) > 20) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    identity,
                    const SizedBox(height: 8),
                    Align(alignment: Alignment.centerRight, child: button),
                  ],
                );
              }
              return Row(
                children: [
                  Expanded(child: identity),
                  const SizedBox(width: 8),
                  button,
                ],
              );
            },
          ),
          if (state?.message case final String message)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(message, style: theme.textTheme.bodySmall),
                  ),
                  if (state != null && !state.signedIn && provider != null)
                    IconButton(
                      tooltip: '刷新 UP 主信息',
                      onPressed: state.loading
                          ? null
                          : () => ref.read(provider.notifier).refresh(),
                      icon: const Icon(Icons.refresh, size: 18),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// The same painted board the video card uses, so the author block reads as
  /// one card above the player. The wrapper exists in both skins - only the
  /// decoration and the inner padding change - because swapping the node type
  /// when the setting flips rebuilds the subtree and throws the page to the top
  /// (F82). Flat is the region's own look: no fill, no extra inset.
  Widget _board(BuildContext context, Widget child) {
    final surface = videoCardSurfaceOf(context);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      padding: EdgeInsets.all(surface.enabled ? surface.inset : 0),
      decoration: liquidBoardDecoration(
        surface: surface,
        scheme: Theme.of(context).colorScheme,
      ),
      child: child,
    );
  }
}
