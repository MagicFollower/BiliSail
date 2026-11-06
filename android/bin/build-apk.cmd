@echo off
setlocal EnableExtensions EnableDelayedExpansion
title BiliSail Test - Android APK Builder

REM ============================================================
REM  BiliSail Android arm64 development APK - one-click builder.
REM  Double-click to run.
REM
REM  Location : <repo root>\android\bin\build-apk.cmd
REM  Output   : <repo root>\build\development\android-arm64\
REM             BiliSail-test-arm64-release-<version>-<yyyyMMdd-HHmmss>.apk
REM             e.g. BiliSail-test-arm64-release-6.2.6+6-20261106-093512.apk
REM             (.sha256 / .json metadata share the same base name)
REM  Package  : dev.bilisail.bilisail.test (the "BiliSail" test app,
REM             local development signing; coexists with the release
REM             package dev.bilisail.bilisail)
REM
REM  Steps:
REM    1. Locate the Flutter SDK.
REM    2. Locate the Android SDK.
REM    3. Locate a JDK 17+ (required by AGP 9).
REM    4. Reuse or build the bili_mux native component (needs MSYS2).
REM    5. Call tool\build-android-development.ps1 in Release mode.
REM       That script builds the APK, then verifies the package id,
REM       display name, signature and the release/not-debuggable
REM       identity, and writes .sha256/.json metadata next to it.
REM    6. Report the artifact and offer an adb install.
REM
REM  This script only locates the toolchains and delegates to the
REM  standard entry point; it does not duplicate any signing or
REM  verification rules.
REM
REM  Non-ASCII project paths break the Dart AOT snapshotter, so when
REM  one is detected the whole build runs through the pure-ASCII
REM  directory junction C:\bilisail-build (see the notice below).
REM  All script text is plain ASCII on purpose: cmd renders it the
REM  same way under every console codepage, so output can never
REM  turn into mojibake.
REM ============================================================

set "SCRIPT_DIR=%~dp0"
REM android\bin\ -> android\ -> repo root
for %%I in ("%SCRIPT_DIR%..\..") do set "REPO_ROOT=%%~fI"
set "TOOL_DIR=%REPO_ROOT%\tool"

echo.
echo  ============================================
echo    BiliSail Test - Android APK Builder
echo  ============================================
echo.

REM ---------- 0. sanity checks ----------
if not exist "%REPO_ROOT%\pubspec.yaml" (
    echo [ERROR] Flutter project root not found: %REPO_ROOT%
    echo         Keep this script inside android\bin\.
    goto :fail
)
if not exist "%TOOL_DIR%\build-android-development.ps1" (
    echo [ERROR] Build entry not found: %TOOL_DIR%\build-android-development.ps1
    goto :fail
)

REM ---------- 0.1 ASCII path check ----------
set "NEED_JUNCTION=0"
set "ASCII_PROBE="
REM powershell.exe is always present. The pwsh app-execution alias cannot
REM be resolved by cmd's for /f in some environments, so probe with that.
set "PROBE_CMD=powershell -NoProfile -Command"
for /f "usebackq delims=" %%P in (`%PROBE_CMD% "if ('%REPO_ROOT%' -match '[^\u0000-\u007F]') { 'nonascii' } else { 'ascii' }"`) do set "ASCII_PROBE=%%P"
if "%ASCII_PROBE%"=="nonascii" (
    set "NEED_JUNCTION=1"
    echo.
    echo  ------------------------------------------------------------
    echo   [INFO] The project path contains non-ASCII characters:
    echo          %REPO_ROOT%
    echo          The Dart AOT snapshotter cannot build under a non-ASCII
    echo          path, so this build runs through the pure-ASCII
    echo          directory junction C:\bilisail-build instead.
    echo.
    echo          - The junction is a link only: it uses no extra disk
    echo            space and copies no files.
    echo          - Do not delete it between builds; the script verifies
    echo            and reuses it. To clean it up, run:
    echo              rmdir C:\bilisail-build
    echo            That removes the link only, never project files; the
    echo            next build recreates it automatically.
    echo  ------------------------------------------------------------
    echo.
) else (
    echo  [INFO] Project path is pure ASCII; building in place.
)

