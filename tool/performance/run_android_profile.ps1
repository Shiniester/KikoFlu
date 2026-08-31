param(
  [Parameter(Mandatory = $true)]
  [string]$DeviceId,

  [ValidateSet('baseline', 'candidate')]
  [string]$Label = 'candidate',

  [string]$OutputDirectory = 'build/performance_reports',

  [string]$FixtureDirectory = 'build/performance_fixtures',

  [ValidateRange(2, 16384)]
  [int]$ZipMegabytes = 512,

  [string]$BaselineReport,

  [string]$PlaybackFixture,

  [ValidateRange(1, 120)]
  [int]$SoakMinutes = 30,

  [ValidateRange(0, 2)]
  [int]$MaximumThermalStatus = 2,

  [switch]$SkipSoak
)

$ErrorActionPreference = 'Stop'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$resolvedOutput = [IO.Path]::GetFullPath((Join-Path $repositoryRoot $OutputDirectory))
$resolvedFixtures = [IO.Path]::GetFullPath((Join-Path $repositoryRoot $FixtureDirectory))
$packageName = 'com.meteor.kikoeruflutter'
$deviceFixtureRoot = "/sdcard/Android/data/$packageName/files/performance_fixtures"
$deviceManifestPath = "$deviceFixtureRoot/manifest.json"
$deviceControlPath = "$deviceFixtureRoot/control.json"
$devicePlaybackManifestPath = "$deviceFixtureRoot/playback_fixture.json"

function Invoke-Adb {
  param([string[]]$Arguments)
  $output = & adb @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "adb failed: adb $($Arguments -join ' ')"
  }
  return ($output -join "`n").Trim()
}

function Get-ThermalStatus {
  $output = Invoke-Adb @('-s', $DeviceId, 'shell', 'cmd', 'thermalservice', 'get-current-status')
  $match = [regex]::Match($output, '(\d+)\s*$')
  if (-not $match.Success) {
    $output = Invoke-Adb @('-s', $DeviceId, 'shell', 'dumpsys', 'thermalservice')
    $match = [regex]::Match($output, 'mStatus\s*=\s*(\d+)')
  }
  if (-not $match.Success) { throw 'Unable to read Android thermal status.' }
  return [int]$match.Groups[1].Value
}

function Get-BatteryState {
  $output = Invoke-Adb @('-s', $DeviceId, 'shell', 'dumpsys', 'battery')
  $level = [regex]::Match($output, '(?m)^\s*level:\s*(\d+)')
  $temperature = [regex]::Match($output, '(?m)^\s*temperature:\s*(\d+)')
  if (-not $level.Success -or -not $temperature.Success) {
    throw 'Unable to read Android battery state.'
  }
  return @{
    level = [int]$level.Groups[1].Value
    temperature = [int]$temperature.Groups[1].Value
  }
}

function Wait-ForThermalReady {
  for ($attempt = 1; $attempt -le 80; $attempt++) {
    $status = Get-ThermalStatus
    if ($status -le $MaximumThermalStatus) { return $status }
    Write-Host "Thermal status $status is above $MaximumThermalStatus; cooling..."
    Start-Sleep -Seconds 15
  }
  throw 'The device did not return to the accepted thermal state.'
}

function Push-ControlFile {
  param(
    [string]$Path,
    [hashtable]$Values
  )
  Write-JsonFile -Path $Path -Value $Values
  Invoke-Adb @('-s', $DeviceId, 'push', $Path, $deviceControlPath) | Out-Null
}

function Write-JsonFile {
  param(
    [string]$Path,
    [object]$Value
  )
  $json = $Value | ConvertTo-Json -Depth 8
  [IO.File]::WriteAllText($Path, $json, $utf8NoBom)
}

function Read-ReportData {
  param([string]$Path)
  $envelope = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
  if ($null -ne $envelope.data) { return $envelope.data }
  return $envelope
}

New-Item -ItemType Directory -Force -Path $resolvedOutput | Out-Null

$connected = & adb devices
if ($LASTEXITCODE -ne 0 -or -not ($connected -match "(?m)^$([regex]::Escape($DeviceId))\s+device$")) {
  throw "Android device '$DeviceId' is not connected and authorized."
}

