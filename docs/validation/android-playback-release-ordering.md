# Android 退出播放页后的卡死与闪退：释放顺序

日期：2026-11-04。现象来自用户实机描述：浏览并播放视频后退出播放页回到主页，**偶发**立刻卡死约 3–5 秒，随后进程消失。与底栏是液态玻璃还是原生 dock 无关。

本轮先只读代码逻辑定位错序，随后按用户「彻底闭环」补上插件层补丁并做了 Release 构建与产物级核对；**仍未安装到设备、未取 tombstone**。因此下面的原生致毁路径是**机制推断**，逐行的释放顺序则是**源码事实**，产物是否含补丁是**构建事实**（三者在下文分开标注）。

## 为什么一定是原生层

Release 里未捕获的 Dart 异常不结束进程（`lib/main.dart` 只在 macOS smoke 分支接管错误，正常路径没有 zone/`exit`）。所以"闪退"只可能来自原生层或系统回收。相关排除各有依据：drift 走后台 isolate（`lib/core/storage/app_database.dart:16`）、触摸卡片不会逐卡起预览引擎（`ScrollAwareHoverRegion` 需要真实指针）、`bili_widgets_binding.dart` 的无障碍守卫只在 Windows 生效、`TextMeasurementCache` 有 512 上限、`AndroidMediaLeases.close()` 只是通道往返。

## 锁定副本里的释放顺序（源码事实）

依赖为 `media_kit@73771ec3`（`My-Responsitories`）与 `media_kit_video@fd8421d2`，版本 1.2.5（`bggRGjQaUbCoE`）。下列路径取本地 Pub 缓存的实际副本，与根应用和 `bili_player` 两处锁文件一致。

1. `Player.dispose()` 只给核心 **2 秒**收尾：`media_kit/lib/src/player/native/player/real.dart:71-96` 的 `await stop(synchronized: false).timeout(const Duration(seconds: 2))`，超时就照常继续。本工程把 `network-timeout` 设为 30 秒（`packages/bili_player/lib/src/media_kit_engine.dart:483`，值取 `native_playback_health.dart:9` 的 `bufferingTimeout`），所以退出的瞬间若还在等网，必然走这条截断路径。
2. 接着 `super.dispose()`（`platform_player.dart:66-85`）跑 `release` 钩子 → `AndroidVideoController._dispose()`（`media_kit_video/lib/src/video_controller/android_video_controller/real.dart:263-272`）→ 通道 `VideoOutputManager.Dispose` → `media_kit_video/android/.../VideoOutput.java:149-174`：**立即** `surfaceTextureEntry.release()` 与 `surface.release()`。该文件里唯一保护 JNI 全局引用的是硬编码 5 秒 `postDelayed`，注释原话 "Invoke DeleteGlobalRef after a voluntary delay to eliminate possibility of libmpv referencing it sometime in the near future"——上游自己承认这里在赌时间。
3. `Initializer.dispose(ctx)` 只摘唤醒回调，核心仍活着（`initializer_native_event_loop.dart:95-101`）。
4. **真正的核心销毁在 5 秒后**，由 `Timer(const Duration(seconds: 5), () => mpv_terminate_destroy(ctx))` 在 Dart UI 线程上执行；应用层既等不到也取消不了。`mpv_terminate_destroy` 阻塞到核心线程退出。

即：渲染表面先死、mpv 核心后死，中间靠两个各自独立、互相猜的写死 5 秒。这与 `docs/validation/windows-preview-dispose.md` 记录的是同一类问题——Windows 那边由 `windows/patches/media_kit_video` 在插件边界建立了完成顺序，同文档明确写着 **"Android/macOS 保持既有实现"**，而本树只有 `android/` 工程。本轮按同一机制补上了 Android 侧的构建副本补丁，见下节。

## 插件层补丁：让表面退休等确认，而不是等时间

