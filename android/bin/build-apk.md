# `build-apk.cmd` 一键发包脚本说明

日期：2026-11-06。对应源码：`ba1f9a8` + F92 的产物命名改动（脚本自身的完整链路在改动前后一致，改动只影响产物名与最新件探测）。

本文描述 `android/bin/build-apk.cmd` 的**实际行为**：它做什么、按什么顺序探测、把什么交给谁、失败时会怎样、产物落在哪里、依赖哪些文件。所有内容都来自逐行读源码与本轮真实跑通的结果，不做推测；末节列出仍未验证的部分。

---

## 1. 定位与职责边界

这个脚本是**本机 Android arm64 开发测试包的双击入口**，不是构建系统的一部分。它只做三件事：探测工具链、调用标准构建入口、报告与可选安装。

```mermaid
flowchart LR
    subgraph inscope["本脚本负责"]
        A["探测 Flutter / Android SDK / JDK 17+ / MSYS2"]
        B["决定是否跳过 mux 组件构建"]
        C["调用 tool/build-android-development.ps1"]
        D["解析最新产物并报告大小"]
        E["询问是否 adb install -r"]
    end
    subgraph outscope["本脚本不负责，全部在 tool/ 下"]
        F["产物命名与元信息"]
        G["包名 / 名称 / 版本 / ABI / AOT 校验"]
        H["签名指纹与 pin 比对"]
        I["libmpv jar 预置与代理决策"]
        J["设备常亮设置保存与恢复"]
    end
    C --> F
    C --> G
    C --> H
    C --> I
    C --> J
    A --> C
    B --> C
    D --> E
```

三条硬边界：

- **不重复任何规则**。签名、身份、版本、ABI、AOT 的判定只存在于 `tool/*.ps1`，脚本里没有任何一份副本，因此不会出现两处规则漂移。
- **不碰正式包**。开发测试身份由 Gradle 属性 `bilisailDevelopmentBuild=true` 打开（[android/app/build.gradle.kts:85](../../android/app/build.gradle.kts)：`applicationIdSuffix = ".test"`、标签「BiliSail 测试版」）；CI 与正式发布走 `tool/build-release.ps1`，不传该属性，也不经过本脚本。
- **不做破坏性动作**。安装只用 `adb install -r`；不卸载、不 `pm clear`、不强制降级；junction 清理只用 `rmdir`（删链接，不删目录内容）。

---

## 2. 全链路主流程

```mermaid
flowchart TD
    S(["双击运行 / cmd 调用"]) --> P0["第 0 步 前置检查<br/>REPO_ROOT 下 pubspec.yaml 存在<br/>tool/build-android-development.ps1 存在"]
    P0 -->|"任一缺失"| FX["打印缺失路径 → :fail → pause → exit /b 1"]
    P0 --> P01["第 0.1 步 ASCII 路径判定<br/>用 powershell 正则检查 REPO_ROOT 是否含非 ASCII"]
    P01 -->|"纯 ASCII"| KEEP["就地构建，REPO_ROOT 不变"]
    P01 -->|"含非 ASCII"| JUNC[":setup_junction<br/>建/校验 C:/bilisail-build 目录链接<br/>REPO_ROOT 与 TOOL_DIR 改指链接"]
    JUNC -->|"链接指向不对"| FX
    KEEP --> P1["第 1 步 定位 Flutter SDK"]
    JUNC -->|"成功"| P1
    P1 -->|"找不到"| FX
    P1 --> P2["第 2 步 定位 Android SDK<br/>同时导出 ANDROID_HOME 与 ANDROID_SDK_ROOT"]
    P2 -->|"找不到"| FX
    P2 --> P3["第 3 步 定位 JDK 17+<br/>结果存 BUILD_JDK 并导出 JAVA_HOME 与 PATH"]
    P3 -->|"没有 17+"| FX
    P3 --> P4["第 4 步 mux 原生组件<br/>复用预构建资产或触发构建"]
    P4 --> P5["第 5 步 调用 ps1 构建 Release"]
    P5 -->|"退出码非 0"| FY["打印失败说明含 libmpv jar 手动兜底路径 → :fail"]
    P5 -->|"退出码 0"| P6["第 6 步 解析最新版本化 Release 产物<br/>报告绝对路径与整 MB 大小"]
    P6 -->|"没有匹配文件"| FX
    P6 --> Q{"已连接 adb 设备？<br/>choice 15 秒默认 N"}
    Q -->|"Y 且有设备"| INST["逐个设备 adb install -r<br/>失败只提示不自动卸载"]
    Q -->|"N / 超时 / 无 adb"| DONE[":done → pause → exit /b 0"]
    INST --> DONE
```