$apiLevel = [int](Invoke-Adb @('-s', $DeviceId, 'shell', 'getprop', 'ro.build.version.sdk'))
if ($apiLevel -lt 24) { throw "Android API $apiLevel is below the API 24 minimum." }

$dfOutput = Invoke-Adb @('-s', $DeviceId, 'shell', 'df', '-Pk', '/data')
$dfLine = ($dfOutput -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 1)
$dfParts = $dfLine.Trim() -split '\s+'
if ($dfParts.Count -lt 4) { throw 'Unable to determine free device storage.' }
$freeKilobytes = [int64]$dfParts[3]
$minimumFreeKilobytes = 8 * 1024 * 1024
if ($freeKilobytes -lt $minimumFreeKilobytes) {
  throw 'The Android device needs at least 8GB free under /data.'
}

$wifiStatus = Invoke-Adb @('-s', $DeviceId, 'shell', 'cmd', 'wifi', 'status')
if ($wifiStatus -notmatch '(?i)enabled') {
  throw 'Wi-Fi must be enabled for the real playback soak.'
}
$lowPowerMode = Invoke-Adb @('-s', $DeviceId, 'shell', 'settings', 'get', 'global', 'low_power')
if ($lowPowerMode -ne '0') {
  throw 'Android battery saver must be disabled for comparable measurements.'
}

$revision = (& git -C $repositoryRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $revision -notmatch '^[a-f0-9]{40}$') {
  throw 'Unable to resolve the current Git revision.'
}

$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$runDirectory = Join-Path $resolvedOutput "${Label}_$timestamp"
New-Item -ItemType Directory -Force -Path $runDirectory | Out-Null