if "%NEED_JUNCTION%"=="1" call :setup_junction
if errorlevel 1 goto :fail
if "%NEED_JUNCTION%"=="1" (
    set "REPO_ROOT=%JROOT%"
    set "TOOL_DIR=%JROOT%\tool"
)
REM ---------- 1. locate the Flutter SDK ----------
set "FLUTTER_BIN="
if exist "%FLUTTER_HOME%\bin\flutter.bat" set "FLUTTER_BIN=%FLUTTER_HOME%\bin\flutter.bat"
if not defined FLUTTER_BIN if exist "%FLUTTER_ROOT%\bin\flutter.bat" set "FLUTTER_BIN=%FLUTTER_ROOT%\bin\flutter.bat"
if not defined FLUTTER_BIN call :find_on_path flutter.bat FLUTTER_BIN
if not defined FLUTTER_BIN for %%D in (
    "%USERPROFILE%\dev\flutter"
    "%LOCALAPPDATA%\flutter"
    "%USERPROFILE%\flutter"
    "%USERPROFILE%\fvm\default"
    "C:\flutter"
    "C:\src\flutter"
    "C:\tools\flutter"
) do (
    if not defined FLUTTER_BIN if exist "%%~D\bin\flutter.bat" set "FLUTTER_BIN=%%~D\bin\flutter.bat"
)
if not defined FLUTTER_BIN (
    echo [ERROR] Flutter SDK not found.
    echo         Set FLUTTER_HOME to your Flutter install and retry.
    goto :fail
)
echo [1/6] Flutter SDK : %FLUTTER_BIN%

REM ---------- 2. locate the Android SDK ----------
set "SDK="
if defined ANDROID_HOME if exist "%ANDROID_HOME%\platform-tools" set "SDK=%ANDROID_HOME%"
if not defined SDK if defined ANDROID_SDK_ROOT if exist "%ANDROID_SDK_ROOT%\platform-tools" set "SDK=%ANDROID_SDK_ROOT%"
if not defined SDK for %%D in (
    "%LOCALAPPDATA%\Android\Sdk"
    "%USERPROFILE%\dev\android-sdk"
    "C:\Android\Sdk"
) do (
    if not defined SDK if exist "%%~D\platform-tools" set "SDK=%%~D"
)
if not defined SDK (
    echo [ERROR] Android SDK not found. Install it or set ANDROID_HOME.
    goto :fail
)
set "ANDROID_HOME=%SDK%"
set "ANDROID_SDK_ROOT=%SDK%"
echo [2/6] Android SDK : %SDK%

REM ---------- 3. locate a JDK 17+ (required by AGP 9) ----------
REM The result is stored in BUILD_JDK and exported for the build in step
REM 5; any JDK 17+ found this way is used even when JAVA_HOME points at
REM an older JDK.
set "BUILD_JDK="
if defined JAVA_HOME (
    call :java_major "%JAVA_HOME%" JAVA_MAJOR
    if !JAVA_MAJOR! GEQ 17 set "BUILD_JDK=%JAVA_HOME%"
)
if not defined BUILD_JDK for %%D in (
    "D:\JDK"
    "C:\Program Files\Java"
    "C:\Program Files\Eclipse Adoptium"
    "C:\Program Files\Microsoft"
    "C:\Program Files\Zulu"
    "C:\Program Files\Android\Android Studio\jbr"
) do (
    if not defined BUILD_JDK (
        if exist "%%~D\bin\java.exe" (
            call :java_major "%%~D" JAVA_MAJOR
            if !JAVA_MAJOR! GEQ 17 set "BUILD_JDK=%%~D"
        ) else if exist "%%~D\" (
            for /d %%J in ("%%~D\*") do (
                if not defined BUILD_JDK if exist "%%~fJ\bin\java.exe" (
                    call :java_major "%%~fJ" JAVA_MAJOR
                    if !JAVA_MAJOR! GEQ 17 set "BUILD_JDK=%%~fJ"
                )
                if not defined BUILD_JDK for /d %%K in ("%%~fJ\*") do (
                    if not defined BUILD_JDK if exist "%%~fK\bin\java.exe" (
                        call :java_major "%%~fK" JAVA_MAJOR
                        if !JAVA_MAJOR! GEQ 17 set "BUILD_JDK=%%~fK"
                    )
                )
            )
        )
    )
)
if not defined BUILD_JDK (
    echo [ERROR] No JDK 17+ found. AGP 9 requires JDK 17 or newer.
    goto :fail
)
echo [3/6] JDK         : %BUILD_JDK% (Java !JAVA_MAJOR!)