> **本节已被文末「2026-11-05 更正：插件层补丁由上游首帧机制承接（F84）」作废**：`android/patches/media_kit_video` 已随上游 `f464c55` 的补丁机制并入而被撤除，下面的表与判据只保留作历史记录。

`android/patches/media_kit_video`（Gradle 入口 `android/build.gradle.kts:20`），结构沿用同目录 `audio_service` 补丁的做法：把插件的 Java 源同步到该插件构建目录下的副本、重定向 `sourceSets.main.java.srcDirs`，**不改 Pub 缓存**。与 `audio_service` 用锚点文本替换不同，这里改为校验上游 SHA-256 后用 `java/com/alexmercerind/media_kit_video/` 里的完整改写副本覆盖——三个文件、多处改动，锚点太脆。

| 文件 | 改了什么 | 为什么 |
| --- | --- | --- |
| `VideoOutput.java` | `dispose()` 不再立即释放，改为：清掉 `setOnFrameAvailableListener`、把「纹理条目 + `Surface` + JNI 全局引用」三项装进一个 `pendingRelease`，并投一个 `RELEASE_FALLBACK_MILLIS = 6000L` 的兜底任务；新增 `releaseNative()` 取消兜底并就地一次性退休（`nativeReleased` 幂等）。 | 纹理条目注销后回调仍打 `markTextureFrameAvailable` 是给 Flutter 送一个不存在的纹理号；三项必须一起退休，且兜底延时必须**超过**核心的 5 秒销毁定时器，否则等于回到原样 |
| `VideoOutputManager.java` | `dispose(handle)` 把输出移到 `pendingReleases` 而不是丢弃；新增 `releaseNative(handle)`。 | 句柄是 `mpv_handle` 指针地址，会被下一个播放器复用；已排队的旧对象必须仍可达，且不能被新对象覆盖后泄漏（覆盖也只丢映射，兜底任务仍持有它） |
| `MediaKitVideoPlugin.java` | 新增通道分支 `VideoOutputManager.ReleaseSurface`。 | Dart 侧需要一条显式确认通路 |

`check` 任务挂了补丁回归（`:media_kit_video:check` → `testBilisailMediaKitVideoRelease`），与 `audio_service` 同一位置；另外 `tool/check.ps1` 的 Lint 段新增 `tool/test-android-media-kit-patch.ps1`，不需要 Android SDK：它从 `pubspec.lock` 的 `resolved-ref` 定位缓存副本、**从 `apply.gradle` 本身解析** SHA-256 引脚（不在脚本里复制常量）、断言提交副本与上游不同（否则修复是空转），再用任一 JDK 17+ 跑同一份回归，并做一次反向对照。

## 两侧合起来的顺序

`_releasePlayer()` 现在按这条序列走（仅 Android）：卸载 Flutter 表面 → 等核心 `current-vo` 不再是活动输出 → `old.dispose()`（插件把原生对象排队，兜底 6 秒）→ **确认过**才调 `VideoOutputManager.ReleaseSurface` 立即退休；没确认就不调，交给兜底。于是"表面先死、核心后死"这个错序在两种情形下都被排除：核心正常收尾时按确认退休，核心卡住时退休时刻晚于核心的销毁定时器。

`mpv_terminate_destroy` 仍在不可取消的裸 `Timer` 里，所以卡死窗口的**根**没有消失；本轮做的是让它落在一个已经停止、已经放下输出的核心上，从而几乎不耗时。这一点不因补丁而改变，别再按"已根除"理解。

## 致毁路径（推断，未取证）

核心尚未收尾时，它的 Android 视频输出仍挂在已被 `surface.release()` 释放的原生窗口上；同时 `VideoOutput.java:86-106` 的帧可用回调仍指向已注销的纹理条目。据此推断两条可见后果：UI 线程被 5 秒后的 `mpv_terminate_destroy` 阻塞（对应"卡死"，时长取决于核心还需多久退出），以及核心随后拆 VO 时踩到已释放对象（对应"闪退"）。只有退出瞬间核心正忙才触发，故为偶发。**本树没有 Android tombstone/ANR 记录，这条路径未经设备证据确认。**

