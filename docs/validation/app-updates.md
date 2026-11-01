# 关于页与每日更新检查

日期：2026-10-06。在已有工作区修改上增量实现。

## 行为与边界

关于页显示真实应用版本、可点击的 `https://github.com/CKopoer/BiliSail` 和“检查更新”。应用启动后不阻塞首屏，每个本地日历日首次启动检查一次；先持久化尝试日期，自动检查失败或没有新版本时不弹窗，当天重启不再次检查。手动检查不受日期限制，有加载状态和明确结果，与正在进行的自动检查共享同一次请求。

2026-10-24 调整自动提醒规则：按 `major.minor.patch` 持久化最后自动提醒的版本，同一版本跨日、重启或仅增加 `+N` 构建号均不再自动弹窗；例如已提醒 `1.1.1+3` 后，`1.1.1+4` 保持安静，发现 `1.1.2` 时再次提醒。记录只向更新的版本推进，远端候选回退不会重新提醒旧版本。每日查询仍照常进行；手动点击“检查更新”绕过自动提醒记录，每次仍可提示包含最新构建号的新版本，合并进自动请求的手动检查也遵守此规则。

2026-10-28 增加“设置 → 关于 → 检查预发布更新”，默认关闭，沿用 2026-10-25 的正式版筛选行为。关闭时，手动与每日自动检查均排除 GitHub 标记为 `prerelease: true` 的预发布版本，只从正式 Release 中选择候选；开启时，两类检查均将正式版和预发布版按完整版本号比较，选择最新候选，弹窗保留预发布标记。`draft: true` 的草稿始终排除，渠道不按标签拼写猜测。没有候选时，手动检查按开关提示“暂无已发布的正式版本”或“暂无已发布的版本”，自动检查保持安静，也不写入自动版本提醒记录。

开关通过 `AppSettings`、设置控制器与 `SqliteSettingsRepository` 保存，保存后用于后续检查，无需重启；在途检查沿用发起请求时的渠道选择。检查等待已保存设置加载后再请求，避免启动时把已开启的选择当作默认关闭。保存失败沿用回退和错误提示；旧快照缺失字段、非法值及恢复默认均关闭，显式保存的布尔值保持有效。偏好 JSON 快照版本由 30 增至 31，SQLite 表结构不变。每日检查次数及自动提醒按三段版本号去重的规则保持不变，切换渠道后可手动检查。

2026-11-02 启动检查改为可选且默认关闭：新增“设置 → 关于 → 启动时检查更新”，`AppSettings.checkUpdatesOnStartup` 默认 false，`SqliteSettingsRepository` 对缺失字段、非法值与恢复默认都回落到关闭，偏好 JSON 快照 `schemaVersion` 由 34 增至 35，SQLite `schemaVersion` 仍为 3、不改表。关闭时启动路径不查询 GitHub，也不写入当日尝试记录，因此当天任意时刻开启都能完成那一次检查；开启后沿用“每个本地日历日首次启动检查一次”和“同一三段版本号仅自动提醒一次”。上文 2026-10-06 与 2026-10-24 的“每天首次启动自动检查”是当时的默认行为，现由该开关取代；手动检查始终不受开关与日期限制。

同日起，发现新版本时（自动与手动共用同一弹窗）除版本、预发布标记与 Markdown 说明外，还显示本机版本、发布时间（`published_at`，响应未提供时标注）、Release 页面地址与附件清单（名称与大小）。“查看本次请求详情”展开本次请求记录：请求方法与完整 URL、实际发出的请求头、HTTP 状态码、解码后响应字节数、耗时、预发布渠道选择、候选总数以及被排除的草稿／预发布／非版本标签数量；“复制请求详情”把同一份记录写入剪贴板，便于反馈时附证据。没有新版本与请求失败仍只在设置页显示单行结果，不弹窗。

新版本弹窗显示版本与更新说明；“稍后再说”关闭弹窗，“前往 Release”调用系统浏览器打开该版本页面。只有用户点击才打开外部页面，不自动下载、安装或打开浏览器。提示由进程级宿主管理，切换或关闭设置标签不会取消整个应用的更新检查；同一请求不产生重复弹窗。退出或请求超时会取消网络读取，迟到响应不更新状态。