流程图对应源码里的六个 `echo [n/6]` 计数点与三个子过程（`:find_on_path`、`:setup_junction`、`:java_major`）；`:fail` 与 `:done` 是两个终点，唯一区别是退出码 1 还是 0。

---

## 3. 逐个步骤的真实逻辑

### 3.1 第 0 / 0.1 步：前置检查与非 ASCII 路径绕行

判定用 `powershell -NoProfile -Command`，而不是 `pwsh`——注释写明原因：某些环境下 cmd 的 `for /f` 解析不了 `pwsh` 的应用执行别名。判据是正则 `[^\u0000-\u007F]`。

```mermaid
flowchart TD
    A["REPO_ROOT 是否含非 ASCII"] -->|"否"| B["[INFO] Project path is pure ASCII; building in place."]
    A -->|"是"| C["提示：Dart AOT snapshotter 无法在非 ASCII 路径下构建<br/>本次经 C:/bilisail-build 链接运行"]
    C --> D{"链接已存在？"}
    D -->|"存在且能看到 pubspec.yaml 与 android/bin/build-apk.cmd"| E["复用，不重建"]
    D -->|"存在但校验不过（陈旧或指向别处）"| F["rmdir 只删链接<br/>重建 mklink /J"]
    D -->|"不存在"| F
    F --> G{"创建后能否读到 pubspec.yaml"}
    G -->|"否"| H["报错并给出手工 mklink 命令 → 失败退出"]
    G -->|"是"| I["REPO_ROOT = C:/bilisail-build<br/>TOOL_DIR = 其下 tool"]
    E --> I
```

要点：链接只是别名，不复制文件、不额外占盘；脚本每次都会校验它指向的是本工程；`build-apk.cmd` 自身必须留在 `android/bin/` 下（第 0 步就是靠 `..\..\` 反推仓库根）。

### 3.2 第 1~3 步：工具链探测顺序

顺序即优先级，先命中先用；三条探测链互不依赖但都在构建前完成。

```mermaid
flowchart TD
    subgraph f1["Flutter SDK"]
        A1["FLUTTER_HOME/bin/flutter.bat"] --> A2["FLUTTER_ROOT/bin/flutter.bat"]
        A2 --> A3["where flutter.bat"]
        A3 --> A4["固定目录列表<br/>~/dev/flutter、LOCALAPPDATA/flutter、~/flutter、<br/>~/fvm/default、C:/flutter、C:/src/flutter、C:/tools/flutter"]
    end
    subgraph f2["Android SDK（必须含 platform-tools）"]
        B1["ANDROID_HOME"] --> B2["ANDROID_SDK_ROOT"]
        B2 --> B3["LOCALAPPDATA/Android/Sdk、~/dev/android-sdk、C:/Android/Sdk"]
        B3 --> B4["两个变量同时导出"]
    end
    subgraph f3["JDK 17+（AGP 9 要求）"]
        C1{"JAVA_HOME 的主版本 >= 17？"} -->|"是"| C2["BUILD_JDK = JAVA_HOME"]
        C1 -->|"否或已指向旧 JDK"| C3["扫描 D:/JDK、Program Files 下<br/>Java / Eclipse Adoptium / Microsoft / Zulu /<br/>Android Studio jbr"]
        C3 --> C4["两层展开：目录本身或其一级、二级子目录<br/>凡 bin/java.exe 存在且主版本 >= 17 即取"]
        C4 --> C5{"仍无命中"}
        C5 -->|"是"| C6["报错：AGP 9 requires JDK 17 or newer → 失败退出"]
        C5 -->|"否"| C7["BUILD_JDK 命中"]
    end
    f1 --> f2 --> f3