REM ---------- 4. reuse or build the bili_mux native component ----------
REM tool\build-android-development.ps1 builds the mux component by default.
REM Building it needs MSYS2, so this script prefers the existing prebuilt
REM asset and only builds when it is missing. The mux build must run
REM through a login shell (bash -l): a plain non-login bash does not put
REM /usr/bin on PATH, and the gcc driver then fails silently. The gcc
REM wrapper below pins the build to /ucrt64/bin/gcc.exe.
set "JAVA_HOME=%BUILD_JDK%"
set "PATH=%BUILD_JDK%\bin;%PATH%"
set "FLUTTER_SUPPRESS_ANALYTICS=true"
echo.
set "MSYS_BASH="
if defined BILI_MUX_MSYS_ROOT if exist "%BILI_MUX_MSYS_ROOT%\usr\bin\bash.exe" set "MSYS_BASH=%BILI_MUX_MSYS_ROOT%\usr\bin\bash.exe"
if not defined MSYS_BASH if exist "C:\msys64\usr\bin\bash.exe" set "MSYS_BASH=C:\msys64\usr\bin\bash.exe"
set "MUX_PREBUILT=%REPO_ROOT%\packages\bili_mux\native\prebuilt\android-arm64\libbili_mux.so"
set "GCC_SHIM=%TEMP%\bilisail_gcc.sh"
set "MUX_PAYLOAD=%TEMP%\bilisail_mux_build.sh"
set "SKIP_MUX_ARG="
if defined MSYS_BASH (
    if exist "%MUX_PREBUILT%" (
        echo  [INFO] MSYS2       : %MSYS_BASH%
        echo  [INFO] bili_mux prebuilt asset found; skipping its build.
        set "SKIP_MUX_ARG=-SkipMuxBuild"
    ) else (
        echo  [INFO] MSYS2       : %MSYS_BASH%
        echo.
        echo [4/6] Building the bili_mux Android arm64 component...
        echo       The first build takes a few minutes.
        > "%GCC_SHIM%" echo #!/bin/bash
        >> "%GCC_SHIM%" echo exec /ucrt64/bin/gcc.exe "$@"
        > "%MUX_PAYLOAD%" echo set -e
        >> "%MUX_PAYLOAD%" echo export PATH="/tmp/bilisail-gccwrap:/ucrt64/bin:$PATH"
        >> "%MUX_PAYLOAD%" echo export ANDROID_NDK_HOME="%SDK:\=/%/ndk/28.2.13676358"
        >> "%MUX_PAYLOAD%" echo mkdir -p /tmp/bilisail-gccwrap
        >> "%MUX_PAYLOAD%" echo cp "%GCC_SHIM:\=/%" /tmp/bilisail-gccwrap/gcc
        >> "%MUX_PAYLOAD%" echo chmod +x /tmp/bilisail-gccwrap/gcc
        >> "%MUX_PAYLOAD%" echo cd "%REPO_ROOT:\=/%"
        >> "%MUX_PAYLOAD%" echo bash packages/bili_mux/tool/build.sh android-arm64
        "%MSYS_BASH%" -l "%MUX_PAYLOAD%"
        if not errorlevel 1 (
            set "SKIP_MUX_ARG=-SkipMuxBuild"
        ) else (
            echo  [WARN] The bili_mux component build failed. Diagnostics:
            echo         build\download_mux\android-arm64\*.log
            echo         Continuing with the APK build; if the native asset
            echo         is still missing, the Flutter build will report it.
        )
    )
) else (
    echo  [WARN] MSYS2 bash not found; skipping the mux component build.
    echo         If packages\bili_mux\native\prebuilt\android-arm64 has no
    echo         libbili_mux.so yet, the Flutter build will report the
    echo         missing native asset.
)
echo [5/6] Building the development Release APK...
echo       The first build takes a few minutes.
set "PS_EXE="
for /f "delims=" %%Q in ('where pwsh 2^>nul') do if not defined PS_EXE set "PS_EXE=%%Q"
if not defined PS_EXE for /f "delims=" %%Q in ('where powershell 2^>nul') do if not defined PS_EXE set "PS_EXE=%%Q"
if not defined PS_EXE (
    echo [ERROR] Neither pwsh nor powershell was found on PATH.
    goto :fail
)
call "%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%TOOL_DIR%\build-android-development.ps1" -Mode Release %SKIP_MUX_ARG%
set "BUILD_RC=%errorlevel%"
if not "%BUILD_RC%"=="0" (
    echo.
    echo [ERROR] APK build failed, exit code %BUILD_RC%. See the log above.
    echo   A GitHub download timeout for the libmpv jars is handled before Gradle
    echo   runs: tool\android-libmpv-assets.ps1 stages the three jars under the
    echo   plugin build directory build\media_kit_libs_android_video\20260906 after
    echo   checking the SHA-256 pins that the plugin itself declares, and it forwards
    echo   the Windows system proxy to Gradle only when a direct route fails on this
    echo   machine.
    echo   If no route works, copy those three jars into that directory by hand and
    echo   run this script again; the checksums are verified either way.
    goto :fail
)