## 本轮修正：把猜时间换成等可观测事实

主应用仍只经 `PlayerEngine`/`VideoSurface` 使用播放器。改动分两层：Dart 侧落在 `bili_player` 的播放器边界与一处应用控制器，原生侧落在 `android/patches/media_kit_video` 的构建副本补丁（上一节）。Windows 沿用既有原生补丁路径，macOS 未动，两者的 Dart 行为逐字不变。

1. `packages/bili_player/lib/src/media_kit_video_output.dart:153` 起：新增挂载计数与 `awaitSurfaceDetached(timeout: 400ms)`（`:159`）。`clearPlayer()` 只是"请求"下一帧卸载，因此新增 `_SurfacePresence`（`:491`）包住 `mkv.Video` 子树，由其 `initState`/`dispose` 维护计数，承诺只在**计数归零**时兑现——同一帧换绑新表面时旧表面卸载、新表面仍在屏，等待不会被误判为已完成。从未挂过表面（纯音频、预览未上屏）时立即返回，悬挂风险由有界超时兜住。
2. 新增 `packages/bili_player/lib/src/android_output_release.dart`：`releaseAndroidOutput()` 按 `detachSurface → stop → 轮询 current-vo` 的顺序执行，每步有界（3s / 600ms，轮询 20ms），并**返回是否确认核心已放下输出**——确认了调用方才允许立刻退休原生表面。**不替上游重复设置 `vo`/`wid`**——`AndroidVideoController.onUnloadHooks` 本来就会排队 `vo=null`、`wid=0`（`android_video_controller/real.dart:117-134`），这里只等它生效。判据复用工程里已有的原生读取 `current-vo`（`media_kit_engine.dart:889` 已用它做杜比映射判定），值不再是 `gpu`/`gpu-next` 即证明核心已把视频输出换成空输出，此后插件释放 `Surface` 才不再有核心侧引用。
3. `packages/bili_player/lib/src/media_kit_engine.dart:1300` 起：`_releasePlayer()` 在 `clearPlayer()` 与 `old.dispose()` 之间插入上述协调，并在 `dispose()` 返回后**仅在确认时**调 `_videoOutput.releaseAndroidSurface(handle)`（`:1309`，实现在 `media_kit_video_output.dart:298`）立刻退休原生表面；未确认就不调，交给插件那 6 秒兜底。这样 `Player.dispose()` 内部那次 2 秒 `stop` 变成"已经停好"的空操作，不再触发截断；核心收尾完再销毁，5 秒后的 `mpv_terminate_destroy` 也就几乎不耗时。最坏新增时延上界约 3.6 秒，且只在核心真卡住时出现；`AppDependencies.close()` 会 `await playback.close()`（`lib/app/dependencies.dart:609`），所以这个上界也是退出应用时的等待上界。`handle` 在 `dispose()` 之前读取，销毁后只把它当整数传给通道。
4. `lib/features/playback/application/playback_manager.dart:92`：`release()` 原先 `unawaited(closing.whenComplete(...))`，而 `PlaybackSession.close()` 在所有步骤跑完后**故意重抛**第一个清理失败（`playback_session.dart:2942-2975`）。Android 上没人等这条 future，于是每次释放失败都变成一条无人处理的异步错误；同一个被拒绝的 future 留在 `_releases` 里还会让 `drainReleases()` 为其他仍在关闭的会话一起抛。改为收口后再入池。**本轮没有新增释放失败的上报通道**，因此这类失败不再可见，只换来不再误导。

## 本轮检查与未测项

Dart 侧：