```

`java_major` 用 `java -version` 的第 3 个 token 取主版本号，取不到记 0（即视为不合格）。JDK 找到后在**第 4 步开头**才导出：

```
set "JAVA_HOME=%BUILD_JDK%"
set "PATH=%BUILD_JDK%\bin;%PATH%"
set "FLUTTER_SUPPRESS_ANALYTICS=true"
```

这一步正是本轮实测的关键：本机 `JAVA_HOME` 指向 Dragonwell 8，直接调 ps1 会让 Gradle 报「configured to use JVM 8」；脚本自己探测到 `D:\JDK\…dragonwell-21…` 并覆盖后，Gradle 正常跑完。日志行形如 `[3/6] JDK : D:\JDK\…\dragonwell-21.0.12.0.12+8-GA (Java 21)`。

### 3.3 第 4 步：mux 原生组件复用或构建

```mermaid
flowchart TD
    A["定位 MSYS2 bash<br/>BILI_MUX_MSYS_ROOT → C:/msys64"] --> B{"找到 bash？"}
    B -->|"否"| C["[WARN] 跳过 mux 构建<br/>不加 -SkipMuxBuild，交给 ps1 自己准备"]
    B -->|"是"| D{"预构建资产已存在？<br/>packages/bili_mux/native/prebuilt/android-arm64/libbili_mux.so"}
    D -->|"是"| E["[INFO] 复用资产<br/>SKIP_MUX_ARG = -SkipMuxBuild"]
    D -->|"否"| F["写两个 TEMP 脚本<br/>gcc 包装指向 /ucrt64/bin/gcc.exe<br/>负载脚本导出 ANDROID_NDK_HOME"]
    F --> G["bash -l 登录 shell 执行<br/>packages/bili_mux/tool/build.sh android-arm64"]
    G -->|"退出码 0"| E
    G -->|"非 0"| H["[WARN] 打印 build/download_mux/android-arm64/*.log<br/>不加 -SkipMuxBuild 继续构建"]
    C --> I["第 5 步"]
    E --> I
    H --> I
```

两处刻意为之的细节：**必须用 `bash -l`**（非登录 shell 不会把 `/usr/bin` 放进 PATH，gcc 会静默失败）；**NDK 固定 `28.2.13676358`**，由 `tool/build-download-mux.ps1` 校验 `source.properties`，本脚本只在 TEMP 负载里导出同一路径。若既没有 MSYS2 又没有预构建资产，ps1 会在准备 mux 时抛错——这是如实的失败路径，不是「自动降级成功」。

### 3.4 第 5 步：交给 ps1

```mermaid
sequenceDiagram
    participant CMD as build-apk.cmd
    participant DEV as build-android-development.ps1
    participant HELP as tool 下五个助手
    participant FL as flutter build apk
    participant GR as Gradle + AGP
    CMD->>DEV: -Mode Release 可选 -SkipMuxBuild
    DEV->>HELP: 读 pubspec 版本并算期望 versionCode
    DEV->>HELP: Ensure-LibmpvAndroidJars 预置三个 ABI jar
    DEV->>FL: build apk --release --target-platform android-arm64<br/>--split-per-abi --target lib/main.dart<br/>--android-project-arg=bilisailDevelopmentBuild=true<br/>--dart-define=BILISAIL_RELEASE_VERSION
    FL->>GR: assembleRelease
    GR-->>FL: build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
    FL-->>DEV: 退出码 0
    DEV->>DEV: 复制到交付目录并按新命名落名
    DEV->>HELP: 身份 / 资源 / ABI / AOT / 签名 / pin 校验
    DEV-->>CMD: 打印 Development Release APK 绝对路径
    CMD->>CMD: 非 0 退出码则打印兜底说明并失败
