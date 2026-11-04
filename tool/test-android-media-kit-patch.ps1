$ErrorActionPreference = 'Stop'
# Guards the media_kit_video Android patch without an Android SDK:
#   1. the pinned upstream sources still match the SHA-256 pins the Gradle patch
#      script refuses to build against otherwise, and the committed copies are
#      actually patched,
#   2. the parked-surface ordering regression really runs and really passes,
#   3. a retimed fallback is rejected, so the passing run above proves something.
# Pins are parsed from android/patches/media_kit_video/apply.gradle and never
# restated here, so this check and the Gradle build cannot disagree.

$root = Split-Path -Path $PSScriptRoot -Parent
$patchRoot = Join-Path (Join-Path $root 'android') 'patches/media_kit_video'
$applyScript = Join-Path $patchRoot 'apply.gradle'
$packagePath = Join-Path 'com' 'alexmercerind/media_kit_video'
$patchedJava = Join-Path (Join-Path $patchRoot 'java') $packagePath
$orderingTest = Join-Path $patchRoot 'SurfaceReleaseOrderingTest.java'
$names = @('VideoOutput.java', 'VideoOutputManager.java', 'MediaKitVideoPlugin.java')

foreach ($required in @($applyScript, $orderingTest)) {
  if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
    throw "Missing patch input: $required"
  }
}

