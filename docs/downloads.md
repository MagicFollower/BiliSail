# 下载与离线播放方案

日期：2026-10-07。下列是本轮实施方案，验收结果另列于文末；不能从参考项目或插件支持列表推导三端后台下载已完成。

2026-10-09 按用户选择接入独立精简封装组件与“合并为单个 MP4”选项；保留分轨方式和旧任务。依赖核对见[文件封装能力评估](validation/download-muxing-evaluation.md)，实现与手动构建步骤见[合并验收记录](validation/download-muxing-results.md)。

2026-10-11 下载窗口改为“保存格式”：音视频分轨（默认）／合并 MP4／合并 MKV。两种封装使用同一精简组件、取消与提交链路；合并文件按单文件媒体打开，修复旧 MP4 被当作缺音轨 DASH 而报“未取得点播音频轨道”的问题。旧 MP4 完成项无需重新下载；本轮验证见[封装与离线播放修复](validation/download-muxing-results.md#mp4-离线播放修复与-mkv2026-10-11)。

## 功能与界面

- 普通视频按分 P、影视按可播放剧集多选；读取当前账号实际返回的清晰度，选择清晰度与视频编码，保存 AAC 音频。不存在选定轨道时明确失败，避免任务悄悄降画质。
- 下载中心沿用当前 Material 3 主题、粉色强调色、圆角、封面比例与字体。2026-10-25 统一为消息／设置页的顶部标题和下划线分类标签，队列／已完成标签各自显示数量。内容区宽度小于 600 时，刷新／设置入口与分类标签同排靠右；较宽布局仍放在标题右侧。大字体下分类标签可横向滚动，两个操作入口保持可见；嵌入“我的”页且不显示标题时，不额外占用空标题行。搜索与批量暂停／继续在宽屏同排、窄屏或大字体下分行；窗口宽度变化保留搜索文字。任务卡分层显示标题、分 P／剧集、画质／编码／格式、状态、字节、速度与进度，宽屏将状态和操作同排，窄屏操作区换行。全部颜色复用现有明暗主题；下载、筛选、批量操作、删除确认与离线播放逻辑保持原有行为。
- 设置默认同时下载两项，可选 1–3 项；默认应用文档目录中的独立离线目录，桌面可指定后续任务目录，已有任务保留原目录。离线文件不受普通缓存清理影响。
- 本地完成项可打开专属离线播放标签，共用现有 PlaybackSession、PlaybackManager 与播放器控件；离线播放读取本地音视频、字幕、弹幕和封面，不依赖详情/播放/云进度网络请求。
- 删除前显示任务名称，并明确选择是否删除文件。暂停、失败、重启恢复都保留断点；重启后等待用户继续，避免启动时立即占用网络。未完成队列最多 500 项；超出剩余容量整批拒绝，并发添加同一内容/画质/编码只创建一项。

## 状态与边界

`downloads/domain` 持有不可变任务、内容身份、轨道和仓储契约；`data` 实现 Web 源解析、SQLite 索引、受限 HTTP 续传和文件校验；`application` 为进程级服务提供 UI 控制器；`presentation` 只消费领域状态及控制器。`app` 负责下载入口、账号变化、退出、离线播放器和平台文件夹能力的组合。

状态为排队 → 解析 → 下载 → 校验 → 可选合并 → 完成；暂停和失败可显式恢复。任务和文件按账号 scope 隔离，异步操作同时核对 session epoch 和运行代次。账号变化立即取消旧解析/传输，完成的离线媒体保留在原账号下；新账号不会看到或继续旧账号任务。

SQLite 版本由 2 增至 3，保留设置与历史，增加下载索引；任务只保存内容/轨道身份、相对文件名、断点和校验信息，不保存签名 URL 或凭据。每次恢复重新请求 Web 播放信息。旧记录与分轨选择保留独立本地文件；可选合并由随应用携带的精简组件执行无损封装，输出和索引提交后清理分轨。无需用户安装完整 FFmpeg，也不进行转码。

传输要求：系统 TLS；媒体请求仅带 Referer/User-Agent，不带 API Cookie；有限重定向、连接/读超时和取消；续传验证 HTTP 206、Content-Range 起始/结束/总长以及对象身份；遇到不支持 Range 的 200 安全从头重下；无法确认同一资源时丢弃旧片段重下。下载结束核对长度并计算 SHA-256，临时文件刷新/关闭后原子改名，写完成 manifest 后再更新 SQLite。启动与离线打开复核本地文件，处理断电、强杀、文件丢失和 DB/文件提交窗口。

续传语义按 [RFC 9110 的 Range/Content-Range](https://www.rfc-editor.org/rfc/rfc9110.html#name-range) 实现，客户端生命周期依据 [Dart HttpClient](https://api.dart.dev/dart-io/HttpClient-class.html)。每轮轨道传输最多 6 次 HTTP 尝试；整个任务最多刷新一次源，因此每轨最多两轮、12 次 HTTP 尝试。双轨传输共用 3 小时总 deadline，连接与每次读均独立超时。哈希计算在 isolate，启动只复核轻量索引/文件信息，离线打开和完成时进行完整校验。

封面、字幕和普通弹幕各自限量并允许降级，缺失显示警告而不使已完整音视频失效。离线附属文件只保存正文，不保存远端媒体/字幕地址或会话信息。后台/休眠/系统服务能力不从前台 HTTP 实现推导，Android/macOS 设备验证单独记录。

## 参考来源与采用范围

只读参考 `biliuwp-lite` 的 `Controls/Dialogs/DownloadDialog.xaml.cs`、`ViewModels/Download/DownloadDialogViewModel.cs`、`Services/BackgroundDownloadService.cs`、`Services/DownloadService.cs` 与 `Models/Download/*` 的选集、轨道、附属文件和队列职责；参考 `bili-kernel/src/Services/Services.Media/Core/PlayerClient.cs` 的 UGC/PGC DASH 解析与公开模型。参考仓库提交及许可限制沿用 [参考文档](references.md)。独立编写 Dart/Flutter，不复制 C#/XAML、资源或引入相邻仓库运行时依赖；界面按本项目主题设计。

沿用既有 Web GET `/x/player/playurl`、`/pgc/player/web/playurl`、`/x/player/wbi/v2`、`/x/v2/dm/web/seg.so` 和公开字幕 JSON。API 请求沿用 Cookie 可选、WBI 按端点、25 秒 deadline 和取消；内容权益按服务端结果执行。不会使用参考 App/TV token 或绕过 PGC 地区/会员权限。

## 验收记录

2026-10-07，Windows x64 主机、Flutter 3.47.6：

| 验证 | 结果与边界 |
| --- | --- |
| `tool/check.ps1` | 格式及静态分析通过；根应用 945、bili_api 282、bili_player 22、bili_danmaku 32 项测试通过，共 1,281 项 |
| 下载协议与队列回归 | 覆盖 200 忽略 Range、206 范围/长度错误及分段响应、强 ETag 改变、416、取消真实断点、过期地址刷新与双轨重置、重启/文件损坏、账号切换和删除竞态、后台数据库故障、非零速度；v1/v2 数据库升级保留设置与历史 |
| 界面与离线适配器 | 多选、共同画质、旧请求取消、账号变化、删除文件选择、离线文件校验前不挂载播放器；320/390/1000 宽度与大字体检查。静态预览使用项目 HarmonyOS Sans 字体复核，不等同于发布窗口操作验收 |
| Windows 原生离线 | `flutter test integration_test/windows_downloads_test.dart -d windows` 通过；真实 HTTP 下载合成分轨、重开 SQLite、关闭服务器后用 media_kit 播放本地音视频、字幕和弹幕，seek/播放/暂停通过；无远端源重解析或云进度读写 |
| Windows x64 Release | `flutter build windows --release` 通过；入口为 `build/windows/x64/runner/Release/bilisail.exe`，分发需保留整个 Release 目录。本轮没有替换已安装版本或发布 Release |
| Android arm64 Debug | `flutter build apk --debug --target-platform android-arm64` 通过；产物为 `build/app/outputs/flutter-apk/app-debug.apk`。未安装到设备，不能据此确认下载、离线解码或后台行为通过 |
| Windows 游客公网下载 | `flutter test integration_test/windows_downloads_online_probe_test.dart -d windows --dart-define=BILI_DOWNLOAD_ONLINE=true` 通过；公开 UGC 的实际可用 360P（qn 16）双轨完整下载 14,700,421 字节，本地 SHA-256 复核通过，附属下载警告为 0。没有加载登录凭据或执行账号写操作；此探针默认跳过，不进入常规离线 CI |

macOS 构建、Android/macOS 设备离线播放、真实登录账号/会员 PGC 下载、公网长视频断网/休眠恢复和发布窗口鼠标操作尚未验收。Android 退入后台主动暂停当前应用下载；未实现系统下载服务、后台保活或系统通知，不能声称具备这些能力。暂停或重启后的资源若缺少强 ETag，会保留记录后安全从头重新下载该轨，避免拼接不同对象。

### 2026-10-25 下载页样式与布局

仅调整下载中心的展示层，复用共享分类标签和现有主题；下载控制器、仓储、协议、状态流转及删除确认保持原有实现。

- `tool/check.ps1 -SkipPub` 通过：根应用 2696、bili_api 456、bili_player 81、bili_danmaku 93、bili_mux 2 项，共 3328 项通过；格式、静态分析和打包边界检查通过。10 项 mux 原生测试因未设置 `BILI_MUX_LIBRARY` 跳过，不计为原生封装通过。日志：`build/downloads-style-check.log`。
- 下载页和账号工作区定向 34 项通过，覆盖暂停／重试、删除取消与文件选择、进度动画、窄屏／大字体、离线入口和页面状态保留；最终下载页专项 16 项复测通过。日志：`build/downloads-style-targeted.log`、`build/validation/downloads-style/final-ui.log`。
- 使用应用字体和明暗主题，检查 320／390／600／1000／1440 宽度的队列与完成列表，共 20 张静态渲染；320 宽度同时使用 1.5 倍文字。10 项渲染场景均复查宽窄布局切换后的搜索文字和筛选结果保留，无布局异常。截图与日志：`build/validation/downloads-style/`。这些是 fake 数据的组件渲染，不代表真实窗口或设备验收。

未构建安装包或操作真实客户端；当前没有可连接的 Dart 调试进程，无法执行热重载。Windows、Android、macOS 实际窗口与触控体验仍待运行构建确认。

同日按窄屏反馈，将刷新／设置移至子标签行右侧，内容区 600 及以上仍使用标题右侧布局。下载页与工作区定向 34 项通过；明暗主题的 320／390／599／600／1000／1440 宽度共 12 个渲染场景通过，包含 320 宽度的 1.5 倍文字、599／600 边界、无标题嵌入模式、宽窄切换后的搜索保留，以及窄屏按钮与标签同行的位置检查。输出：`build/downloads-compact-header-targeted.log`、`build/validation/downloads-compact-header/`。仍仅为组件渲染，未打包或实机操作。

此次微调后的 `tool/check.ps1 -SkipPub` 再次通过：3328 项测试、格式、静态分析及打包边界检查通过，10 项 mux 原生测试仍因未配置 `BILI_MUX_LIBRARY` 跳过。日志：`build/downloads-compact-header-check.log`。


### 2026-10-26 Android 默认下载路径校验

Android 默认目录仍由 `getApplicationDocumentsDirectory()` 提供，追加
`BiliSail/offline`；锁定的 `path_provider_android 2.3.1` 通过 JNI 调用
`Context.getDir("flutter", MODE_PRIVATE)`，不是 `/sdcard` 或公共 Download。
旧实现对完整祖先链一直检查到 `/`，把所有非 directory 结果（包括查找失败的
notFound）都报为符号链接，可能误拒绝系统合法路径别名或不可查询的祖先。

组合根向 `DownloadFileStore` 注入 Android 平台提供的应用文档目录作为可信锚点。
默认路径直接使用平台给出的锚点，不强制 realpath，以免解析本身再次查询受限
系统祖先。仅当旧记录使用不同锚点写法时，解析双方并要求指向同一目录；解析
失败不放宽。所有 I/O 使用平台锚点，从 `BiliSail/offline` 到 scope/task 逐级无链接检查，
先验证父目录再创建子目录。下载子树中的链接（含指向子树内部的链接）不获豁免。
其他平台仍使用原来的全祖先边界；非法任务 ID、`..`、错误目录布局、任意其他
DB 根路径不能借此成为受信目录。

新建、续传、封装文件访问、离线校验和删除共用文件存储校验。文件名白名单、
归属标记、媒体/临时文件链接拒绝和递归删除前子树检查保留。旧任务保留原目录
记录及媒体，不迁移文件、不清设置、不增加系统权限；无法证明属于当前应用
锚点的旧路径安全拒绝。目录缺失/不可访问、非目录和真实链接使用不同提示。

新增文件存储正反向回归与仓储端到端回归：默认创建、平台锚点别名、旧路径
恢复/续传/离线打开/删除、错误根目录和越界、根/scope/task/media/tmp/归属标记
链接、悬空链接与外部文件不变。符号链接测试在 Linux CI 执行；Windows 无额外
建链权限时明确跳过。环境没有 Flutter/Dart SDK，本地仅完成代码审查、WASM
版 dart_style 格式化及 diff 检查，正式格式、分析和测试以分支 CI 为准。

尚未采集用户设备的首次失败祖先或安装验证，不能视作设备问题已复现。
最小诊断应包含版本、Android API、路径来源、脱敏后的平台/实际根路径、首次
失败节点及 no-follow 类型、解析错误码。该修复保持现有基于路径的 I/O 模型，
不宣称消除了拥有目录并发写权限的攻击者造成的检查/使用竞态；若扩展到
不可信共享存储，应另行评估目录句柄/no-follow 原生 I/O 或 SAF 适配。


## 2026-10-26：离线播放不做内容完整性门禁

按用户取舍，完成、打开、刷新和初始化不再读取完整媒体计算 SHA，也不比较完成文件的历史大小或修改时间。旧摘要仅兼容读取；新轨道以 committed 标识落盘提交，旧摘要非空记录兼容为已提交。用户修改媒体后仍交给播放器尝试，分轨缺失显示具体轨道错误。

账号和任务归属、受限文件名、符号链接及删除边界继续生效；HTTP Range/ETag/响应长度仍用于传输正确性。私有临时文件刷新关闭及改名后才记录提交，不因播放器错误删除文件。旧文档中的“打开时完整校验”由本节取代。

新增/调整回归覆盖分轨修改、刷新和重启、合并文件修改、原分轨清理及缺音轨错误。当前执行环境无 Flutter/Dart SDK，SDK 下载代理返回 HTTP 403；本地仅做 WASM Dart 格式预检和差异检查，正式分析/单测由分支 CI 验证。Android 实机未验证。

原生合并器也取消了写完后重读整个输出并比较压缩包 SHA 的运行时强核验。保留封装所需的输入轨道/编码识别、包大小限制、读写和 trailer/close 错误、取消及截止时间。CI 原生封装回归仍独立比较音视频包内容/时间戳，用于验证实现正确性，不作为用户媒体的播放门禁。


## 2026-10-26：Android 公共保存位置

首次下载只提供文件夹选择，不再提供默认 Downloads/BiliSail 或推荐保存位置。应用内选择器复用 Material 主题、粉色强调色及明暗外观，浏览内部存储和可用外部存储，支持进入文件夹、返回上一级并明确确认当前文件夹；取消不添加任务。用户选择持久保存，设置修改仅影响新任务；旧任务不迁移。

Android 11+ 的 SAF 即使获得“所有文件访问权限”也不能选择 Downloads 根目录，因此本轮按用户要求采用获得存储授权后的本地文件夹浏览器。Android 11+ 在系统设置页申请 MANAGE_EXTERNAL_STORAGE，并在返回后通过 Environment.isExternalStorageManager() 确认实际状态；Android 6–10 申请 READ/WRITE_EXTERNAL_STORAGE（maxSdkVersion=29），Android 10 使用 requestLegacyExternalStorage。拒绝、撤销或不再询问时显示重新授权入口，未授权不读取文件夹或保存新位置。权限申请仅由打开文件夹选择流程触发，不在启动时申请。依据 [Android 所有文件访问](https://developer.android.com/training/data-storage/manage-all-files) 和 [SAF 目录限制](https://developer.android.com/training/data-storage/shared/documents-files#document-tree-access-restrictions)。

私有 .part 维持续传和原生合并，最终媒体流式写入用户确认的文件夹，使用 <taskId>_video.m4s / audio.m4s 或合并文件；不额外创建 BiliSail 默认目录。选定前用独占临时文件检查写入能力，随后清理探针；创建媒体也使用独占创建，不覆盖现有文件。平台返回的共享存储根作为可信锚点，仅遍历其下目录，拒绝点路径、符号链接及 Android 私有目录。每次最多显示 2000 个子文件夹并提示截断。原生私有日志逐个记录创建的 URI，失败保留原文件，重试只清理自己的未提交条目；已发布记录重复调用返回原 URI。SQLite 持久保存 URI 后才清理私有媒体，字幕/弹幕及归属信息仍私有。旧 MediaStore/SAF 任务继续按原有 URI 读取与删除，旧默认目的地不再用于新任务，必须重新明确选择文件夹。

新任务通过本地 file URI 播放；旧公共任务继续通过 ContentResolver 只读 FD，主视频及外部音轨分别持有句柄直到 mpv 释放；不在播放前复制媒体。仅支持可 seek 的提供者，流式管道给出明确错误。原生仅打开本应用发布日志中的 URI；删除检查选定文件夹及精确任务文件名，旧任务检查 MediaStore 相对位置或 SAF 子树归属，不递归公共目录。存储撤销、离线、空间不足保留任务和可恢复私有源。公共文件通常保留至卸载后，但任务数据库和授权不恢复；没有自动重新导入功能。

发布阶段需额外写出及峰值双份空间；多轨发布不是跨文件原子事务。提供者创建成功到私有日志落盘之间存在系统 API 无法原子提交的极小窗口，进程在此时终止可能留下孤立条目，应用不会通过广泛扫描/删除来冒险清理它。

验证包括仓储公共提交/重启/授权恢复/发布失败重试，以及播放器双轨 FD 生命周期测试。

本轮在 master 整合原 feat/android-public-downloads 分支并修复选择器：

- 下载选择器、下载页面、仓储、文件边界和离线播放定向测试 77 项通过；Windows 缺少建链权限，13 项符号链接测试明确跳过。新选择器覆盖无默认位置、授权先于浏览、拒绝后重新授权、明确选择 Downloads 根目录、上一级导航、保存失败重试、取消和重复操作保护。320/390 宽度的明暗主题共 4 张静态预览通过，320 使用 1.5 倍文字；输出在 `build/validation/android-download-folder/`，日志 `build/android-download-targeted.log`。
- 下载相关 Dart 文件和新增设备测试静态分析无错误；相关格式与 `git diff --check` 通过。四个包共 641 项测试通过（bili_api 460、bili_player 83、bili_danmaku 93、bili_mux 5）；10 项 mux 原生测试未配置 BILI_MUX_LIBRARY 而跳过。日志 `build/android-download-package-tests.log`。
- Android arm64 的 mux 组件重建及完整应用 Debug APK 构建通过，日志 `build/android-download-mux-build.log`、`build/android-download-apk-build.log`。Android 16/API 36 x86_64 临时只读模拟器中，选定 Downloads 根目录后的真实发布/读取/重复提交/精确删除，以及旧 MediaStore 发布/只读 FD/删除，共 2 项集成测试通过；不存在账号或网络写操作。第二轮还观察到真实系统授权设置页打开，再由测试宿主授予该模拟器的 app-op 并关闭设置页，原生返回后继续测试；这不等同于用户手动切换权限或厂商系统实机验收。日志 `build/android-download-device-test.log`、`build/android-download-permission-activity.log`。
- 模拟器暴露旧 MediaStore 条目尚未首次打开写入流时无法读取的问题，现先创建底层文件再检查可 seek，仍在复制媒体之前拒绝流式提供者。
- 已执行 `tool/check.ps1 -SkipPub`，被同期其他任务文件的格式检查阻塞；单独运行根测试为 2852 项通过、13 项跳过，`primary_switch_layout_test.dart` 的保留页面尺寸断言失败（390×682 与 390×734），属于同期导航改动，未修改这些文件。日志 `build/android-download-check.log`、`build/android-download-root-tests.log`。本轮无可连接的 DTD 调试进程，未执行热重载；原生改动需重新安装构建。

Android 6–10 权限窗口、厂商 Android 实机、可移除设备/拔出恢复和实际媒体解码仍需验收；不将 mock、模拟器或编译结果视为这些项目通过。

## 2026-11-02：每个分 P 一个可读目录，弹幕字幕与清单随媒体同放

按用户要求，下载不再只在公共目录留一个媒体文件，而是**每个分 P 一个可读目录，媒体与弹幕字幕清单放在一起**，为"重装应用后指向同一目录即可重新识别"做铺垫。本条只完成发布面，扫描导入尚未实现。

目录形态（`<目的地>/` 下）：

```
BV1gDEUuUZA-P3 视频标题/
  media.mp4 | media.mkv | video.m4s + audio.m4s
  extras.json      弹幕与字幕正文（version 1，见下）
  cover.img        封面，存在才发布
  manifest.json    自描述清单（version 3）
```

- 目录名由 `lib/features/downloads/domain/download_folder_name.dart` 生成：`<bvid>-P<页码> <清洗后的标题>`，`\/:*?"<>|` 与控制字符换成空格并折叠，去掉结尾的点和空格，整体限 160 字节并给冲突后缀留出余量；标题全被清掉时退回 `<bvid>-P<页码>`。截断只停在码点之间，不会把多字节字符切成非法 UTF-8。
- 冲突由平台层判定：MediaStore 查同 `RELATIVE_PATH` 是否已有条目，SAF 列树根子项，`file:` 直接看路径是否存在，占用则追加 `-2`、`-3`…（上限 99）。**目录名不是身份**，身份是 `manifest.json` 里的 `id`。
- `manifest.json` 升到 version 3：新增 `video`/`part`/`aid`/`createdAtMs`/`output` 与 `extras`/`cover` 的字节数，**删除 `scope`**——该文件现在会落到共享存储，不能带账号标识；同时继续不含任何签名地址或会话信息（既有约束）。
- `extras.json` 仍是弹幕与字幕的唯一载体：`{version:1, comments:[{id,positionMs,text,mode,color,fontSize,weight}], subtitles:[{label,cues:[{startMs,endMs,text}]}], warnings:[…]}`，上限 60000 条弹幕、16 条字幕轨道、整体 32 MB。它只在应用私有目录时会被卸载连带清除，这正是本条把它发布出去的动机。
- 三条发布分支（MediaStore `downloads`、SAF 树、`file:` 路径）都改为建子目录，文件用裸名；此前 SAF 与 `file:` 是在目的地根下平铺 `<taskId>_<name>`。`checkBoundary` 按清单记录里的 `folderPath`/`relativePath`/`folderDocId` 校验，**旧的平铺 journal 仍可校验、读取与删除**（缺字段时回落到 `<taskId>_<name>` 推导）。
- 删除任务时，`file:` 与 SAF 分支会连带删掉我们创建且已空的目录；用户自己往里放过东西的目录保留不删。MediaStore 无法删目录，该模式下会留下一个空文件夹。
- 发布集合从"只有媒体"变成"媒体 + 清单 + 附属"，因此 `publicFiles` 的键集合随之变宽；私有目录仍是离线播放的读取源，本条不改变读取路径。

已知边界与本条未做的事：

- **扫描导入尚未实现**：现在只是把可识别的东西放出去了，重装后指向同一目录还不会自动出现在下载列表里。
- MediaStore 的空目录不计入冲突判定（只查有没有条目），所以同一分 P 重新下载且旧目录已空时可能复用同名目录；同名文件由系统加 `(1)` 后缀，不会覆盖，但会在同一目录里留下两份。
- SAF 的云盘类 provider 可能不支持建子目录，此时发布直接失败并提示改用其他位置，未做"回退平铺"。
- 验收：目录命名规则由 `test/features/downloads/download_folder_name_test.dart` 6 项钉住（形状、非法字符、空白折叠、结尾点/空格、字节上限与码点完整性、冲突后缀余量）；清单 version 3、不含 `scope`、含 `extras` 字节数，以及发布集合含 sidecars，由 `sqlite_download_repository_test.dart` 断言；"只发布真正落地的附属文件（含 `cover.img`）"由 `download_file_store_test.dart` 断言。下载目录共 99 项通过、13 项跳过（Windows 建链权限），根应用全量 3935 项通过、13 项跳过。原生 `:app:compileDebugKotlin` 编译通过。**Android 真机上三种目的地的实际目录形态、旧任务兼容与删除行为未验收**，需重新出包后在设备上确认；原生里"旧平铺 journal 回落推导"只有编译与代码走查覆盖，没有仪器测试。

## 2026-11-02：下载设置显示当前配置的目录

按用户要求，「下载设置」对话框此前只有一个"公共下载位置（更改仅影响新任务）"按钮，看不出当前到底配到哪儿，桌面端也只笼统说"默认保存在应用文档目录的离线文件夹"。现在对话框顶部显示**当前下载位置**一行，并说明每个分 P 一个子目录、媒体与弹幕字幕清单同放其中。

- 生效优先级与仓储一致：自定义目录（仅 `allowCustomDirectory` 且非空）→ 已选公共位置 → 应用默认目录；未选公共位置的 Android 显示"未选择公共下载位置，首次下载前会让你选择"。显示的是**已保存**的配置，不跟随输入框里的草稿改动，避免"看着改了其实没存"。
- 公共位置的三种存储形态统一由 `lib/features/downloads/domain/download_destination_label.dart` 翻译，否则用户会看到 `content://…/tree/primary%3ADownload…`：`downloads` 哨兵 → "系统下载目录（Download/BiliSail）"；`file:` URI → 去掉 `file://`、**解码 `%xx`**、去掉 Windows 盘符前的多余斜杠；SAF 树 URI → 解码文档 id 成"内部存储/…"或"存储卷 <uuid>/…"。无法识别的形态原样显示，不抛异常。
  - 中文目录名踩到的坑：`Uri.path` 返回的是**百分号编码**形式，且 `Uri.parse` 会把非 ASCII 自行编码成 `%E4%B8%8B…`，所以直接显示 `uri.path` 会让"下载"变成一串 `%xx`（`Uri.pathSegments` 才是解码的）。改用显式解码；不用 `Uri.toFilePath()` 是因为它还会按宿主平台重写分隔符，显示串不该随运行测试的机器变。解码失败（`Uri.decodeComponent` 对非法 `%` 抛的是 `ArgumentError`，不是 `FormatException`）时退回原串，只兜这两类，其余照抛。
- 桌面（Windows/macOS）且位置是真实路径时提供"打开目录"，走既有 `FileAccessService.openDirectory`；MediaStore 与 SAF 位置没有可交给 shell 的路径，因此不显示该按钮。
- 按钮文案改为"更改公共下载位置"，并删除与新增说明重复的旧兜底文案。
- 验收：`test/features/downloads/download_destination_label_test.dart` 8 项（空值、哨兵、Android 路径、Windows 盘符、SAF 主卷与可移除卷、**中文目录名在 `file:` 与 SAF 两种形态下都解码**、非法 `%` 转义退回原串、无 tree 段与未知 scheme 兜底）；`download_presentation_test.dart` 1 项断言对话框按 key 显示已保存的自定义目录（同文本也出现在下方输入框，因此按 `ValueKey` 定位而非文本）。下载目录共 108 项通过、13 项跳过（上一节 99 项为 P1 提交时数字），`flutter analyze` 无问题。**Android 上"已选公共位置"的实际显示文本未在设备验证**（widget 测试里公共存储为 null）。

## 2026-11-02：下载 tab 从共享目录扫描并导入离线内容

按用户要求，下载页要能"快速高效地从下载目录解析离线的数据显示"。此前 `refresh()` 只逐条核对数据库里已有的任务，共享目录中新出现的文件夹永远不会被发现；而重装后数据库是空的，列表就什么都没有。

新增 `DownloadRepository.scanShared()`：列出共享目录里的每个分 P 文件夹 → 读清单 → 校验 → 认领入库 → 把弹幕字幕取回私有目录。设置对话框加"扫描下载目录并导入"按钮并显示结果摘要，下载 tab 首次打开自动扫一次（仅当存在共享存储位置）。

快在哪里：

- **不是靠并发，是靠缓存**。`download_scan_cache(folder_key PRIMARY KEY, task_id, manifest_bytes, manifest_modified_ms, scanned_at_ms)`（数据库 `schemaVersion` 3 → 4，迁移步骤改为可链式：v1 补列 → v2 建下载表 → v3 建缓存表，`to` 非当前版本直接抛错）。二次扫描时，某文件夹的清单字节数与修改时间都没变、且该任务已在列表中且 completed，就**完全不读清单**，只做一次列表查询。
- 扫描按顺序执行是刻意的：读的是平台往返，而计数、会话守卫和缓存写入单线程才好恢复；半途中断（切账号、取消）只置 `aborted`，且**不裁剪缓存**，避免把没走到的文件夹的快路信息抹掉。
- 清单解析是纯函数（`download_manifest_scan.dart`，不碰网络/数据库/通道），需要时可整批丢进 isolate。

安全与归属边界：

- 只列目的地**下一层**、且必须含我们自己的 `manifest.json` 的目录；绝不递归用户其他子树。
- 清单里的媒体字节数必须与平台实际列出的**逐一对上**，对不上只拒绝并给原因，不会把截断/被替换的文件夹当成可播。`sha256` 只在长度完整时接受，截断的按"无摘要"处理。
- 三个新通道方法（`listFolders`、`readText`、`copyPublished`）共用 `requirePublishedSidecar`：证明目标 URI 确实是刚列出的那个目录的直接子项、且名字在 `manifest.json`/`extras.json` 之内——通道不能变成"调用方给什么路径就读什么"的通用文件读取器。
- **认领（adopt）**：`verify`/`openMedia`/`delete` 都依赖应用偏好里的 journal，而 journal 随卸载消失。扫描读到的 URI 会先逐个按目的地复检，再写回 journal，之后播放与删除沿用既有路径，不需要为导入项单开一套。复检失败则整条撤销，不留半截 journal。
- 归属：导入项记在当前账号名下；该 id 已属于别的账号时跳过并计入 `ownedElsewhere`，**不因为谁打开了 tab 就转移所有权**。
- 弹幕字幕以流式复制取回私有 `extras.json`（清单允许到 32 MB，读成字符串会造成几十 MB 瞬时占用），复制失败只降级报告，不影响已导入的媒体。

验收：`download_manifest_scan_test.dart` 6 项（合并/分轨接受、字节被截断拒绝、v2 清单与坏标识拒绝、轨道列表不完整拒绝、截断摘要按无摘要处理）；`sqlite_download_repository_test.dart` 新增 2 项端到端（导入一次后二次扫描 `unchanged=1` 且**清单读取请求数仍为 1**，证明快路真的没重读；字节不符则 `rejected=1` 且不入库不认领），并断言 `extras.json` 落回私有目录；`download_presentation_test.dart` 断言扫描按钮存在、点击后显示领域层措辞的摘要。数据库迁移新增 v3→v4 用例，既有 23 处 `schemaVersion` 断言随之抬到 4。下载目录 116 项通过、13 项跳过；`:app:compileDebugKotlin` 通过。

未验证：Android 真机上三种目的地（MediaStore / SAF / `file:`）的实际扫描与认领、可移除存储拔出时的表现、几百个文件夹时的首扫耗时；SAF provider 不支持子目录列举时的降级未取样。

## 2026-11-02：崩溃面包屑升级为跨进程诊断日志（schema 4→5）

现象（鸿蒙卓易通）：删除一条任务 → 清后台 → 重开 → 点下载 tab 就闪退；重开后再读是成功的。上一节的 `download-scan-breadcrumb` 单行没给出答案，**原因是它自己把证据擦了**：扫描成功收尾会 `_clearScanStage()`，而一次守卫是进程级的，崩后重开必然再扫一次并把上一个进程的停点覆盖掉——用户看到的"没有红色内容"正好是一次成功扫描的必然结果，不构成任何信息。另外 Release 里未捕获的 Dart 异常并不结束进程（`lib/main.dart` 只在 macOS smoke 分支接管错误，正常路径没有 zone/`exit`），所以"闪退"只可能来自原生层，只记 Dart 侧停点的红字本来就记不到它。

- 新增 `lib/core/diagnostics/diagnostics_log.dart` + 表 `diagnostics_events(id, run_id, at_ms, message)`（`schemaVersion` 4→5，`onUpgrade` 里 `from <= 4` 建表；v3 老库沿链路一并补齐）。每事件一条 `INSERT`，**不做整行读回再改写**：一次扫描要落几十条，重写一个几十 KB 的 settings 值会把被观察的那条路径本身拖慢，观察行为改变了被观察对象。启动时 `trim()` 只保留最近 3000 行；所有写入 `await`（还没提交就死的行等于没记），`_run` 吞掉自身异常，诊断不能把本来能用的操作弄坏。
- 锚点按"能不能跨过进程死"排：`进程启动` → `下载页进入` → `下载页首帧后` → `扫描请求` → `扫描 <stage> [目录]` → 每次公共存储调用 `原生 <method> →` / `←` / `✗ <code> <message>`。判据是那条 `→` 有没有配对的 `←`：调用没回来就死，死在 Kotlin 侧；只到 `下载页进入` 而没有 `扫描请求`，死在首帧构建/绘制；两者都没有，则与下载 tab 无关。
- 文本先洗后存：`scrub()` 去掉 URL query、凭据形状（`bili_jct` / `SESSDATA` / `access_key` / `cookie=` / `token=` 等）与 ≥24 位不透明串并截到 400 字；`describeError` 只留 `runtimeType` 与前 6 帧。Dart 侧 `FlutterError.onError` 与 `PlatformDispatcher.onError` 都写这里，早于数据库就绪的条目先进缓冲、`install()` 时补写。
- 查看口：设置 → 关于 → 「诊断日志」，弹窗按时间列出最近 600 条、每个进程以「进程启动」分隔，支持复制全部 / 刷新 / 清空。`DiagnosticsLog.instance == null`（单元测试、未走 `main` 的入口）时该行不渲染。日志只在本机 SQLite 里，不联网。
- 原生封口（顺手把两个能打死进程的口子堵上）：`DownloadStorageHandler` 的 worker 兜底从 `catch (Exception)` 抬到 `catch (Throwable)`，回投改成 `main.post { runCatching { result.* } }`。Android 上任一线程的未捕获 throwable 都会结束整个进程，`OutOfMemoryError` 与虚拟 provider 抛出的 `NoClassDefFoundError` 以前会从旧写法漏出去；现在翻成一次可见的 storage 失败并带上类名。
- 验收：`test/core/diagnostics/diagnostics_log_test.dart` 5 项（顺序与 run 归属、`limit` 取尾部而非头部、早于数据库的事件在 install 时补进表、`scrub` 四类、`describeError` 不带秘密）；`app_database_test.dart` 新增 v4→v5 用例，断言下载表与扫描缓存原样保留、新表初始为空、`user_version` 到 5；既有 23 处 `schemaVersion` 断言抬到 5。core + settings + downloads 共 612 项通过、13 项跳过，`flutter analyze` 无问题，`:app:compileDebugKotlin` 通过。
- 未验证：**崩溃原因仍未定位**，本轮交付的是观测手段与原生兜底；卓易通上的实际事件序列要等这一版装上后由「诊断日志」页面读出。MediaStore/SAF 两条目的地在真机上各扫一次的停点也尚未取样。

### 2026-11-02（同日第二轮）：日志读出的事实，与新增的原生停点

设备回读了 17:05 版的事件序列（从「诊断日志」页复制），三条事实：

1. **`原生 copyPublished →` 三次都没有配对的 `←`**：附属文件 `extras.json` 的复制调用从未返回。前两个进程并没有崩，只是这条 await 永久悬挂、扫描卡在那一步；队列与界面照常，所以看着像"什么都没发生"。
2. **同进程内两次扫描交叠**：第一次仍挂在 copyPublished 上，期间用户改过下载位置（日志里有 `原生 choose →/←`）并手动按了「扫描下载目录并导入」，第二次扫描完整跑完并打出 `扫描结束 目录=1 … 跳过=1 完成`。两条扫描共用同一个仓储、同一批 `taskLocks` 与同一个认领流程——这是可复现的交叠，不是设计里的并发。
3. **崩的那次停在 `原生 readText ←` 之后**：Dart 侧到 `扫描 adopt` 之间只剩解析清单、构造任务、建私有目录，这些杀不掉进程（Release 无 zone/`exit`，且 `Throwable` 兜底已在上一版生效）。所以要么读数被截图截尾，要么真死在原生调用里而日志还没写到位。

针对这三条补仪器，不猜修法：

- **原生停点**：`DownloadStorageHandler.step()` 把"现在做到哪一行"写进 `SharedPreferences`（`commit()` 同步落盘，进程被杀仍在），新增 `lastNativeStep` **在主线程直接回答、不进 worker 队列**——五条 worker 全卡住时仍然问得到。`listFolders` / `readText` / `copyPublished`（校验归属→查询大小→打开输入流→写临时文件→落盘→替换正式文件）/ `adopt`（写 journal→逐个校验 N/M→完成）/ `delete` 都打了点。
- Dart 侧：`scanShared` 开头把上一次的原生停点写进日志（`原生上次停在 …`），这是被杀进程唯一还能拿到的证据；被追踪的通道调用超过 20 秒未返回时，watchdog 记一条"仍在等待"并顺带再问一次当前停点。`PublicDownloadStorage` 因此多了 `lastNativeStep()`（无原生侧的平台返回 null）。
- 锚点补细到能判读窗口：`目的地 私有路径/系统下载库/SAF 树`、`缓存命中`、`清单已读 <目录> <字符数>`、`清单通过 <id>`、`清单拒绝`、`他号已认领`、`入库 <id>`、`附属文件已复制`、`已通知界面`。
- 查看口第一行改成 **「上一个进程停在：X」**——不再依赖滚动和肉眼找进程边界，也避免截图截尾丢掉关键行。
- 验收：`diagnostics_log_test.dart` 6 项（新增"崩溃边界取的是更早进程的**最新**一条，不是最旧一条"）；`sqlite_download_repository_test.dart` 的扫描用例从第一次扫描就装日志，断言原生停点、目的地形态、清单已读/通过、入库、缓存命中都进了表且最后一行是 `扫描结束`。core + settings + downloads 613 通过、13 跳过；`flutter analyze` 无问题；`:app:compileDebugKotlin` 通过。
- 下一版的判据：**copyPublished 究竟卡在哪一行**（`native-step` 会直接给出答案，最可疑的是 `resolver.openInputStream(file://…)` 与 `fd.sync()`/`renameTo` 在容器虚拟文件系统上的行为）；交叠扫描是否要在仓储侧加"同一时刻只跑一条"的闸门——本轮只记录，未改语义。

### 2026-11-02（同日第三轮）：症状确认为悬挂，修复制副本、加超时、拒绝重入

用户报出可复现症状，与第二轮读出的形状完全对上：**点「扫描下载目录并导入」后一直显示"正在扫描…"；关掉对话框后下载页能刷出视频；再进设置页显示"上次扫描未完成，停在…"**。三条各自说明一件事：视频能刷出来 = 认领与入库已经跑完（`_save` + `_emit` 在复制之前）；红字停着 = 扫描函数再没走到 `_clearScanStage()`；转圈不停 = 那条 `await` 永远不返回。所以这是**悬挂不是崩溃**，且悬挂点就是 `copyPublished`。顺带解释了上一轮的交叠：对话框每次重开都带着新的 `_scanning=false`，按钮于是可以反复按，每次都再起一条扫描。

- **复制路径改直读**（根因候选，也是本就不该绕的路）：`file:` 目的地的附属文件以前用 `resolver.openInputStream(file://…)` 逐块拷，等于每 64 KB 走一次 binder；清单读取对同一种目的地早就走 `File.readText` 直路。现在 `copyPublished` 与它一致：`uri.scheme == "file"` 用 `File(...).inputStream()`，其余仍走 resolver。
- **去掉 `fd.sync()`**：写入后强刷磁盘是容器数据目录（虚拟/FUSE 挂载）上另一个可能不返回的动作。这个文件是可重取的旁路副本，丢了下次扫描再抄一遍，不值得为它冒 fsync 的险；发布媒体文件的路径也没有 fsync。
- **有界调用加 60 秒超时**：`listFolders` / `readText` / `copyPublished` / `adopt` 的数据量都有上限（清单 256 KB、旁路 32 MB），超时后翻成 `AppFailure(storage, '公共下载目录没有响应，已放弃本次操作')`，扫描按"弹幕字幕未能取回"降级继续跑完，红字与转圈都能结束。`publish` / `verify` **不加**：搬一个媒体文件本来就可能超过任何值得等的时限。20 秒的 watchdog 仍会先记一条"仍在等待，停在：<原生停点>"。
- **仓储拒绝重入**：`_scanRunning` 为真时第二次 `scanShared` 直接返回 `DownloadScanResult(alreadyRunning: true)`，`summary` 说"上一次扫描仍在进行中，本次未启动。"；扫描本体挪进 `_scanPass`，外层 `try/finally` 放闸，**抛异常的那次也不会把闸永久关死**。没有另开一条"跳过扫描"的假失败路径，UI 也就拿不到第二份认领。

验收：新用例 `a second scan is refused while one is in flight and the gate is released`（替身 `listPublishedFolders` 挂在一个 Completer 上，用 `listReached` 确认第一条真的到了那里，再断言第二条 `alreadyRunning` 与文案；随后放行第一条得到 `imported=1`，然后让列目录抛错，再跑第三次必须正常返回 `unchanged=1`，证明异常路径也会放闸）。core + settings + downloads 614 通过、13 跳过；`flutter analyze` 无问题；`:app:compileDebugKotlin` 通过。

仍未验证：真机上 `file:` / MediaStore / SAF 三种目的地里挂住的那一种是哪一种（要看 `原生上次停在 …` 与 `目的地 …` 两行）；如果换成 SAF 目的地，`openInputStream` 直路改动帮不上，剩下的兜底就是 60 秒超时 + 不重入。`fd.sync()` 是不是真凶同样未经设备证实。

收窄范围的一条既有证据：17:05 版的日志里出现过 `原生 choose →/←`，而 `choose` 只有"选一个文件夹"这条路径会调用（MediaStore 与 SAF 各有自己的入口），所以那台设备的公共目的地应是 `file:`。同一目的地下的媒体发布走 `File.inputStream()` → `File.outputStream()` → `fd.sync()` 并成功了（视频就在目录里），说明 fsync 在那台机器上不像是阻塞点；而 `resolver.openInputStream(file://…)` 恰好是扫描路径里唯一把普通文件当 content URI 交给 provider 的调用。下一版的 `目的地 私有路径` 与 `原生 copyPublished ←` 两行会把这条推断证实或推翻。

### 2026-11-02（同日第四轮）：真因是回投负载，上一轮两条猜测被证据推翻

17:51 版带回的日志把结论翻转了。**上面那段推断是错的，这里显式更正**：

- 原生停点显示 `copyPublished 完成`——那个 `step()` 在 `renameTo` 之后才写，说明**校验归属、打开输入流、写临时文件、`fd.sync()`、替换正式文件全部跑完了**。所以 `openInputStream(file://…)` 和 fsync 都不是阻塞点，上一轮针对它们的两处修改建立在被推翻的假设上。
- 真正断的是**回投**：`when` 分支里只有 `"copyPublished" -> copyPublished(call)` 没有像 `adopt` / `verify` / `delete` 那样写 `; null`，于是 `value` 是 `kotlin.Unit`。`StandardMessageCodec` 编码不了它，`result.success(value)` 在主线程的 Runnable 里抛异常。
- 这一个 bug 同时解释了两件事：**加 `runCatching` 之前**，这个异常在主线程未捕获 → 系统结束进程 = 用户报的闪退；**加了之后**，异常被吞 → 回复永远没发出 → Dart 的 `await` 永久悬挂 = 这一轮报的"一直正在扫描…"。所以第三轮那次"顺带修好闪退"其实只是把崩溃降级成了悬挂，判断方向也因此被带偏了一轮。

改动：

- `"copyPublished" -> { copyPublished(call); null }`——根因，一行。
- 回投不再静默：新增 `reply(name) { ... }`，在主线程提交，失败时写进原生停点（`回投失败 <method> <异常类名>`），下一次扫描的 `原生上次停在 …` 就会把它带回来。`runCatching` 那种"把崩溃变成挂住"的兜底不再出现在这里。
- 保留 `file:` 直读 `File.inputStream()`，但**理由换成真实的那一个**：普通文件走 ContentResolver 是每 64 KB 一次 binder 往返，没有好处，而清单读取对同一种目的地本来就走直路。
- **恢复 `fd.sync()`**：它被上一轮以"可能不返回"为由删掉，而本轮证据证明它正常完成；发布媒体文件的路径同样在 sync，保持一致。
- 60 秒超时与扫描重入闸门保留（它们不是为这个 bug 加的，但正是它们让悬挂在 20 秒处留下可读的"仍在等待，停在：copyPublished 完成"，从而暴露了回投这一侧）。

关于"扫描为什么慢"：**扫描从不读视频字节**。一次完整导入 = 6 次通道调用 + 读一个 923 字符的 `manifest.json` + 抄一个小文本旁路；命中缓存时只有 3 次通道调用（日志里 `缓存命中` 那一档）。`adopt` 对每个文件只做 `checkBoundary` + 开一次 FD 再 `lseek` 探可寻址性，是元数据操作。慢的部分全部来自这条回投 bug，不是解析成本；目的地切换后缓存键变化导致的全量重读也是设计内的。

验收：`:app:compileDebugKotlin` 通过；Dart 侧无行为改动（第三轮的超时/闸门用例仍覆盖）。**设备端未验证**：这一版的判据是 `原生 copyPublished ←` 出现配对、红字不再停留、一次扫描在几十毫秒内返回。

## 2026-11-02：删除任务不再删文件、外层刷新移除、换目录立即接管列表

三处口径调整，围绕同一句话：**下载列表是公共目录的一个视图**。

- **外层「刷新下载」图标移除**，只留设置对话框里的「扫描下载目录并导入」。`refresh()` 没有变成死代码，它仍有三处入口：队列报错时错误态里的「重试」（`downloads_screen.dart`）、`/downloads` 根标签刷新与账号页下载分区刷新（`router.dart`）；加上启动、续传前、下载抛错时、点开离线视频前四处**自动**核对，手动全量核对在 Android 上不再是必需动作。摘掉的是"用户以为它能找回重装前的内容"这个误导——发现能力本来只有扫描有。
- **删除任务不再删除任何文件**：`remove(id)` 的 `deleteFiles` 参数从领域接口、控制器、仓储三层一起去掉，删除对话框的复选框换成说明文字。连带后果必须讲明白：**文件还在目录里，下次扫描就会把它重新导入**，所以对话框直接写"想彻底移除请到下载目录删除对应文件夹（文件夹名以 BV 号开头）"。`remove` 同时清掉该任务的 `download_scan_cache` 行，免得旧缓存把这次重导入伪装成一次命中。公共侧原生 journal 记录暂不清理——`adopt` 对同一 key 有早退路径，残留有界；`PublicDownloadStorage.delete` 在 lib 侧已无调用者，保留待后续一并处置。
- **切换下载目录后立刻接管列表**：`scanShared({replaceCompleted: true})` 解析出新目的地之后，先移除 `publicDestination` 指向别的公共目录的**已完成**行（不碰文件；`publicDestination == null` 的应用私有下载保留），再照常扫描导入。对话框里「更改公共下载位置」成功后先 `_loadLocations()` 让「当前下载位置」即刻变更，再跑一次替换式扫描并就地显示摘要——不等重启。

验收：新增 2 个仓储用例（替换式扫描清掉旧目录的行且 `deleted` 为 false、换回原目录能重新导入并带上新目的地；`remove` 保留任务目录与旁边的无关文件）；改 4 处既有断言（`remove` 调用、`removed` 记录类型、两个用例改名以匹配新语义）；presentation 用例改为断言对话框的说明文案。downloads + playback + settings 共 1296 通过、13 跳过；`flutter analyze` 无问题。

未验证：真机上三种目的地（`file:` / MediaStore / SAF）之间来回切换后列表接管的手感；把目录切回原处时靠扫描重新认领的路径在用例里覆盖了，设备未取样。