```

脚本只判断 `$LASTEXITCODE`，不解释 ps1 内部逻辑，因此 ps1 的任何新校验都不需要同步改本脚本。承载方式是 `where pwsh` 优先、退回 `where powershell`，两者都没有才报「Neither pwsh nor powershell was found on PATH」；调用固定带 `-NoProfile -ExecutionPolicy Bypass`，避免用户 profile 与执行策略影响构建。

### 3.5 第 6 步：产物解析与报告

```mermaid
flowchart TD
    A["APK_DIR = build/development/android-arm64"] --> B["dir /b /a-d /o:-D 模式<br/>BiliSail-test-arm64-release-*.apk<br/>按时间倒序，只列文件"]
    B --> C["findstr 正则过滤以 .apk 结尾的行"]
    C --> D{"取到的第一行"}
    D -->|"空"| E["[ERROR] 报期望命名 BiliSail-test-arm64-release-version-timestamp.apk<br/>并给出目录 → :fail"]
    D -->|"非空"| F["APK_OUT = APK_DIR + 该文件名"]
    F --> G{"文件确实存在？"}
    G -->|"否"| E
    G -->|"是"| H["for %%~zA 取字节数<br/>set /a 换算整 MB"]
    H --> I["BUILD OK 横幅：绝对路径 + 大小 +<br/>提示同基名 .sha256/.json 在旁边"]
```

`findstr` 这一步不是多余：`dir` 的旧式通配会把 `*.apk.sha256` 这类相邻 sidecar 一起带出来，靠 `\.` + `apk$` 锚定结尾才排除；同时旧固定名 `BiliSail-test-arm64-release.apk` 不匹配新 glob，因此不会被当成交付件。这三点都做过夹具验证，见第 7 节。

### 3.6 收尾：可选安装

只在 `%SDK%\platform-tools\adb.exe` 存在时进入；`choice /t 15 /d N` 意味着**不按键就是跳过安装**；设备列表来自 `adb devices | findstr /r /c:"device$"`，逐台 `adb install -r`。安装失败只提示「插 USB + 打开 USB 调试后重试」，不卸载、不清数据。最后 `:done` / `:fail` 都以 `pause` 结束，让双击窗口不闪退。

---

## 4. 依赖文件与代码架构

```mermaid
graph TD
    CMD["android/bin/build-apk.cmd<br/>本脚本，纯 ASCII 批处理"]
    PS1["tool/build-android-development.ps1<br/>构建 + 命名 + 校验 + 元信息"]
    AD["tool/android-development.ps1<br/>aapt / badging 解析 / 命名与最新件探测"]
    AV["tool/android-version.ps1<br/>紧凑 versionCode 公式"]
    AS["tool/android-signing.ps1<br/>apksigner PEM 取证书指纹"]
    AM["tool/android-media-notification.ps1<br/>六个音频通知 drawable"]
    AL["tool/android-libmpv-assets.ps1<br/>jar 清单解析、多传输下载、代理参数"]
    BM["tool/build-download-mux.ps1<br/>NDK 版本校验后调 mux 构建"]
    SH["packages/bili_mux/tool/build.sh"]
    GR["android/app/build.gradle.kts<br/>bilisailDevelopmentBuild 开关"]
    PUB["pubspec.yaml 的 version 行"]
    OUTD["build/development/android-arm64/<br/>APK + .sha256 + .json + 签名 pin"]
    RAW["build/app/outputs/flutter-apk/<br/>Flutter 原始产物，每次覆盖"]
    JARDIR["build/media_kit_libs_android_video/20260906/<br/>预置的三个 ABI jar"]
    CMD --> PS1
    PS1 --> AD
    PS1 --> AV
    PS1 --> AS
    PS1 --> AM
    PS1 --> AL
    PS1 --> BM
    BM --> SH
    PS1 --> PUB
    PS1 --> RAW
    RAW --> OUTD
    AL --> JARDIR
    GR -.->|"Gradle 属性"| PS1
    CMD -.->|"探测后调用"| SH
    CMD -.->|"探测后调用"| BM