function Get-NormalizedHash([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Missing source: $Path" }
  $text = [IO.File]::ReadAllText($Path).Replace("`r`n", "`n")
  $stream = [IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($text))
  try {
    return (Get-FileHash -InputStream $stream -Algorithm SHA256).Hash.ToLowerInvariant()
  } finally {
    $stream.Dispose()
  }
}

# --- 1. resolve the pinned media_kit_video checkout from the lock file ---
$lock = Get-Content -LiteralPath (Join-Path $root 'pubspec.lock') -Raw
$entry = [regex]::Match(
  $lock,
  '(?ms)^  media_kit_video:\r?\n.*?resolved-ref: "?(?<ref>[0-9a-f]{40})"?')
if (-not $entry.Success) { throw 'Could not read the media_kit_video resolved-ref from pubspec.lock.' }
$checkout = "media-kit-$($entry.Groups['ref'].Value)"
$cacheRoot = if ($env:LOCALAPPDATA) {
  Join-Path (Join-Path $env:LOCALAPPDATA 'Pub') 'Cache\git'
} elseif ($HOME) {
  Join-Path $HOME '.pub-cache/git'
} else {
  $null
}
$source = if ($cacheRoot -and (Test-Path -LiteralPath $cacheRoot -PathType Container)) {
  Get-ChildItem -LiteralPath $cacheRoot -Directory -Filter $checkout -ErrorAction SilentlyContinue |
    Select-Object -First 1
} else {
  $null
}
if ($null -eq $source) {
  Write-Output "SKIP media_kit_video patch check: $checkout is not in the Pub cache."
  exit 0
}
$upstreamJava = Join-Path (Join-Path (Join-Path $source.FullName 'media_kit_video') 'android') `
  ("src/main/java/" + ($packagePath -replace '\\', '/'))

# --- 2. pins enforced by the build, read from the build script itself ---
$pins = @{}
$applyText = Get-Content -LiteralPath $applyScript -Raw
foreach ($match in [regex]::Matches($applyText, "(?<name>'[A-Za-z]+\.java')\s*:\s*'(?<hash>[0-9a-f]{64})'")) {
  $pins[$match.Groups['name'].Value.Trim("'")] = $match.Groups['hash'].Value
}
if ($pins.Count -ne $names.Count) {
  throw "apply.gradle pins $($pins.Count) sources, expected $($names.Count)."
}

$checks = 0
foreach ($name in $names) {
  if (-not $pins.ContainsKey($name)) { throw "apply.gradle does not pin $name." }
  $actual = Get-NormalizedHash (Join-Path $upstreamJava $name)
  if ($actual -ne $pins[$name]) {
    throw "media_kit_video $name changed; review the surface release ordering patch. Expected $($pins[$name]), got $actual."
  }
  $patched = Join-Path $patchedJava $name
  if ((Get-NormalizedHash $patched) -eq $actual) {
    throw "media_kit_video $name is committed unpatched; the ordering fix would be a no-op."
  }
  $checks++
}

# --- 3. run the ordering regression with any JDK 17+ ---
function Get-Java([string]$Candidate) {
  foreach ($exe in @('java.exe', 'java')) {
    $path = Join-Path (Join-Path $Candidate 'bin') $exe
    if (Test-Path -LiteralPath $path -PathType Leaf) {
      $version = (& $path -version 2>&1 | Select-Object -First 1) | Out-String
      $major = [regex]::Match($version, 'version "?(?<m>\d+)')
      if ($major.Success) {
        return [pscustomobject]@{Exe = $path; Major = [int]$major.Groups['m'].Value}
      }
    }
  }
  return $null
}

$candidates = @()
if ($env:JAVA_HOME) { $candidates += $env:JAVA_HOME }
foreach ($probe in @('D:\JDK', 'C:\Program Files\Java', 'C:\Program Files\Eclipse Adoptium',
  'C:\Program Files\Microsoft', 'C:\Program Files\Android\Android Studio\jbr')) {
  if (Test-Path -LiteralPath $probe -PathType Container) {
    $candidates += $probe
    # Installs nest, e.g. D:\JDK\<distribution>\<jdk-21>\bin\java.exe.
    $candidates += (Get-ChildItem -LiteralPath $probe -Recurse -Depth 4 -Filter 'java.exe' -File -ErrorAction SilentlyContinue |
      ForEach-Object { $_.Directory.Parent.FullName })
  }
}
$java = $null
foreach ($candidate in $candidates) {
  $found = Get-Java $candidate
  if ($null -ne $found -and $found.Major -ge 17) { $java = $found; break }
}
if ($null -eq $java) {
  Write-Output 'SKIP media_kit_video patch check: no JDK 17+ can run the ordering regression.'
  exit 0
}

$work = Join-Path ([IO.Path]::GetTempPath()) ("bilisail-media-kit-patch-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -Force | Out-Null
try {
  $outputs = $names | ForEach-Object { Join-Path $patchedJava $_ }
  $report = & $java.Exe $orderingTest $outputs[0] $outputs[1] $outputs[2] (Join-Path $work 'classes') 2>&1
  if ($LASTEXITCODE -ne 0 -or (($report | Out-String) -notmatch 'assertions passed')) {
    throw "media_kit_video ordering regression failed:`n$($report | Out-String)"
  }
  $checks++

  # Negative control: a fallback that no longer outlives the core's five-second
  # destroy timer must fail.
  $mutated = Join-Path $work 'mutated'
  New-Item -ItemType Directory -Path $mutated -Force | Out-Null
  foreach ($path in $outputs) { Copy-Item -LiteralPath $path -Destination $mutated }
  $target = Join-Path $mutated 'VideoOutput.java'
  $text = [IO.File]::ReadAllText($target)
  if ($text -notmatch 'RELEASE_FALLBACK_MILLIS = (\d+)L') {
    throw 'Patched VideoOutput.java no longer declares a fallback delay.'
  }
  [IO.File]::WriteAllText($target, $text.Replace($Matches[0], 'RELEASE_FALLBACK_MILLIS = 5000L'))
  $mutatedOutputs = $names | ForEach-Object { Join-Path $mutated $_ }
  $rejectedReport = & $java.Exe $orderingTest $mutatedOutputs[0] $mutatedOutputs[1] $mutatedOutputs[2] (
    Join-Path $work 'mutated-classes') 2>&1
  $text2 = $rejectedReport | Out-String
  if ($text2 -notmatch 'Fallback must outlive') {
    throw "Retimed fallback was not rejected by the expected assertion:`n$text2"
  }
  if ($LASTEXITCODE -eq 0) {
    throw 'A fallback delay inside the core destroy window exited successfully.'
  }
  $checks++
} finally {
  Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output "media_kit_video Android patch checks passed: $checks"