$manifestFile = Join-Path $resolvedFixtures 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestFile)) {
  Push-Location $repositoryRoot
  try {
    & dart run tool/performance/generate_fixtures.dart `
      --output $resolvedFixtures `
      --with-zip `
      --zip-uncompressed-mb $ZipMegabytes
    if ($LASTEXITCODE -ne 0) { throw 'Fixture generation failed.' }
  } finally {
    Pop-Location
  }
}
$manifest = Get-Content -Raw -LiteralPath $manifestFile | ConvertFrom-Json
if ($manifest.fixtureVersion -ne 2 -or
    $manifest.zipUncompressedBytes -ne ($ZipMegabytes * 1024 * 1024) -or
    $manifest.contentHash -notmatch '^[a-f0-9]{64}$') {
  throw 'Existing fixture manifest does not match the requested schema/ZIP size.'
}
$fixtureHash = [string]$manifest.contentHash

$model = Invoke-Adb @('-s', $DeviceId, 'shell', 'getprop', 'ro.product.model')
$androidVersion = Invoke-Adb @('-s', $DeviceId, 'shell', 'getprop', 'ro.build.version.release')
$fingerprint = Invoke-Adb @('-s', $DeviceId, 'shell', 'getprop', 'ro.build.fingerprint')
$windowAnimationScale = Invoke-Adb @('-s', $DeviceId, 'shell', 'settings', 'get', 'global', 'window_animation_scale')
$transitionAnimationScale = Invoke-Adb @('-s', $DeviceId, 'shell', 'settings', 'get', 'global', 'transition_animation_scale')
$animatorDurationScale = Invoke-Adb @('-s', $DeviceId, 'shell', 'settings', 'get', 'global', 'animator_duration_scale')
$deviceFile = Join-Path $runDirectory 'device.json'
$deviceMetadata = @{
  serial = $DeviceId
  model = $model
  androidVersion = $androidVersion
  apiLevel = $apiLevel
  buildMode = 'profile'
  fingerprint = $fingerprint
  freeDataKilobytes = $freeKilobytes
  windowAnimationScale = $windowAnimationScale
  transitionAnimationScale = $transitionAnimationScale
  animatorDurationScale = $animatorDurationScale
  lowPowerMode = $lowPowerMode
}
Write-JsonFile -Path $deviceFile -Value $deviceMetadata

if (-not $PlaybackFixture) {
  $PlaybackFixture = Join-Path $resolvedFixtures 'playback_fixture.json'
} elseif (-not [IO.Path]::IsPathRooted($PlaybackFixture)) {
  $PlaybackFixture = [IO.Path]::GetFullPath((Join-Path $repositoryRoot $PlaybackFixture))
}

Push-Location $repositoryRoot
try {
  & flutter pub get
  if ($LASTEXITCODE -ne 0) { throw 'flutter pub get failed.' }

  & flutter build apk --profile `
    --target integration_test/android_profile_test.dart `
    --dart-define=KIKOFLU_PERFORMANCE=true `
    --dart-define="KIKOFLU_PERF_CONTROL_PATH=$deviceControlPath"
  if ($LASTEXITCODE -ne 0) { throw 'Profile scenario APK build failed.' }
  $flutterApkPath = Join-Path $repositoryRoot 'build/app/outputs/flutter-apk/app-profile.apk'
  if (-not (Test-Path -LiteralPath $flutterApkPath)) {
    throw 'Profile scenario APK is missing.'
  }
  $scenarioApkPath = Join-Path $runDirectory 'kikoflu-profile-scenario.apk'
  Copy-Item -LiteralPath $flutterApkPath -Destination $scenarioApkPath

  $soakApkPath = $null
  if (-not $SkipSoak) {
    & flutter build apk --profile `
      --target integration_test/android_media3_soak_test.dart `
      --dart-define=KIKOFLU_PERFORMANCE=true `
      --dart-define="KIKOFLU_PERF_CONTROL_PATH=$deviceControlPath"
    if ($LASTEXITCODE -ne 0) { throw 'Media3 soak APK build failed.' }
    if (-not (Test-Path -LiteralPath $flutterApkPath)) {
      throw 'Media3 soak APK is missing.'
    }
    $soakApkPath = Join-Path $runDirectory 'kikoflu-profile-media3-soak.apk'
    Copy-Item -LiteralPath $flutterApkPath -Destination $soakApkPath
  }

  Invoke-Adb @('-s', $DeviceId, 'install', '-r', '-t', $scenarioApkPath) | Out-Null
  Invoke-Adb @('-s', $DeviceId, 'shell', 'rm', '-rf', $deviceFixtureRoot) | Out-Null
  Invoke-Adb @('-s', $DeviceId, 'shell', 'mkdir', '-p', $deviceFixtureRoot) | Out-Null
  Invoke-Adb @('-s', $DeviceId, 'push', (Join-Path $resolvedFixtures '.'), "$deviceFixtureRoot/") | Out-Null

  if (Test-Path -LiteralPath $PlaybackFixture) {
    Invoke-Adb @('-s', $DeviceId, 'push', $PlaybackFixture, $devicePlaybackManifestPath) | Out-Null
  } elseif ($Label -eq 'candidate') {
    throw 'Candidate soak requires the playback fixture created by baseline.'
  }

  $runFiles = @()
  for ($run = 1; $run -le 5; $run++) {
    $accepted = $false
    for ($attempt = 1; $attempt -le 5 -and -not $accepted; $attempt++) {
      $thermal = Wait-ForThermalReady
      $battery = Get-BatteryState
      if ($battery.level -lt 20) { throw 'Battery level must be at least 20%.' }

      $controlFile = Join-Path $runDirectory "control_run_$run.json"
      Push-ControlFile -Path $controlFile -Values @{
        mode = 'profile'
        label = $Label
        revision = $revision
        run = $run
        fixtureHash = $fixtureHash
        fixtureManifestPath = $deviceManifestPath
        playbackManifestPath = $devicePlaybackManifestPath
        thermalStatus = $thermal
        batteryPercent = $battery.level
        batteryTemperatureTenthsCelsius = $battery.temperature
        soakMinutes = $SoakMinutes
        trackSwitches = 50
      }

      Invoke-Adb @('-s', $DeviceId, 'shell', 'am', 'force-stop', $packageName) | Out-Null
      $runFile = Join-Path $runDirectory "run_$run.json"
      $env:KIKOFLU_PERF_RUN_OUTPUT = $runFile
      & flutter drive `
        --profile `
        --device-id $DeviceId `
        --driver test_driver/performance_driver.dart `
        --target integration_test/android_profile_test.dart `
        --use-application-binary $scenarioApkPath `
        --dart-define=KIKOFLU_PERFORMANCE=true `
        --dart-define="KIKOFLU_PERF_CONTROL_PATH=$deviceControlPath"
      if ($LASTEXITCODE -ne 0) { throw "Profile run $run failed." }

      $postThermal = Get-ThermalStatus
      if ($postThermal -le $MaximumThermalStatus) {
        $accepted = $true
        $runFiles += $runFile
      } else {
        Write-Host "Discarding run $run attempt ${attempt}: thermal=$postThermal"
        Remove-Item -LiteralPath $runFile -ErrorAction SilentlyContinue
      }
    }
    if (-not $accepted) { throw "Unable to obtain a thermally valid run $run." }
  }

  $soakFile = $null
  if (-not $SkipSoak) {
    Invoke-Adb @('-s', $DeviceId, 'install', '-r', '-t', $soakApkPath) | Out-Null
    $thermal = Wait-ForThermalReady
    $battery = Get-BatteryState
    $controlFile = Join-Path $runDirectory 'control_soak.json'
    Push-ControlFile -Path $controlFile -Values @{
      mode = 'media3-soak'
      label = $Label
      revision = $revision
      run = 0
      fixtureHash = $fixtureHash
      fixtureManifestPath = $deviceManifestPath
      playbackManifestPath = $devicePlaybackManifestPath
      thermalStatus = $thermal
      batteryPercent = $battery.level
      batteryTemperatureTenthsCelsius = $battery.temperature
      soakMinutes = $SoakMinutes
      trackSwitches = 50
    }
    Invoke-Adb @('-s', $DeviceId, 'shell', 'am', 'force-stop', $packageName) | Out-Null
    $soakFile = Join-Path $runDirectory 'media3_soak.json'
    $env:KIKOFLU_PERF_RUN_OUTPUT = $soakFile
    & flutter drive `
      --profile `
      --device-id $DeviceId `
      --driver test_driver/performance_driver.dart `
      --target integration_test/android_media3_soak_test.dart `
      --use-application-binary $soakApkPath `
      --dart-define=KIKOFLU_PERFORMANCE=true `
      --dart-define="KIKOFLU_PERF_CONTROL_PATH=$deviceControlPath"
    if ($LASTEXITCODE -ne 0) { throw 'Media3 soak failed.' }

    $soakData = Read-ReportData -Path $soakFile
    if ($soakData.playbackFixture.contentHash -notmatch '^[a-f0-9]{64}$') {
      throw 'Media3 soak did not produce a playback fixture hash.'
    }
    Write-JsonFile -Path $PlaybackFixture -Value $soakData.playbackFixture
  }

  Remove-Item Env:KIKOFLU_PERF_RUN_OUTPUT -ErrorAction SilentlyContinue
  $reportPath = Join-Path $runDirectory "${Label}.json"
  $assembleArguments = @(
    'run',
    'tool/performance/assemble.dart',
    $reportPath,
    $deviceFile,
    $Label,
    $revision
  ) + $runFiles
  if ($soakFile) { $assembleArguments += @('--shared-metrics', $soakFile) }
  & dart @assembleArguments
  if ($LASTEXITCODE -ne 0) { throw 'Unable to assemble performance report.' }

  if ($BaselineReport) {
    $comparisonJson = Join-Path $runDirectory 'comparison.json'
    $comparisonMarkdown = Join-Path $runDirectory 'comparison.md'
    & dart run tool/performance/compare.dart `
      $BaselineReport $reportPath `
      --json-output $comparisonJson `
      --markdown-output $comparisonMarkdown
    if ($LASTEXITCODE -ne 0) {
      throw "Performance acceptance failed. See $comparisonMarkdown"
    }
  }

  Write-Host "Profile report: $reportPath"
} finally {
  Remove-Item Env:KIKOFLU_PERF_RUN_OUTPUT -ErrorAction SilentlyContinue
  Pop-Location
}