```

各依赖被本脚本使用的具体点：

| 文件 | 谁调用 | 用途 |
| --- | --- | --- |
| [tool/build-android-development.ps1](../../tool/build-android-development.ps1) | 本脚本第 5 步（唯一入口） | 构建、命名、复制、校验、写元信息、可选安装 |
| [tool/android-development.ps1](../../tool/android-development.ps1) | ps1 点源；三个设备回归脚本也点源 | `Get-AndroidDevelopmentApkName`、`Resolve-AndroidDevelopmentApk`、aapt 定位与 UTF-8 安全读取、badging 解析与拒绝规则 |
| [tool/android-version.ps1](../../tool/android-version.ps1) | ps1 | `major*10000 + minor*1000 + patch*100 + build` 紧凑 versionCode，格式不符即抛 |
| [tool/android-signing.ps1](../../tool/android-signing.ps1) | ps1 | `apksigner verify --print-certs-pem` 取唯一证书的 SHA-256 |
| [tool/android-media-notification.ps1](../../tool/android-media-notification.ps1) | ps1 | `aapt dump resources` 校验六个音频通知 drawable 未被 shrink 掉 |
| [tool/android-libmpv-assets.ps1](../../tool/android-libmpv-assets.ps1) | ps1 | Gradle 评估期会下载的三个 libmpv jar 先按插件自身 pin 预置，必要时才透传系统代理 |
| [tool/build-download-mux.ps1](../../tool/build-download-mux.ps1) | ps1（第 4 步未加 `-SkipMuxBuild` 时） | 校验 NDK 修订号后经 MSYS2 构建 `libbili_mux.so` |
| [android/app/build.gradle.kts](../../android/app/build.gradle.kts) | Gradle | `bilisailDevelopmentBuild=true` 时切 `.test` 包名与「BiliSail 测试版」标签 |
| [pubspec.yaml](../../pubspec.yaml) | ps1 | 版本与构建号来源，同时决定产物名里的版本段与期望 versionCode |

架构上只有两层是「规则拥有者」：ps1 及其助手（构建语义）、`android/app/build.gradle.kts`（身份语义）。本脚本属于第三层——环境适配层，换机器时只需要它能找到自己的工具链。

---

## 5. 产物、命名与元信息

```mermaid
flowchart TD
    A["flutter build 产出<br/>build/app/outputs/flutter-apk/app-arm64-v8a-release.apk"] --> B["复制到交付目录<br/>build/development/android-arm64/"]
    B --> C["目标文件名 = Get-AndroidDevelopmentApkName<br/>BiliSail-test-arm64-模式-pubspec版本-yyyyMMdd-HHmmss.apk<br/>时间取构建时刻本地时间，秒级"]
    C --> D["身份与内容校验（第 6 节）"]
    D -->|"任一不过"| E["抛错，交付件视为不可用"]
    D -->|"全过"| F["写同基名 sidecar<br/>X.apk.sha256 与 X.apk.json"]
    F --> G["JSON 字段：PackageId、DisplayName、Version、<br/>VersionCode、Mode、BuiltAt、Signing、<br/>CertificateSha256、Sha256"]
    G --> H["signing-certificate.sha256 为目录级唯一 pin<br/>与每构建文件名无关"]
```

本轮真实产物（F92 之后第一次全链路）：

```
build\development\android-arm64\
  BiliSail-test-arm64-release-6.2.6+6-20261106-100544.apk        63,743,588 字节
  BiliSail-test-arm64-release-6.2.6+6-20261106-100544.apk.sha256
  BiliSail-test-arm64-release-6.2.6+6-20261106-100544.apk.json   BuiltAt 2026-11-06T10:05:44+08:00
  signing-certificate.sha256
