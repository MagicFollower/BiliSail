param(
  [Parameter(Mandatory)]
  [string]$DeviceId,
  [ValidatePattern('^[a-z0-9-]+$')]
  [string]$Label = 'optimized',
  [ValidateSet('primary-switch', 'recommendation-updates', 'retained-cards')]
  [string]$Scenario = 'primary-switch',
  [switch]$SkipMuxBuild
)
$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $PSScriptRoot 'android-development.ps1')
. (Join-Path $PSScriptRoot 'android-signing.ps1')

function Invoke-ValidationCommand([string]$Executable, [string[]]$Parameters) {
  & $Executable @Parameters
  if ($LASTEXITCODE -ne 0) { throw "$Executable failed: $LASTEXITCODE" }
}

Push-Location $repoRoot
$powerState = $null
$previousSdk = $env:ANDROID_HOME
try {
  $adb = (Get-Command adb -ErrorAction Stop).Source
  if (!$env:ANDROID_HOME -and !$env:ANDROID_SDK_ROOT) {
    $env:ANDROID_HOME = Split-Path (Split-Path $adb)
  }
  Invoke-ValidationCommand $adb @('-s', $DeviceId, 'get-state')
  $powerState = (& $adb -s $DeviceId shell settings get global stay_on_while_plugged_in).Trim()
  Invoke-ValidationCommand $adb @('-s', $DeviceId, 'shell', 'svc', 'power', 'stayon', 'usb')
  Invoke-ValidationCommand $adb @('-s', $DeviceId, 'shell', 'input', 'keyevent', 'KEYCODE_WAKEUP')
  if (!$SkipMuxBuild) { & (Join-Path $PSScriptRoot 'build-download-mux.ps1') -Target android-arm64 }
  # Always preserve a fresh normal entry point before replacing the APK with a
  # deterministic fixture. All variants share the installed test app's data.
  & (Join-Path $PSScriptRoot 'build-android-development.ps1') -Mode Release -SkipMuxBuild
  $restorePackage = Resolve-AndroidDevelopmentApk $repoRoot
  $target = if ($Scenario -eq 'retained-cards') {
    'integration_test/android_retained_cards_test.dart'
  } elseif ($Scenario -eq 'recommendation-updates') {
    'integration_test/android_recommendation_updates_test.dart'
  } else { 'integration_test/android_primary_switch_test.dart' }

  Invoke-ValidationCommand flutter @(
    'build', 'apk', '--profile', '--target-platform', 'android-arm64', '--split-per-abi',
    '--target', $target,
    "--dart-define=SWITCH_LABEL=$Label",
    $AndroidDevelopmentBuildArgument
  )
  $apk = Join-Path $repoRoot "build/validation/$Scenario-$Label.apk"
  New-Item -ItemType Directory -Force -Path (Split-Path $apk) | Out-Null
  Copy-Item -LiteralPath 'build/app/outputs/flutter-apk/app-arm64-v8a-profile.apk' -Destination $apk
  $certificate = Confirm-AndroidApkSigning $apk ([pscustomobject]@{ Signing = 'temporary-debug-key' })
  $pinnedCertificate = (Get-Content -LiteralPath 'build/development/android-arm64/signing-certificate.sha256' -Raw).Trim()
  if ($certificate -cne $pinnedCertificate) { throw 'Profile and normal development APK signing identities differ.' }
  # Flutter drive can uninstall after a signature mismatch. Fail here first,
  # so neither the production app nor an incompatible validation app is erased.
  Install-AndroidDevelopmentApk $DeviceId $apk 'Profile'
  try {
    Invoke-ValidationCommand flutter @(
      'drive', '--profile', '--no-pub', '--keep-app-running', '-d', $DeviceId,
      '--driver', 'tool/validation/primary_switch_driver.dart',
      '--use-application-binary', $apk
    )
  } finally {
    Install-AndroidDevelopmentApk $DeviceId $restorePackage 'Release'
    Invoke-ValidationCommand $adb @('-s', $DeviceId, 'shell', 'am', 'force-stop', $AndroidDevelopmentPackageId)
    Invoke-ValidationCommand $adb @('-s', $DeviceId, 'shell', 'am', 'start', '-n', "$AndroidDevelopmentPackageId/dev.bilisail.bilisail.MainActivity")
  }
  Write-Output "Profile results: build/validation/$Scenario-$Label.json"
} finally {
  if ($null -ne $powerState -and
      (& $adb -s $DeviceId shell settings get global stay_on_while_plugged_in).Trim() -eq '2') {
    if ($powerState -eq 'null') { & $adb -s $DeviceId shell settings delete global stay_on_while_plugged_in }
    else { & $adb -s $DeviceId shell settings put global stay_on_while_plugged_in $powerState }
  }
  [Environment]::SetEnvironmentVariable('ANDROID_HOME', $previousSdk)
  Pop-Location
}
