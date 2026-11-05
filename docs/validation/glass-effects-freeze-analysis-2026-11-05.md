# 液态玻璃开关卡死分析与滤镜缓存/启动预热修复

日期：2026-11-05。基线源码：`e623581`。

## 问题

设置页「液态玻璃底栏」和「视频条目液态卡片」两个开关被怀疑打开后让页面卡死 3~5 秒。需要分别判定每个开关是否存在卡死路径，并对确有的路径做最小修复。两个开关的定义见 [app_settings.dart](../../lib/features/settings/domain/app_settings.dart)，设置页入口见 [settings_screen.dart:326](../../lib/features/settings/presentation/settings_screen.dart)。

## 逐个开关的定位

### 视频条目液态卡片（`liquidVideoCards`）——无卡死路径

- 令牌只参与绘制：`VideoCardSurface` 是 ThemeExtension，只带渐变、发丝线和阴影数值；卡片按它画 `BoxDecoration`（[video_card.dart:479](../../lib/shared/ui/video_card.dart)），不采样背景。
- App 内 `BackdropFilter` 控件用法 0 处：5 处出现全部是注释，分布在 [app_notice.dart:142](../../lib/shared/ui/app_notice.dart)、[liquid_pull_refresh.dart:26](../../lib/shared/ui/liquid_pull_refresh.dart)、[video_card.dart:476](../../lib/shared/ui/video_card.dart)、[video_card_surface.dart:9](../../lib/shared/ui/video_card_surface.dart)、[app_settings.dart:223](../../lib/features/settings/domain/app_settings.dart)，内容都是说明「刻意不用」——网格会在每个滚动帧为每张可见卡采样一次背景。
- 保存路径是异步乐观更新：开关 → 控制器 update → 排队写 SQLite，不阻塞 UI 线程。
- 主题切换重建被拦住：`VideoCardSurface` 实现了 `==`/`hashCode`，`AnimatedTheme` 的分步 lerp 不改变令牌值，卡片不会因切换动画逐帧重建。

### 液态玻璃底栏（`liquidGlassDock`）——有卡死量级路径，但不阻塞 UI 线程

底栏由独立包 `liquid_dock_navi` 提供。先排除 UI 线程阻塞：透镜着色器加载是异步且带 try/catch（[liquid_lens.dart:18](../../../liquid_dock_navi/lib/src/liquid_lens.dart)），拖拽弹簧动画的 ticker 有界（[dock_navi.dart:157](../../../liquid_dock_navi/lib/src/dock_navi.dart)）。代价集中在栅格线程，共四条：

| # | 路径 | 代码位置 | 代价 |
| --- | --- | --- | --- |
| ① | 底栏自身 `BackdropFilter` | [dock_navi.dart:562](../../../liquid_dock_navi/lib/src/dock_navi.dart) | 整条一次 backdrop 采样+模糊 |
| ② | 边缘折射透镜常开，自身也是 `BackdropFilterLayer` | [dock_navi.dart:576](../../../liquid_dock_navi/lib/src/dock_navi.dart) | 又一层全尺寸 backdrop 采样 |
| ③ | 首次用透镜片元着色器出图 | [liquid_lens.dart:258](../../../liquid_dock_navi/lib/src/liquid_lens.dart) | 驱动侧建 pipeline（PSO） |
| ④ | 每帧新建 `ui.ImageFilter.shader`（修复前 `_buildFilter` 无缓存） | 同上 | 每动画/滚动帧分配新滤镜对象 |

①②是持续开销：底栏出现和拖拽时每帧两次全尺寸 backdrop 过滤，弱 GPU 栈上表现为掉帧而不是卡死；③④中，能量级上能解释「3~5 秒卡死」的只有 ③。

**③ 的机制**：`ui.FragmentProgram` 由 impellerc 在构建期编译成目标后端字节码，但驱动侧的 pipeline（PSO）要等该着色器第一次真正被栅格化时才创建；部分驱动栈上这次创建可达数秒，且发生在栅格线程。修复前它落在「开关打开后底栏第一次画出折射带」那一帧（或冷启动首帧），与「打开开关页面就卡死几秒」的观察完全重合。F83 记录的播放退出卡死是原生释放路径的另一机制，与本条无关。

## 修复

按选定方向「滤镜复用 + 启动预热」，不改两个开关的语义、默认值和底栏视觉：

1. **滤镜复用**：`_buildFilter()` 增加 uniform 记录缓存（[liquid_lens.dart:252](../../../liquid_dock_navi/lib/src/liquid_lens.dart)）——uniform 全部未变则复用同一个 `ui.ImageFilter.shader`，不再每帧新建；`program` setter 同步清缓存，避免复用指向已释放着色器的滤镜。
2. **启动预热**：`LiquidDockLensShader.warmUp()`（[liquid_lens.dart:40](../../../liquid_dock_navi/lib/src/liquid_lens.dart)）用 1×1 离屏渲染驱动一次 PSO 编译；由 [bili_app.dart:362](../../lib/app/bili_app.dart) 在首帧后调用一次，与交互路径分离；预热失败仅 `debugPrint`，着色器不可用时 no-op。

被否掉的方案：删特效层（用户要保留效果）、切换时同步阻塞加载（把停顿移到切换时刻更明显）、降采样（降画质且与编译停顿无关）。

## 已核

- `liquid_dock_navi`：`dart format` 干净；`flutter analyze` 干净；`flutter test` 20/20 通过。
- 根应用：`flutter analyze` 无问题；`liquid_glass_dock_setting_test`、`dock_selection_test`、`dock_entries_test`、`shell_layout_test` 四件合并复跑 **74/74** 通过（其中 `shell_layout_test` 67 项）。
- 代码级定位：两个开关的读写路径、`BackdropFilter` 使用面（控件 0 处、注释 5 处）、主题切换重建路径、底栏四条栅格路径逐一核对。

## 未验证

- 无 Android 实机：预热是否真的命中同一 PSO、3~5 秒卡死是否消失，均未测量；需在有问题的设备上对照开/关开关与冷启动复测。
- 视觉回归：滤镜复用不改变 uniform 语义，但边缘折射的实际观感未在设备上复核。
- ①②两条持续开销的实际帧率影响未测量，本轮只消除了 ③④。
