# 视频结尾「正在恢复播放」与 3~5 秒卡死的根因定位和末尾护栏修复

日期：2026-11-06。基线源码：`a73b2ff`。环境：Android（鸿蒙卓易通）。

## 问题

视频播放到结尾时，播放页显示「正在恢复播放…」，该阶段偶发界面卡死 3~5 秒。需要定位触发与卡死两条链，并做最小修复。

## 触发链：为什么视频结束时会进入「正在恢复播放」

唯一能产生这行文案的路径是 `PlaybackSession.isRecovering`（`_recoveryScheduled || _recoveryInProgress`，[playback_session.dart:496](../../lib/features/playback/application/playback_session.dart)），它只由 `_scheduleRecovery` 置位；而 `_scheduleRecovery` 只接受 `nativePlayback` / `videoInterrupted` 两种失败。结尾前会发出这两种失败的只有播放健康检查：

1. 临近结尾、phase 仍是 `playing`（尚未 `ended`）时，外部音轨 EOF 或 `audio-pts` 读取失败/冻结。[native_playback_health.dart](../../packages/bili_player/lib/src/native_playback_health.dart) 的音频规则用「保留的旧音频时钟」对比前进的视频位置：`position - audio > 750ms` 即判 `nativePlayback` 失败，末尾护栏仅 `duration - position > 500ms`。
2. 采样每 250ms 一次，单次 `audio-pts` 读取超时 1s 且是同步 FFI（`getPropertyAsync` 只是语法糖，[native_player_properties.dart](../../packages/bili_player/lib/src/native_player_properties.dart)）。读取变慢/失败时旧时钟被保留，视频位置继续前进：真实 EOF 前最多约 2s 就可能凑够 750ms——健康检查把「正常结尾」误判成「音轨死亡」。卓易通的转译栈上读取更容易变慢，误判窗口更宽。
3. 失败经 `_interruptPlayback`（[media_kit_engine.dart:311](../../packages/bili_player/lib/src/media_kit_engine.dart)，phase 为 `ended` 才提前返回，此刻还没到）→ `_fail` → 会话失败监听（[playback_session.dart:108](../../lib/features/playback/application/playback_session.dart)）。会话的 `_desiredPlaying` 只在 enteredEnded 时清零（[playback_session.dart:1436](../../lib/features/playback/application/playback_session.dart)），此刻仍为 true → `_scheduleRecovery`（[playback_session.dart:174](../../lib/features/playback/application/playback_session.dart)）→ 面板文案「正在恢复播放…」（[playback_panel.dart:1726](../../lib/features/playback/presentation/playback_panel.dart)）→ `retry()` 重解析 + 重开播放器。

同文件 :39 的 videoInterrupted 规则（播放位置领先缓冲区 250ms 以上）在末尾有同一个 500ms 护栏：网络追赶不上 demuxer 缓存时同样会把结尾误判为中断。

**这条恢复本身没有意义**：视频正在正常结束，重解析换来的新播放器只会把结尾再演一遍，却要付出整条 `retry()` 的代价——包括下面的卡死窗口。

## 卡死链：为什么偶发 3~5 秒

1. `retry()` → `engine.open()` → `_releasePlayer()`（[media_kit_engine.dart:601](../../packages/bili_player/lib/src/media_kit_engine.dart) 调用，[:1313](../../packages/bili_player/lib/src/media_kit_engine.dart) 实现）在 Android 上先做 `releaseAndroidOutput`（卸载表面 ≤400ms + stop ≤3s + 轮询 `current-vo` ≤600ms），再 `old.dispose()`（[:1345](../../packages/bili_player/lib/src/media_kit_engine.dart)）。
2. 固定插件的 `NativePlayer.dispose()` 随即投一个**不可取消的 5 秒 Timer**，在 Dart UI isolate 上执行 `mpv_terminate_destroy(ctx)`，阻塞到旧 mpv 核心退出（Pub 缓存 `media-kit-73771ec…/media_kit/lib/src/player/native/player/real.dart:87-95`）。
3. 卓易通上「重解析 + 新播放器/VO 初始化」 routinely 超过 5s，Timer 正好落在 spinner 窗口内；旧核心若还在收尾（引擎把 `network-timeout` 配成 30s），UI 线程被阻塞数秒——即 3~5 秒卡死。偶发取决于旧核心忙闲，与 [F83](../decisions.md) 记录的退出卡死是同一机制，该文档明确保留这条残余风险：应用侧既等不到也取消不了这个 Timer。

同路径还有一处加成：`releaseAndroidOutput` 轮询只把 20ms 睡眠计入 600ms 预算，每次 `readCurrentOutput()` 是 UI isolate 上的同步 FFI，核心锁被占时单次读取即可阻塞，墙钟时间无上界（[android_output_release.dart:39](../../packages/bili_player/lib/src/android_output_release.dart)）。本轮未改它（见「未验证」）。

## 修复

按选定方向，只改健康检查的末尾护栏：两条规则的 `500ms` 换成共享常量 `endOfStreamGuard = 2s`（[native_playback_health.dart:15](../../packages/bili_player/lib/src/native_playback_health.dart)）。

**为什么是 2s**：采样 250ms + 读取超时 1s，旧音频时钟在真实 EOF 前最多可陈旧约 2s（约两次失败读取）；护栏必须覆盖这个窗口才能消除误报，再宽只会放大「片尾真实音轨死亡漏检」的盲区。2s 内漏检的代价是结尾至多 2s 无声或短暂停顿，远小于一次完整重解析加播放器更换。

保留的行为：`duration <= 0`（未知时长）仍绕过护栏；片中音频 EOF、静默停滞（8s/30s）的判据不变；护栏外（距结尾 >2s）的音频 EOF 仍然失败。

被否掉的方向：在会话层 `_scheduleRecovery` 加「距结尾不恢复」的护栏（失败仍会落到 error 文案，比 spinner 更糟，且把播放健康判断拆成两处）；改固定插件的 5 秒 Timer（F84 后插件层补丁已撤，应用侧无通路）。

## 已核

- `bili_player` 定向：`flutter test test/native_playback_health_test.dart` **20/20 通过**（含 3 条新用例：护栏内陈旧音频时钟不失败、护栏内缓冲区掉队不失败、护栏外音频 EOF 仍失败）。
- 单点变异：常量改回 500ms → 恰好两条护栏用例转红（-2），护栏外用例保持绿；改回 2s 复跑全绿。期间发现并修正一条 initially 无效的用例（`position - buffered = 0` 时 videoInterrupted 规则本就够不着，已改为位置领先缓冲区 500ms）。
- `bili_player` 全量：`flutter test` **160/160 通过**；`flutter analyze` No issues found；`dart format` 干净。
- 根应用定向：`playback_session_test`、`playback_panel_test`、`macos_fullscreen_close_test`、`workspace_router_test` 合并 **781/781 通过**。

## 未验证

- 卓易通实机未测：视频结尾是否不再出现「正在恢复播放」、卡死是否消失，均需设备复测；本条只证明了 Dart 侧判据。
- 插件 5 秒 `mpv_terminate_destroy` Timer 的 UI 线程阻塞**没有消除**：合法恢复路径（片中真实停滞、URL 刷新失败等）仍会走到 `old.dispose()`，恢复总时长超过 5s 时卡死仍可能出现。要根治需改 `media_kit` 核心侧销毁路径（F83 结论：本树不做）。
- 结尾前 2s 内的真实音轨死亡/缓冲区饥饿不再触发恢复（有意的盲区），实际观感未在设备上确认。
- `releaseAndroidOutput` 轮询的墙钟无界问题仍在（本轮未改）。