- `packages/bili_player` 定向：`flutter test test/android_output_release_test.dart test/media_kit_video_output_test.dart` **21 项通过**；该包全量 **153 项通过**。
- 根应用定向：`flutter test test/features/playback/macos_fullscreen_close_test.dart test/features/playback/playback_panel_test.dart test/features/playback/playback_session_test.dart test/app/workspace_router_test.dart` **771 项通过**。
- 四条判据各做过单点变异回红再恢复：`awaitSurfaceDetached` 改成直接返回 → 卸载用例在 `media_kit_video_output_test.dart:385` 失败；协调器里把 `stop` 提到 `detachSurface` 之前 → 顺序断言与"核心不被提前触碰"同时失败（`+4 -2`）；`_surfaceMounted()` 计数改成空实现 → 挂载/卸载配对两条同时失败（`+11 -2`）；协调器超时分支的 `return false` 改成 `return true` → 只有一条用例转红（`+5 -1`），即确认标志本身有判据在守。四次都改回后复跑，并用 `diff` 核对恢复后的文件与变异前逐字一致。

插件与构建侧（都是实跑，不是推断）：

- `./gradlew :media_kit_video:prepareBilisailMediaKitVideo :media_kit_video:testBilisailMediaKitVideoRelease` → **`media_kit_video surface release regression: 22 assertions passed`**，`BUILD SUCCESSFUL`。
- `./gradlew :media_kit_video:compileReleaseJavaWithJavac` → `BUILD SUCCESSFUL`；`javap` 读构建产物 `intermediates/javac/release/.../VideoOutputManager.class`，确认里面有 `pendingReleases` 字段与 `releaseNative(long)` 方法——证明编译的是改写副本而不是上游。
- **引脚守卫验证**：把 `apply.gradle` 里 `VideoOutput.java` 的期望值临时改成全 0，配置该任务立刻失败并打印 `media_kit_video VideoOutput.java changed; review the surface release ordering patch (got c2cd529f…, expected 0000…)`；改回后 `BUILD SUCCESSFUL`。
- `tool/test-android-media-kit-patch.ps1` → **`media_kit_video Android patch checks passed: 5`**（三条上游引脚/副本已改判据 + 正向回归 + 反向对照：把兜底延时改成 5000L 必须报 `Fallback must outlive the core's five-second destroy timer`）。已接进 `tool/check.ps1` 的 Lint 段，该段整体全绿（CI 计划 27、版本 41、签名 21、开发包身份 7、媒体通知资源 25、补丁 5；五个工程 `dart format` 共 871 文件 0 改动；`flutter analyze` No issues found）。
- 真机安装包已产出：`tool/build-android-development.ps1 -Mode Release -SkipMuxBuild` → `√ Built build\app\outputs\flutter-apk\app-arm64-v8a-release.apk (60.7MB)`，交付件 `build/development/android-arm64/BiliSail-test-arm64-release.apk`，63,677,572 字节，`68e7535df92f46b3b02c129c826a6744261614e4cc13581873afe6986d2c6c58`，身份 `dev.bilisail.bilisail.test` / `BiliSail 测试版` / `6.2.6+5` / VersionCode 62605 / 本机开发签名。
- **交付件级验证**：从该 APK 解出 `classes.dex`，`grep -a` 命中 `VideoOutputManager.ReleaseSurface`——补丁确实进了发布产物，不只是进了构建目录。

仍需用户在真机验证，且下列项**本轮完全没测**：装上这个 APK 后反复"播放→退出→回主页"，尤其在网络已卡住／缓冲中转圈时退出；停止预览后超过 6 秒的窗口内是否仍有卡死、进程消失、释放停滞或资源增长；`ReleaseSurface` 通路在真机上是否被真正调用（本轮只证明了它存在于产物与单测桩里，没证明运行时调用）；全屏／非全屏切换、多标签并发、页面回收与超时换备用地址路径；卓易通容器内的同一行为；`mpv_terminate_destroy` 落在已停止核心上的实际耗时没有测量。单测与静态分析证明的是 Dart 侧顺序与有界性，dex 与 `javap` 证明的是补丁进入了产物，**都不等于原生竞态在设备上已被观测消除**。