2026-10-27 更新说明改用 `flutter_markdown_plus` 的 `MarkdownBody` 渲染 GitHub Flavored Markdown，支持标题、粗体／斜体、列表、任务列表、引用、表格、行内与围栏代码及链接。正文仍可选择复制，沿用弹窗纵向滚动，长表格和代码行使用组件自带的横向滚动；文字、引用和链接跟随深浅主题与系统字号。空白说明保留原下载提示。“前往 Release”仍打开已校验的发布地址；正文 HTTP(S) 链接仅在点击后通过已有公开网页打开端口交给系统浏览器，相对链接以该 Release URL 解析，失败时提示且保留弹窗。Markdown 图片复用公开图片组件，不携带账号凭据；本地文件、应用资源等非 HTTP(S) 图片只显示替代文字。不解析内嵌 HTML，GitHub 的 HTML 扩展布局不在本次支持范围内。

## 协议、版本与存储

- 独立无凭据 `HttpClient`，单次 GET `https://api.github.com/repos/CKopoer/BiliSail/releases?per_page=100`；`Accept: application/vnd.github+json`、`X-GitHub-Api-Version: 2026-03-10`。不附 Bilibili Cookie/token，不跟随重定向、不自动重试，保留系统 TLS 验证。
- 2026-11-02 起请求端点与实际发出的请求头收敛为单一常量（`GitHubUpdateRepository.endpoint`、`requestHeaders`），弹窗展示的与真正发送的是同一份；解析增加 `published_at`（省略或字符串，长度 ≤40，无法解析时按未提供处理）和 `assets`（≤64 项，逐项校验名称 ≤200 字符、大小为非负整数且 ≤1 TiB、`browser_download_url` 必须是本仓库 `releases/download/<tag>/…` 的同段 HTTPS 地址）。附件只是信息，不合规范的条目丢弃而不让整次检查失败，与 Release 链接那种“不合规范即判协议错误”有意区分。`UpdateCheckReport` 携带状态码、解码后字节数、耗时与候选计数；由注入的 fetcher 提供响应体时不存在真实传输，这三项为空，弹窗与复制文本都如实标注“未记录”。展示的字节数是解码后的正文，容量上限判断仍按传输层的压缩长度。
- 检查列表第一页最多 100 个 Release，要求 `draft`、`prerelease` 为 JSON 布尔值；始终要求 `draft: false`，默认还要求 `prerelease: false`，仅在开启“检查预发布更新”时接受预发布版。不根据标签名称推断 GitHub 的预发布标记。空列表或全部被渠道筛选排除表示暂无符合渠道的发布；存在符合渠道的记录但均非有效版本时不伪装成“已是最新”。仍保留最多 100 项的查询上限，不继续翻页查找更早的版本。
- 2026-10-25 核对并于 2026-10-28 复核 [GitHub List releases 官方协议（API 2026-03-10）](https://docs.github.com/en/rest/releases/releases?apiVersion=2026-03-10#list-releases)：公开资源可匿名读取，响应为 Release 数组，分页参数只有 `per_page`（最多 100）和 `page`，不提供服务端排除预览版的查询参数，因此在客户端检查 `draft`／`prerelease`。另有 [Get the latest release](https://docs.github.com/en/rest/releases/releases?apiVersion=2026-03-10#get-the-latest-release) 返回单个非草稿、非预览版对象；官方说明其 latest 选择关联 `created_at`，不等同于本项目按语义版本和数字构建号取最大值，因此继续使用列表端点按设置筛选渠道。
- 版本先按 `major.minor.patch` 与预发布标识比较，再比较数字 Flutter `+N` 构建号，支持 `v0.1.0+2`。同一语义版本的不同数字构建仍被识别为更新，但自动弹窗按三段版本号去重，手动检查不受此限制；非数字构建元数据不改变优先级，不按字符串字典序比较。
- `package_info_plus 10.2.2` 从已有锁定的传递依赖提升为直接依赖，BSD-3-Clause，支持 Android/Windows/macOS，未改变解析版本。常规运行读取平台包版本，[Release 脚本](../../tool/build-release.ps1) 通过 `BILISAIL_RELEASE_VERSION` 注入实际 `x.y.z+N`，避免 Android split APK 的 `versionCode +2000` 被当作 Release 构建号。自行执行 split APK 构建时应传相同 Dart define。
- 网络总读取期限 12 秒，整个检查期限 20 秒；响应最多 2 MiB，展示说明最多 12000 字符。说明按 Markdown 显示；作为更新目标的 Release 链接只接受本仓库的 HTTPS 地址，拒绝其他 host、仓库、端口、userinfo、query 或 fragment。正文链接与图片限制为不含 userinfo 的 HTTP(S) URL；打开正文链接最多等待 12 秒。
- 新增精确依赖 [`flutter_markdown_plus 1.0.12`](https://pub.dev/packages/flutter_markdown_plus/versions/1.0.12)，BSD-3-Clause；采用其 Flutter 组件和传递依赖 `markdown 7.3.1`，无新增原生插件或二进制资产。包声明覆盖项目目标平台，实际设备展示仍需逐平台验证。根应用锁文件同步，四个独立包不增加 Markdown 依赖。
- 日期写入既有 `settings` 表的 `app_update.last_startup_day.v1`，最后自动提醒的三段版本号写入 `app_update.last_prompted_version.v1`，与账号无关。提醒记录在发布待显示提示前通过事务认领，读取或保存失败时自动检查保持安静；退出或超时后的存储响应不能恢复弹窗。不改表、不改变当前 SQLite schemaVersion 3、不清空设置或历史；版本查询、HTTP、日期及提醒存储与链接打开均通过应用层注入。

## 参考与采用范围

只读参考相邻 biliuwp-lite 提交 `7c1baab53a5afb80235323ef5b37463e4b93db9f`：

- [AboutSettingsControl.xaml](../../../biliuwp-lite/src/BiliLite.UWP/Controls/Settings/AboutSettingsControl.xaml) / [代码](../../../biliuwp-lite/src/BiliLite.UWP/Controls/Settings/AboutSettingsControl.xaml.cs)：关于页检查入口。
- [BiliExtensions.CheckVersion](../../../biliuwp-lite/src/BiliLite.UWP/Extensions/BiliExtensions.cs)：版本比较、更新说明弹窗和查看详情。
- [App.xaml.cs](../../../biliuwp-lite/src/BiliLite.UWP/App.xaml.cs)：窗口启动后的静默检查入口。
- [GitApi.cs](../../../biliuwp-lite/src/BiliLite.UWP/Models/Requests/Api/GitApi.cs)：参考项目使用自有 `new_version.json`，本项目独立接入自己的 GitHub Release。

仅借鉴流程与职责，独立编写 Dart/Flutter；未复制 C#/XAML、资源、版本描述 schema，亦不依赖或修改相邻仓库。参考项目每次 release 启动检查，本项目按用户要求增加每日尝试记录；未加入忽略版本或镜像更新地址功能。

## 验证

2026-11-02 启动开关与请求记录：`test/features/settings` 定向 251 项通过（更新专项 53 项，含新增的“启动开关关闭时零请求且不认领当日记录”“弹窗展开请求详情并可复制”“设置快照默认／非法值／往返与恢复默认”），根应用全量 3933 通过、13 跳过（`bili_mux` 原生用例因未配置 `BILI_MUX_LIBRARY` 跳过），`flutter analyze` 无问题，`dart format --set-exit-if-changed` 对 659 个文件返回 0。本轮改动不进入四个独立包，未重跑包测试；请求记录断言使用注入的 fetcher 与假仓储，状态码／字节数／耗时按“未记录”验证，未执行真实 GitHub 在线烟测，也未构建安装包或做 Windows／Android／macOS 实机验收，弹窗在窄窗口与大字档下的实际观感待平台验证。

2026-10-28 预发布开关：更新检查、SQLite 设置与恢复默认的 104 项定向测试通过，覆盖两类检查的渠道选择、草稿排除、跨渠道版本排序、预发布标记与协议校验、设置加载等待、无需重启切换、空候选提示、界面保存失败回退、旧快照及非法值回退、保存选择和各平台恢复默认。`tool/check.ps1 -SkipPub` 通过格式、静态分析、打包边界和离线测试：根应用 3209、bili_api 495、bili_player 83、bili_danmaku 116、bili_mux 5 项通过，共 3908 项；根应用 13 项因 Windows 符号链接权限不足跳过，mux 10 项原生用例因未配置 `BILI_MUX_LIBRARY` 跳过。日志 `artifacts/app-updates-prerelease-setting-check-20261028.log`。本次复核 GitHub 官方文档，未执行实际发布列表的在线烟测；未构建安装包或进行平台实机验收，未发现可热重载的运行中调试实例。验证结束时存在其他会话的导航与标签保留相关修改，本次保持原样，验证结果以本轮日志为准。

离线测试覆盖版本及构建号排序、预览/草稿、空列表、错误协议与链接、容量、SQLite 日期重开、跨日/失败后重启、手动合并、取消/超时与迟到结果、窄窗口、弹窗确认及浏览器打开失败。Windows 原生入口为 [windows_app_updates_test.dart](../../integration_test/windows_app_updates_test.dart)，在线读取需显式 `--dart-define=BILI_UPDATES_ONLINE=true`，正常检查不访问真实账号或外网。

2026-10-27 Markdown 渲染：更新专项 40 项测试通过，新增覆盖深浅主题下 360 × 640 窄窗口与 1.5 倍字号、标题／列表／任务／引用／表格／代码、长表格和代码横向滚动、正文链接仅点击打开及相对链接解析、拒绝本地／脚本协议、浏览器打开失败、非网络图片和空白说明后备。`tool/check.ps1 -EnforceLockfile` 通过锁文件解析、格式、静态分析、打包边界和离线测试：根应用 3015、bili_api 478、bili_player 83、bili_danmaku 93、bili_mux 5 项通过，共 3674 项。根应用 13 项因 Windows 符号链接权限不足跳过，mux 10 项原生用例因未配置 `BILI_MUX_LIBRARY` 跳过；日志 `artifacts/app-updates-markdown-check-20261027.log`。文档 7 条本地链接和 `git diff --check` 通过。本次未构建或执行 Windows／Android／macOS 实机验收。

2026-10-25 正式版筛选：更新专项 33 项测试通过，覆盖高版本预览版不遮挡正式版、只有草稿／预览版时无候选、GitHub 布尔字段校验，以及实际 Repository 到手动／自动检查控制器的行为。`tool/check.ps1 -SkipPub` 通过格式、静态分析、打包边界和离线测试：根应用 2687、bili_api 456、bili_player 81、bili_danmaku 93、bili_mux 2 项通过；mux 另有 10 项原生用例因未配置 `BILI_MUX_LIBRARY` 跳过，日志 `artifacts/app-updates-stable-check-20261025.log`。另通过实际 `GitHubUpdateRepository` 的匿名 HTTP 请求取得正式版 `1.1.1+7`，确认 `prerelease: false`，日志 `artifacts/app-updates-stable-online-20261025.log`。Windows 集成测试 fixture 已加入更高版本的预览版并保留正式版提示断言，但本次未执行原生集成测试、构建或三端实机验收；未发现运行中的调试实例可供热重载。

2026-10-24 自动提醒调整：更新专项 28 项离线测试通过，包含数据库重开后保留提醒记录、同版本跨日与构建号变化静默、下一三段版本再次弹窗、手动重复检查与合并请求仍提示、存储迟到响应不恢复弹窗。`tool/check.ps1 -SkipPub` 通过根应用与四个包的格式、静态分析、离线测试和打包边界检查；mux 的 10 项原生用例因未配置 `BILI_MUX_LIBRARY` 跳过，日志 `artifacts/app-updates-version-reminders-check.log`。此次未构建或进行 Windows／Android／macOS 实机验收，无运行中的调试实例可供热重载；下方为 2026-10-06 的历史验证记录。

本轮在 Windows / Flutter 3.47.6 / Dart 3.13.5 完成：

- `tool/check.ps1 -EnforceLockfile` 通过：根应用 641、bili_api 207、bili_player 16、bili_danmaku 21 项，共 885 项；根应用和三个包格式检查、静态分析均通过。更新专项 24 项包含在根应用计数中；日志 `artifacts/app-updates-check.log`。
- `flutter test integration_test/windows_app_updates_test.dart -d windows --dart-define=BILI_UPDATES_ONLINE=true` 通过 2 项。真实 Windows 包读取 `0.1.0+1`，原生窗口显示更新提示，SQLite 当日标记与弹窗操作正确；实际无凭据 GitHub 查询取得已公开的 `0.1.0+2`。外部打开端口在此测试中记录目标 URI，没有实际启动浏览器；日志 `artifacts/app-updates-windows.log`。
- 原生截图 `artifacts/app-updates-windows.png` 已查看，关于页、版本、GitHub 地址、检查入口与更新弹窗布局正常。
- 显式 `BILISAIL_RELEASE_VERSION=1.2.3+45` 的版本读取回归通过，验证发布版本覆盖平台包的原生版本码；日志 `artifacts/app-updates-version-override.log`。
- `flutter build windows --debug` 的普通应用入口构建成功，产物 `build/windows/x64/runner/Debug/bilisail.exe`；日志 `artifacts/app-updates-build.log`。PowerShell 构建脚本语法、110 条本地文档链接及 `git diff --check` 通过。

正常离线检查不访问真实账号或外网，本轮只读访问 GitHub，没有发布 Release、下载更新包或更改账号。Android/macOS 构建与实机运行、真实系统浏览器打开，以及修改后版本的 MSIX 安装升级待验证；Windows 原生验证不代表这些平台或安装链路已经验收。
