$ErrorActionPreference = 'Stop'
$checks = 0
$outputFile = [System.IO.Path]::GetTempFileName()
$names = @('GITHUB_OUTPUT', 'REQUESTED_VERSION', 'ENABLE_ANDROID', 'BUILD_TARGETS')
$previous = @{}
foreach ($name in $names) { $previous[$name] = [Environment]::GetEnvironmentVariable($name) }

function Invoke-Plan([string]$Version, [bool]$AndroidEnabled, [string]$BuildTargets = '') {
  $env:REQUESTED_VERSION = $Version
  $env:BUILD_TARGETS = $BuildTargets
  [Environment]::SetEnvironmentVariable(
    'ENABLE_ANDROID',
    $AndroidEnabled.ToString().ToLowerInvariant()
  )
  [System.IO.File]::WriteAllText($outputFile, '')
  & (Join-Path $PSScriptRoot 'ci-build-plan.ps1')
  $values = @{}
  foreach ($line in Get-Content -LiteralPath $outputFile) {
    $key, $value = $line -split '=', 2
    $values[$key] = $value
  }
  return $values
}

function Assert-Rejected(
  [string]$Version,
  [bool]$AndroidEnabled,
  [string]$BuildTargets = ''
) {
  $rejected = $false
  try {
    Invoke-Plan $Version $AndroidEnabled $BuildTargets | Out-Null
  } catch {
    $rejected = $true
  }
  if (!$rejected) {
    throw "Invalid plan accepted: version=$Version android=$AndroidEnabled targets=$BuildTargets"
  }
  $script:checks++
}

try {
  $env:GITHUB_OUTPUT = $outputFile
  Assert-Rejected '1.2.5+0' $false

  $include = @(((Invoke-Plan '1.2.5+0' $true).matrix | ConvertFrom-Json).include)
  if ($include.Count -ne 1 -or $include[0].target -cne 'android-arm64' -or
      $include[0].runner -cne 'ubuntu-24.04' -or $include[0].arch -cne 'x64') {
    throw 'The plan must contain exactly one Android arm64 target.'
  }
  $checks++

  if ((Invoke-Plan ' 1.2.5+1 ' $true).version -cne '1.2.5+1') {
    throw 'Version override was not trimmed.'
  }
  $checks++
  $sourceVersion = [regex]::Match(
    (Get-Content pubspec.yaml -Raw),
    '(?m)^version:\s*(\S+)\s*$'
  ).Groups[1].Value
  if ((Invoke-Plan '' $true).version -cne $sourceVersion) {
    throw 'Empty version did not use pubspec.yaml.'
  }
  $checks++

  foreach ($version in @('v1.2.5', '1.2.5', '01.2.5+0', '1.2.5+-1', '1.2.5+00')) {
    Assert-Rejected $version $true
  }
  # Android compact versionCode keeps minor/patch at one digit and build at 0..99.
  foreach ($version in @('1.10.5+0', '1.2.5+100', '256.10.5+1000')) {
    Assert-Rejected $version $true
  }

  $selected = Invoke-Plan '1.2.5+0' $true '["android-arm64"]'
  if (@(($selected.matrix | ConvertFrom-Json).include).Count -ne 1) {
    throw 'The selected Android target was dropped.'
  }
  $checks++
  foreach ($invalid in @(
      '[]',
      'null',
      '"android-arm64"',
      '{}',
      '["unknown"]',
      '["android-arm64","android-arm64"]',
      '["android-arm64",null]',
      '[42]',
      'not-json',
      '["windows-x64"]',
      '["macos-arm64"]',
      '["macos-x64"]',
      '["ios-arm64"]',
      '["linux-x64"]'
    )) {
    Assert-Rejected '1.2.5+0' $true $invalid
  }
} finally {
  foreach ($name in $names) {
    [Environment]::SetEnvironmentVariable($name, $previous[$name])
  }
  Remove-Item -LiteralPath $outputFile
}
Write-Output "CI build plan checks passed: $checks"
