$ErrorActionPreference = 'Stop'
$version = $env:REQUESTED_VERSION.Trim()
if (!$version) {
  $match = [regex]::Match((Get-Content pubspec.yaml -Raw), '(?m)^version:\s*(\S+)\s*$')
  if (!$match.Success) { throw 'pubspec.yaml has no version.' }
  $version = $match.Groups[1].Value
}
if ($version -cnotmatch '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)\+(0|[1-9]\d*)$') {
  throw 'Version must be x.y.z+N, for example 0.1.0+1.'
}
if ($env:ENABLE_ANDROID -ne 'true') {
  throw 'This checkout builds Android only; set ENABLE_ANDROID=true.'
}
. (Join-Path $PSScriptRoot 'android-version.ps1')
Get-AndroidVersionCode $version | Out-Null
$platforms = @(
  @{ target = 'android-arm64'; runner = 'ubuntu-24.04'; arch = 'x64' }
)
if (![string]::IsNullOrWhiteSpace($env:BUILD_TARGETS)) {
  $targets = ConvertFrom-Json -InputObject $env:BUILD_TARGETS -NoEnumerate
  if ($targets -isnot [array] -or !$targets.Count -or
      @($targets | Where-Object { $_ -isnot [string] -or $_ -cnotin $platforms.target }).Count -or
      @($targets | Select-Object -Unique).Count -ne $targets.Count) {
    throw 'Build targets must be a nonempty JSON array of distinct selected targets.'
  }
  $platforms = @($platforms | Where-Object { $_.target -cin $targets })
}
"version=$version" >> $env:GITHUB_OUTPUT
"matrix=$(@{ include = @($platforms) } | ConvertTo-Json -Depth 3 -Compress)" >> $env:GITHUB_OUTPUT