残余风险（明确保留）：`mpv_terminate_destroy` 仍由 media_kit 内部那个不可取消、不可等待的 5 秒裸 `Timer` 在 UI 线程执行。本轮把它的前置条件从"赌核心已收尾"改成"确认核心已放下输出"，并把原生表面的退休时机改成"确认后立刻、确认不了就晚于核心"，但没有、也无法让核心销毁本身变成可等待的。若要在设备上再压一层，只能改 `media_kit` 核心侧的销毁路径（本树不做）。

## 2026-11-05 更正：插件层补丁由上游首帧机制承接（F84）

**变化：** 并入上游 `f464c55`（Android 灰黑／单色首帧）时，两条插件补丁撞在同一批文件上：本节的 `android/patches/media_kit_video/apply.gradle` 与上游的 `android/patches/media_kit/first-frame.gradle` 都把 `media_kit_video` 的 Java 源同步进**同一个**构建副本目录 `build/bilisail-patched-java`，各自 `sources.setSrcDirs(...)` 指回它，并且各自仍按未改写的上游原件哈希（`VideoOutput.java` 同为 `c2cd529f…`）做引脚校验。按用户决定「上游机制直接顶掉」，本节的 `android/patches/media_kit_video/`（三个改写副本 + `apply.gradle` + `SurfaceReleaseOrderingTest.java`）与 `tool/test-android-media-kit-patch.ps1`（含 `tool/check.ps1` Lint 段接线）已删除，插件层只留 `patches/media_kit/first-frame.gradle` 一条管线。

**撞车的形态（按两份脚本的源码读出来，未实跑复现）**：两条都接线时，后注册的那条把前一条的改写副本当作同步源（`srcDirs` 已被前一条改指到副本目录），于是要么 `Sync` 的 from 与 into 同为该目录，要么引脚校验对着一份已被改写过的文件失败——表现为 Android 构建直接报错，而不是无声丢补丁。上一轮口头描述里的"静默丢掉一份补丁"说重了，在此更正。

**因此不再成立的：**

| 项 | 现状 |
| --- | --- |
| `VideoOutput.dispose()` 的停放（纹理条目 + `Surface` + JNI 引用三项一起排队、6 秒兜底） | 已无，插件回到 `Player.dispose()` 内立即释放 |
| `VideoOutputManager.releaseNative(handle)` 与通道分支 `VideoOutputManager.ReleaseSurface` | 已无 |
| `MediaKitVideoOutput.releaseAndroidSurface()` 及引擎里"确认过才另发一次退休"的分支 | 已删除——通道无人处理，留着只会每次都走 `MissingPluginException` 兼容分支 |
| 上面"本轮检查"里的 gradle `22 assertions passed`、`javap` 读到 `pendingReleases`、APK `classes.dex` 命中 `ReleaseSurface` 三条证据 | 对本树不再成立 |
| "核心卡住时表面退休晚于核心"这半边保障 | 没有了，只剩"确认核心已放下输出后才发起销毁" |

**仍然保留的 Dart 侧（不受本次替换影响）：** `_SurfacePresence` 挂载计数与 `awaitSurfaceDetached()`；`releaseAndroidOutput()` 的 `detachSurface → stop(3s) → 轮询 current-vo(600ms/20ms)`，仍在 `old.dispose()` 之前执行，只是其返回值不再驱动任何通道调用；`playback_manager.dart:92` 的收口修正。

**锚点预检（本机实测）：** 用一支临时脚本从 `first-frame.gradle` 自身解析出 7 处 `replace()` 锚点与三份引脚哈希（锚点不手抄），逐条在 `pubspec.lock` 指向的 `fd8421d2` Pub 缓存副本里计数，结果 `anchor checks run: 7, failures: 0`。反向对照：把首条锚点末尾多写一个空格，命中数变 0，判据即报缺。注意 `73771ec3` 那份缓存的三份 Java 与 `fd8421d2` 逐字节相同，因此"换一份缓存也能过"不能当作判据有效的证据。真正的 `:media_kit_video` 编译与真机首帧回归仍未跑。
