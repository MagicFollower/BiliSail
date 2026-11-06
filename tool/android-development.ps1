# Local device validation must use this identity across every build mode.
$AndroidDevelopmentPackageId = 'dev.bilisail.bilisail.test'
$AndroidDevelopmentDisplayName = 'BiliSail 测试版'
$AndroidDevelopmentBuildArgument = '--android-project-arg=bilisailDevelopmentBuild=true'

function Get-AndroidDevelopmentAapt {
  $adb = (Get-Command adb -ErrorAction Stop).Source
  $sdk = Split-Path (Split-Path $adb)
  $name = if ($IsWindows) { 'aapt.exe' } else { 'aapt' }
  $tool = Get-ChildItem -LiteralPath (Join-Path $sdk 'build-tools') -Directory |
    Sort-Object { $_.Name -as [version] } -Descending |
    ForEach-Object { Join-Path $_.FullName $name } |
    Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
    Select-Object -First 1
  if (!$tool) { throw 'Android SDK aapt is required to verify the development identity.' }
  return $tool
}

# aapt writes UTF-8 regardless of the console codepage. PowerShell decodes native
# output with [Console]::OutputEncoding (OEM 936 on zh-CN hosts), which mangles the
# non-ASCII display name before the identity comparison. Read through .NET with an
# explicit UTF-8 decoder so the label check is codepage-independent.
function Read-AndroidToolOutput([string]$Executable, [string]$Arguments) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $Executable
  $psi.Arguments = $Arguments
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
  $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
  $process = [System.Diagnostics.Process]::Start($psi)
  $stdout = $process.StandardOutput.ReadToEnd()
  $stderr = $process.StandardError.ReadToEnd()
  $process.WaitForExit()
  if ($process.ExitCode -ne 0) {
    $global:LASTEXITCODE = $process.ExitCode
    return $null
  }
  $global:LASTEXITCODE = 0
  return ($stdout -split "`r?`n")
}

function ConvertFrom-AndroidDevelopmentBadging([string]$Report, [string]$Mode = 'Release') {
  $entry = [regex]::Match($Report, "(?m)^package: name='([^']+)' versionCode='([0-9]+)' versionName='([^']+)'")
  if (!$entry.Success -or $entry.Groups[1].Value -cne $AndroidDevelopmentPackageId) {
    throw "Development APK must use $AndroidDevelopmentPackageId. Installation was cancelled."
  }
  $label = [regex]::Match($Report, "(?m)^application-label:'([^']+)'\r?$")
  if (!$label.Success -or $label.Groups[1].Value -cne $AndroidDevelopmentDisplayName) {
    throw "Development APK must be named $AndroidDevelopmentDisplayName."
  }
  if ($Mode -eq 'Release' -and $Report -match '(?m)^application-debuggable\s*$') {
    throw 'The development Release APK must not be debuggable.'
  }
  return [pscustomobject]@{
    PackageId = $entry.Groups[1].Value
    VersionCode = [int]$entry.Groups[2].Value
    VersionName = $entry.Groups[3].Value
    DisplayName = $label.Groups[1].Value
  }
}

function Confirm-AndroidDevelopmentApk([string]$Package, [string]$Mode = 'Release') {
  $aapt = Get-AndroidDevelopmentAapt
  $report = Read-AndroidToolOutput $aapt "dump badging `"$Package`""
  if ($null -eq $report -or $LASTEXITCODE -ne 0) { throw 'Could not inspect the development APK.' }
  return ConvertFrom-AndroidDevelopmentBadging ($report -join [Environment]::NewLine) $Mode
}

function Install-AndroidDevelopmentApk([string]$DeviceId, [string]$Package, [string]$Mode = 'Release') {
  $null = Confirm-AndroidDevelopmentApk $Package $Mode
  & adb -s $DeviceId install -r $Package
  if ($LASTEXITCODE -ne 0) {
    throw 'Development APK install failed. Preserve installed data; do not uninstall or clear data automatically.'
  }
}

# Development artifacts are named per build instead of overwritten in place, so a
# delivered APK states which version and which build moment it came from. The
# suffix is what makes the file unambiguous once several builds coexist.
function Get-AndroidDevelopmentApkName([string]$Mode, [string]$Version, [datetime]$BuiltAt) {
  if ([string]::IsNullOrWhiteSpace($Version)) { throw 'A development APK name requires the pubspec version.' }
  $stamp = $BuiltAt.ToString('yyyyMMdd-HHmmss')
  return "BiliSail-test-arm64-$($Mode.ToLowerInvariant())-$Version-$stamp.apk"
}

# Callers that need "the current normal-entry APK" must not pin a name that
# changes every build: resolve the newest one for that mode.
function Resolve-AndroidDevelopmentApk([string]$RepoRoot, [string]$Mode = 'Release') {
  $directory = Join-Path $RepoRoot 'build/development/android-arm64'
  $pattern = "BiliSail-test-arm64-$($Mode.ToLowerInvariant())-*.apk"
  $latest = @(Get-ChildItem -LiteralPath $directory -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like $pattern } |
    Sort-Object LastWriteTime, Name -Descending) | Select-Object -First 1
  if (!$latest) {
    throw "No development $Mode APK matches $pattern under $directory. Build it first with tool\build-android-development.ps1 -Mode $Mode."
  }
  return $latest.FullName
}