```

与 Flutter 原始输出的关系：`build/app/outputs/flutter-apk` 那一格是中间物（名字固定、每次覆盖）；交付目录里的是**已经过校验**的那一份。旧固定名 `BiliSail-test-arm64-release.apk` 已不再产出，需要「当前普通入口包」的脚本改用 `Resolve-AndroidDevelopmentApk` 按模式取最新件。

---

## 6. ps1 侧的校验流水线（脚本产物为什么可信）

```mermaid
flowchart TD
    A["复制得到候选 APK"] --> B["Confirm-AndroidDevelopmentApk<br/>aapt dump badging，UTF-8 解码"]
    B --> C{"包名是 dev.bilisail.bilisail.test？<br/>名称是 BiliSail 测试版？<br/>Release 是否被标成 debuggable？"}
    C -->|"任一不符"| X["抛错：身份不符"]
    C -->|"符合"| E["Confirm-AndroidMediaNotificationResources<br/>六个 drawable 必须存在且资源 id 非 0"]
    E -->|"缺失"| X4["抛错：shrink 掉了 audio_service 图标"]
    E -->|"齐备"| D{"versionCode 与 versionName<br/>是否等于 pubspec 推导值？"}
    D -->|"否"| X2["抛错：版本与 pubspec.yaml 不符"]
    D -->|"是"| F["打开 APK 容器：lib/ 下 ABI 只有 arm64-v8a"]
    F -->|"多 ABI 或非 arm64"| X5["抛错：unexpected ABIs"]
    F --> G{"Release 模式"}
    G -->|"是"| H["必须含 lib/arm64-v8a/libapp.so<br/>且不得含 kernel_blob.bin"]
    G -->|"否"| I["跳过 AOT 要求"]
    H --> J["Confirm-AndroidApkSigning<br/>恰好一张证书，取其 SHA-256"]
    I --> J
    J --> K{"目录已有 signing-certificate.sha256？"}
    K -->|"是且指纹不同"| X3["抛错：签名身份变了，保留旧密钥与已装数据"]
    K -->|"否或相同"| L["写/更新 pin，再写同基名 .sha256 与 .json"]
    L --> M["如带 -Install：安装并启动，finally 恢复设备常亮原值与 ANDROID_HOME"]
```

顺序按 [tool/build-android-development.ps1:60](../../tool/build-android-development.ps1) 起的实际代码排列：身份 → 通知资源 → 版本 → ABI → AOT → 签名 → pin → 元信息。

本脚本不复制以上任何一条判据，只是把它们的结果转述给用户；因此 ps1 增加校验时，本脚本无需改动即可保持「通过才报 BUILD OK」。

---

## 7. libmpv jar 与代理决策（Gradle 评估期的网络兜底）

```mermaid
flowchart TD
    A["从插件 android/build.gradle 解析<br/>url + sha256 + destination"] --> B{"目标文件已在<br/>build/media_kit_libs_android_video/20260906/？"}
    B -->|"是且哈希匹配"| C["Status cached, Transport local"]
    B -->|"否"| D{"本机系统代理是否在监听？"}
    D -->|"是"| E["候选顺序：system-proxy → gh-proxy+system-proxy → direct → gh-proxy"]
    D -->|"否"| F["候选顺序：direct → gh-proxy"]
    E --> G["curl 显式 --proxy 或 --noproxy，禁静默继承"]
    F --> G
    G --> H{"下载后哈希等于插件 pin？"}
    H -->|"否"| X["继续下一传输；全失败则报错"]
    H -->|"是"| I["落到 destination，插件仍自行复核"]
    I --> J{"是否有 jar 需要非 direct 才成功？"}
    J -->|"是且代理可用"| K["向 Gradle 追加四个 -D 代理参数<br/>参数值不得含 cmd 元字符"]
    J -->|"否"| L["不加代理参数"]
```

两条不变式：pin 只从插件自己的 `build.gradle` 解析，脚本内不复制常量；无论走哪条传输，插件在 Gradle 阶段仍会自己校验哈希——本兜底**不放松任何完整性检查**。

---

## 8. 失败面与退出码

```mermaid
stateDiagram-v2
    [*] --> Probing
    Probing --> FailedNoPubspec: 仓库根判定失败
    Probing --> FailedJunction: 链接指向不对
    Probing --> FailedToolchain: 缺 Flutter / Android SDK / JDK 17+
    Probing --> Building: 工具链齐备
    Building --> FailedBuild: ps1 退出码非 0
    Building --> Resolving: ps1 退出码 0
    Resolving --> FailedArtifact: 目录无最新版本化 Release
    Resolving --> Offering: 解析到产物
    Offering --> Done: 跳过安装或无 adb / 无设备
    Offering --> Done: 安装成功或失败仅提示
    FailedNoPubspec --> [*]
    FailedJunction --> [*]
    FailedToolchain --> [*]
    FailedBuild --> [*]
    FailedArtifact --> [*]
    Done --> [*]
