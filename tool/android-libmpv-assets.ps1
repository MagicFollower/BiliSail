# Fetches the libmpv Android runtime jars that media_kit_libs_android_video
# downloads during Gradle evaluation, so a single flaky GitHub connection cannot
# fail the APK build. The checksum pins come from the plugin itself; the plugin
# re-verifies the same hashes when it finds the files already in place, so this
# helper never bypasses or replaces source or integrity checks.
$ErrorActionPreference = 'Stop'

function Get-LibmpvJarManifest {
  param(
    [Parameter(Mandatory)][string]$GradleFile,
    [Parameter(Mandatory)][string]$BuildDirectory
  )
  if (!(Test-Path -LiteralPath $GradleFile)) {
    throw "media_kit_libs_android_video build script is missing: $GradleFile"
  }
  $text = Get-Content -LiteralPath $GradleFile -Raw
  $pattern = '\["url":\s*"(?<url>[^"]+)",\s*"sha256":\s*"(?<sha256>[0-9a-f]{64})",\s*"destination":\s*file\("\$buildDir/(?<destination>[^"]+)"\)\]'
  $found = @([regex]::Matches($text, $pattern))
  if (!$found.Count) {
    throw "No libmpv jar entries were parsed from $GradleFile. The upstream layout changed."
  }
  return @(foreach ($match in $found) {
      [pscustomobject]@{
        Url         = $match.Groups['url'].Value
        Sha256      = $match.Groups['sha256'].Value
        Destination = [System.IO.Path]::Combine($BuildDirectory, $match.Groups['destination'].Value.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
      }
    })
}

function Resolve-MediaKitAndroidVideoProject {
  param([Parameter(Mandatory)][string]$RepoRoot)
  $configPath = [System.IO.Path]::Combine($RepoRoot, '.dart_tool', 'package_config.json')
  if (!(Test-Path -LiteralPath $configPath)) {
    throw 'Run flutter pub get before building; .dart_tool/package_config.json is missing.'
  }
  $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
  $entry = @($config.packages | Where-Object { $_.name -eq 'media_kit_libs_android_video' })
  if (!$entry.Count) {
    throw 'media_kit_libs_android_video is not resolved in the current package configuration.'
  }
  $packageDirectory = [System.Uri]::new($entry[0].rootUri).LocalPath
  $androidDirectory = [System.IO.Path]::Combine($packageDirectory, 'android')
  # Flutter evaluates each plugin project with its build directory relocated under
  # the application's own build tree, named after rootProject.name in the plugin's
  # settings.gradle. Staging must use the same location, otherwise Gradle still
  # downloads. If that relocation ever changes, the staged file simply is not found
  # and Gradle downloads as before; no checksum is skipped in either case.
  $settings = [System.IO.Path]::Combine($androidDirectory, 'settings.gradle')
  $projectName = $entry[0].name
  if (Test-Path -LiteralPath $settings) {
    $declared = [regex]::Match(
      (Get-Content -LiteralPath $settings -Raw),
      "rootProject\.name\s*=\s*['""](?<name>[^'""]+)['""]"
    )
    if ($declared.Success) { $projectName = $declared.Groups['name'].Value }
  }
  return [pscustomobject]@{
    GradleFile     = [System.IO.Path]::Combine($androidDirectory, 'build.gradle')
    BuildDirectory = [System.IO.Path]::Combine($RepoRoot, 'build', $projectName)
  }
}

function Get-WindowsSystemProxy {
  try {
    $settings = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
  } catch [System.Management.Automation.ItemNotFoundException] {
    return $null
  }
  if ($settings.ProxyEnable -ne 1) { return $null }
  $spec = "$($settings.ProxyServer)".Split(';')[0].Trim()
  if ($spec -match '^http=(.*):(\d+)$') { $spec = "$($Matches[1]):$($Matches[2])" }
  $parts = $spec.Split(':')
  if ($parts.Length -ne 2) { return $null }
  $port = 0
  if (!([int]::TryParse($parts[1], [ref] $port) -and $port -gt 0 -and $port -lt 65536)) { return $null }
  return [pscustomobject]@{ Host = $parts[0].Trim(); Port = $port }
}

function Test-TcpEndpoint {
  param([Parameter(Mandatory)][string]$ComputerName, [Parameter(Mandatory)][int]$Port)
  $client = [System.Net.Sockets.TcpClient]::new()
  try {
    $wait = $client.ConnectAsync($ComputerName, $Port).Wait(1500)
    return ($wait -and $client.Connected)
  } catch {
    return $false
  } finally {
    $client.Dispose()
  }
}

function Get-DownloadTransports {
  param([Parameter(Mandatory)][string]$Url, [AllowNull()]$Proxy)
  # Explicit proxy flags keep curl from silently inheriting machine state, so the
  # log names the transport that actually worked.
  $candidates = @(
    [pscustomobject]@{ Name = 'direct'; Url = $Url; Proxy = $null }
    [pscustomobject]@{ Name = 'gh-proxy'; Url = "https://gh-proxy.com/$Url"; Proxy = $null }
  )
  if ($null -ne $Proxy) {
    $endpoint = "http://$($Proxy.Host):$($Proxy.Port)"
    $candidates = @(
      [pscustomobject]@{ Name = 'system-proxy'; Url = $Url; Proxy = $endpoint }
      [pscustomobject]@{ Name = 'gh-proxy+system-proxy'; Url = "https://gh-proxy.com/$Url"; Proxy = $endpoint }
    ) + $candidates
  }
  return $candidates
}

function Save-VerifiedFile {
  param(
    [Parameter(Mandatory)][string]$Url,
    [Parameter(Mandatory)][string]$Sha256,
    [Parameter(Mandatory)][string]$Destination,
    [int]$MaxSeconds = 600,
    $Proxy = $null
  )
  if ((Test-Path -LiteralPath $Destination) -and
      (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToLowerInvariant() -eq $Sha256) {
    return [pscustomobject]@{ Status = 'cached'; Transport = 'local' }
  }
  $directory = [System.IO.Path]::GetDirectoryName($Destination)
  New-Item -ItemType Directory -Force -Path $directory | Out-Null
  $temporary = "$Destination.partial"
  $curl = [System.IO.Path]::Combine($env:SystemRoot, 'System32', 'curl.exe')
  $attempted = @()
  foreach ($transport in (Get-DownloadTransports -Url $Url -Proxy $Proxy)) {
    Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    $arguments = @(
      '--silent', '--show-error', '--fail', '--location', '--retry', '2',
      '--connect-timeout', '10', '--max-time', "$MaxSeconds",
      '--output', $temporary
    )
    if ($null -eq $transport.Proxy) { $arguments += @('--noproxy', '*') }
    else { $arguments += @('--proxy', $transport.Proxy) }
    $arguments += $transport.Url
    # curl diagnostics must not enter this function's output stream; the caller
    # receives only the status object.
    & $curl @arguments 2>&1 | Out-Null
    $failed = $LASTEXITCODE -ne 0
    $hash = if (Test-Path -LiteralPath $temporary) {
      (Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash.ToLowerInvariant()
    } else { '' }
    if ($failed -or $hash -cne $Sha256) {
      $attempted += $transport.Name
      continue
    }
    Move-Item -LiteralPath $temporary -Destination $Destination -Force
    return [pscustomobject]@{ Status = 'fetched'; Transport = $transport.Name }
  }
  throw ("Could not fetch a checksum-verified libmpv jar for " +
    "$Destination; transports tried: $($attempted -join ', ').")
}

function Ensure-LibmpvAndroidJars {
  # Returns exactly one object. Callers print the summary, so no progress line can
  # be captured into the assignment and silently disappear from the build log.
  param([Parameter(Mandatory)][string]$RepoRoot)
  $project = Resolve-MediaKitAndroidVideoProject -RepoRoot $RepoRoot
  $manifest = Get-LibmpvJarManifest -GradleFile $project.GradleFile -BuildDirectory $project.BuildDirectory
  $proxy = Get-WindowsSystemProxy
  $proxyListening = ($null -ne $proxy) -and (Test-TcpEndpoint -ComputerName $proxy.Host -Port $proxy.Port)
  $activeProxy = if ($proxyListening) { $proxy } else { $null }
  $jars = @()
  foreach ($entry in $manifest) {
    $saved = Save-VerifiedFile -Url $entry.Url -Sha256 $entry.Sha256 -Destination $entry.Destination -Proxy $activeProxy
    $jars += [pscustomobject]@{
      Name      = [System.IO.Path]::GetFileName($entry.Destination)
      Status    = $saved.Status
      Transport = $saved.Transport
    }
  }
  return [pscustomobject]@{
    BuildDirectory = $project.BuildDirectory
    Jars           = $jars
    ProxyAvailable = $proxyListening
    ProxyEndpoint  = if ($null -ne $proxy) { "$($proxy.Host):$($proxy.Port)" } else { '' }
    DirectFailed   = @($jars | Where-Object { $_.Status -eq 'fetched' -and $_.Transport -ne 'direct' }).Count -gt 0
    ProxyUsed      = @($jars | Where-Object { $_.Transport -like '*proxy*' }).Count -gt 0
  }
}

function Get-AndroidGradleNetworkArguments {
  # Route the Gradle JVM through the system proxy only when a direct GitHub fetch
  # failed here and a proxy is actually listening. Values must contain no cmd
  # metacharacters: Flutter's entry point is a .bat, so a pipe or angle bracket in
  # an argument would be parsed by cmd instead of reaching Gradle.
  param([Parameter(Mandatory)]$Network)
  if (-not $Network.DirectFailed -or -not $Network.ProxyAvailable) { return @() }
  $proxy = Get-WindowsSystemProxy
  if ($null -eq $proxy -or !(Test-TcpEndpoint -ComputerName $proxy.Host -Port $proxy.Port)) { return @() }
  return @(
    "-Dhttp.proxyHost=$($proxy.Host)", "-Dhttp.proxyPort=$($proxy.Port)",
    "-Dhttps.proxyHost=$($proxy.Host)", "-Dhttps.proxyPort=$($proxy.Port)"
  )
}