REM ---------- 6. report the result ----------
REM Every build writes a new version+timestamp artifact instead of overwriting
REM one name, so the deliverable is the newest Release artifact in the folder.
set "APK_DIR=%REPO_ROOT%\build\development\android-arm64"
set "APK_OUT="
for /f "delims=" %%A in ('dir /b /a-d /o:-D "%APK_DIR%\BiliSail-test-arm64-release-*.apk" 2^>nul ^| findstr /r /c:"\.apk$"') do if not defined APK_OUT set "APK_OUT=%APK_DIR%\%%A"
if not defined APK_OUT (
    echo [ERROR] The build finished but no versioned Release APK was found:
    echo         Expected BiliSail-test-arm64-release-version-timestamp.apk in
    echo         %APK_DIR%
    goto :fail
)
if not exist "%APK_OUT%" (
    echo [ERROR] The build finished but the APK is missing: %APK_OUT%
    goto :fail
)
set "APK_BYTES=0"
for %%A in ("%APK_OUT%") do set "APK_BYTES=%%~zA"
set /a APK_MB=APK_BYTES/1048576

echo.
echo  ============================================
echo    BUILD OK
echo    APK : %APK_OUT%
echo    Size: !APK_MB! MB (.sha256/.json metadata sits next to it)
echo  ============================================
echo.
if exist "%SDK%\platform-tools\adb.exe" (
    choice /c YN /t 15 /d N /m "Install to a connected Android device now? (Y=install / N=skip, auto-skip in 15s)"
    if errorlevel 2 goto :done
    for /f "delims=" %%D in ('"%SDK%\platform-tools\adb.exe" devices ^| findstr /r /c:"device$"') do (
        echo [INFO] Installing to device: %%D
        "%SDK%\platform-tools\adb.exe" -s %%D install -r "%APK_OUT%"
        if errorlevel 1 (
            echo [INFO] Install failed. Connect the device via USB and
            echo        enable USB debugging, then retry.
        ) else (
            echo [INFO] Installed on device.
        )
    )
) else (
    echo [INFO] adb not found; skipping install.
)
goto :done

:fail
echo.
pause
exit /b 1

:done
echo.
pause
exit /b 0

REM ============ subroutines ============

:find_on_path
for %%P in ("%~1") do set "%~2=%%~$PATH:P"
exit /b 0

REM Creates C:\bilisail-build as an ASCII junction to the repo root and
REM verifies where it points. Only called when a non-ASCII project path
REM was detected; a stale junction is removed (the link only) and rebuilt.
:setup_junction
set "JROOT=C:\bilisail-build"
if not exist "%REPO_ROOT%\pubspec.yaml" (
    echo [ERROR] Project root not found: %REPO_ROOT%
    exit /b 1
)
if exist "%JROOT%\" (
    if exist "%JROOT%\pubspec.yaml" if exist "%JROOT%\android\bin\build-apk.cmd" goto :junction_ready
    REM Stale junction or it points elsewhere: remove the link only.
    rmdir /q "%JROOT%" >nul 2>&1
)
echo [INFO] Building via the ASCII junction: %JROOT% -^> %REPO_ROOT%
if not exist "%JROOT%" (
    cmd /c mklink /J "%JROOT%" "%REPO_ROOT%" >nul
    if errorlevel 1 (
        echo [ERROR] Failed to create the junction %JROOT%. Create it manually:
        echo         mklink /J C:\bilisail-build "%REPO_ROOT%"
        exit /b 1
    )
)
if not exist "%JROOT%\pubspec.yaml" (
    echo [ERROR] The junction %JROOT% does not point at the project root.
    exit /b 1
)
:junction_ready
exit /b 0

REM Sets %2 to the major version of the JDK at %1 (0 when unknown).
:java_major
setlocal EnableExtensions EnableDelayedExpansion
set "JEXE=%~1\bin\java.exe"
set "MAJOR=0"
if exist "%JEXE%" (
    set "JVFILE=%TEMP%\java_version_%RANDOM%.tmp"
    "%JEXE%" -version > "!JVFILE!" 2>&1
    for /f "usebackq tokens=3" %%V in (`findstr /i /c:"version" "!JVFILE!"`) do (
        set "V=%%~V"
        for /f "delims=. tokens=1" %%N in ("!V!") do set "MAJOR=%%N"
    )
    del /q "!JVFILE!" >nul 2>&1
)
endlocal & set "%~2=%MAJOR%"
exit /b 0