```

| 失败态 | 用户看到什么 | 恢复动作 |
| --- | --- | --- |
| 缺 `pubspec.yaml` | 提示脚本必须留在 `android/bin/` | 把脚本放回原位，不要在别处调用 |
| junction 校验不过 | 打印手工命令 `mklink /J C:/bilisail-build <repo>` | 按提示建链接，或把工程移到纯 ASCII 路径 |
| 找不到 JDK 17+ | 「AGP 9 requires JDK 17 or newer」 | 装 JDK 17+，或把它放进被扫描的固定目录 |
| 无 MSYS2 且无 mux 资产 | 只有 WARN，随后 ps1 报缺原生资产 | 装 MSYS2，或按 mux README 预置 `libbili_mux.so` |
| Gradle 构建失败 | 退出码 + libmpv jar 手动兜底路径 | 按提示手工放置三个 jar 后重跑（哈希仍会校验） |
| 没有匹配产物 | 期望命名格式 + 目录 | 说明 ps1 未产出交付件，看 ps1 日志而非本脚本 |
| 安装失败 | 提示接 USB 与开调试后重试 | 不自动卸载、不清数据，保持已装版本与数据 |

退出码只可能是 `0`（`:done`）或 `1`（`:fail`）。注意：把本脚本或 ps1 的输出接进管道（例如 `| tail`）会让上层看到的退出码变成管道程序的退出码，**掩盖真实失败**；需要判成败时直接取 `$LASTEXITCODE` / `errorlevel`。

---

## 9. 运行方式

```
:: 双击 android\bin\build-apk.cmd（推荐，人交互）
:: 或命令行
cmd /c android\bin\build-apk.cmd < NUL      :: 免按键，choice 走默认 N
pwsh -File tool\build-android-development.ps1 -Mode Release -SkipMuxBuild   :: 绕过本脚本，需自备 JDK 17+ 环境
```

本脚本无参数：模式固定 Release、目标固定 `lib/main.dart`、ABI 固定 arm64。需要 Debug/Profile 或别的入口时直接用 ps1 并自行处理 JDK；`-Install` 需要显式设备号，本脚本的安装分支不依赖它。

---

## 10. 已核 / 未验证

**已核（本轮真实跑过）**

- 全链路真实成功一次：脚本自行探测到 Dragonwell 21（本机 `JAVA_HOME` 指向 JDK 8），Gradle 通过，产物名 `BiliSail-test-arm64-release-6.2.6+6-20261106-100544.apk`，63,743,588 字节，`BuiltAt 2026-11-06T10:05:44+08:00`，身份 `dev.bilisail.bilisail.test`／「BiliSail 测试版」／VersionCode 62606。
- 第 6 步的解析行是**从本脚本原文抽出**跑夹具验证的：同模式最新件胜出、`.apk.sha256`/`.apk.json` 不被当产物、旧固定名不匹配、Profile 与 Release 互不串、空目录按预期报错。
- `tool/check.ps1 -Stage Lint -SkipPub` 全绿（CI 计划 27、Android 版本 41、签名边界 21、开发包身份 7、媒体通知资源 25；五工程 `dart format` 0 改动；`flutter analyze` 无问题）。
- 交付件 SHA-256 与改名前那次构建逐字相同，说明命名改动只影响文件名、不影响 APK 内容。

**未验证**

- 真人双击场景的交互分支：本轮把 stdin 重定向到 NUL 跑通，日志里 `choice` 直接落在 N、`pause` 未阻塞，但无法区分这是「15 秒超时默认」还是「输入被重定向后的即时默认」；`Y → 安装` 这条路径当时无设备，没有执行过。
- 非 ASCII 路径的 junction 分支：本机工程路径本来就是纯 ASCII，`:setup_junction` 只经代码读过，未实跑。
- mux 组件的「现场构建」分支：本机命中预构建资产，`bash -l` + gcc 包装那条路径本轮没跑。
- libmpv jar 的下载与代理分支：三个 jar 全部命中 `cached via local`，`direct` / `gh-proxy` / `system-proxy` 传输选择与 Gradle `-D` 参数透传未在本机复现。
- Profile / Debug 模式的新命名产物未构建过；三个设备回归脚本解析到的最新件是否被正确安装与恢复，需要连设备验证。
- 上表失败态的文案与行为按源码描述，除「Gradle JVM 版本不符」这一条外，其余未逐条实测触发。
