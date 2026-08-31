[CmdletBinding()]
param(
  [string]$ToolchainDirectory = 'build/toolchains',
  [switch]$ForceDownloads,
  [switch]$SkipProfileBuild
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$toolchainRoot = if ([IO.Path]::IsPathRooted($ToolchainDirectory)) {
  [IO.Path]::GetFullPath($ToolchainDirectory)
} else {
  [IO.Path]::GetFullPath((Join-Path $repositoryRoot $ToolchainDirectory))
}
$downloadsRoot = Join-Path $toolchainRoot 'downloads'
$sdkRoot = Join-Path $toolchainRoot 'android-sdk'
$androidCliRoot = Join-Path $toolchainRoot 'android-cli'
$androidUserHome = Join-Path $toolchainRoot 'android-user-home'
$gradleUserHome = Join-Path $toolchainRoot 'gradle-home'

$jdkVersion = '17.0.20.1'
$jdkHome = Join-Path $toolchainRoot "jdk-$jdkVersion"
$jdkArchive = Join-Path $downloadsRoot "microsoft-jdk-$jdkVersion-windows-x64.zip"
$jdkUri = "https://aka.ms/download-jdk/microsoft-jdk-$jdkVersion-windows-x64.zip"
$jdkChecksumUri = "${jdkUri}.sha256sum.txt"

$commandLineToolsRevision = '22.0'
$commandLineToolsArchive = Join-Path $downloadsRoot 'android-commandlinetools-15859902.zip'
$commandLineToolsUri = 'https://dl.google.com/android/repository/commandlinetools-win-15859902_latest.zip'
$commandLineToolsSha256 = '90ae805d20434428bffcb699c290860f19bb5f66a67e6b330067e3de801fb04a'
$standaloneSdkManager = Join-Path $androidCliRoot 'cmdline-tools/bin/sdkmanager.bat'
$sdkCommandLineTools = Join-Path $sdkRoot 'cmdline-tools/latest'
$sdkManager = Join-Path $sdkCommandLineTools 'bin/sdkmanager.bat'

function Assert-WithinToolchainRoot {
  param([string]$Path)
  $resolvedPath = [IO.Path]::GetFullPath($Path)
  $resolvedRoot = [IO.Path]::GetFullPath($toolchainRoot).TrimEnd('\') + '\'
  if (-not $resolvedPath.StartsWith($resolvedRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to modify a path outside the toolchain root: $resolvedPath"
  }
}

function Remove-ToolchainPath {
  param([string]$Path)
  Assert-WithinToolchainRoot -Path $Path
  if (Test-Path -LiteralPath $Path) {
    Remove-Item -LiteralPath $Path -Recurse -Force
  }
}

function Get-OfficialChecksum {
  param([string]$Uri)
  $response = Invoke-WebRequest -UseBasicParsing -Uri $Uri
  $content = if ($response.Content -is [byte[]]) {
    [Text.Encoding]::UTF8.GetString($response.Content)
  } else {
    [string]$response.Content
  }
  $match = [regex]::Match($content, '(?i)\b[a-f0-9]{64}\b')
  if (-not $match.Success) {
    throw "Official checksum response did not contain SHA-256: $Uri"
  }
  return $match.Value.ToLowerInvariant()
}

function Get-VerifiedDownload {
  param(
    [string]$Uri,
    [string]$Destination,
    [string]$ExpectedSha256
  )
  if ($ForceDownloads -or -not (Test-Path -LiteralPath $Destination)) {
    Write-Host "Downloading $Uri"
    Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $Destination
  }
  $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $Destination).Hash.ToLowerInvariant()
  if ($actual -ne $ExpectedSha256.ToLowerInvariant()) {
    throw "SHA-256 mismatch for $Destination. Expected $ExpectedSha256, got $actual."
  }
}

function Install-Jdk17 {
  $javaExecutable = Join-Path $jdkHome 'bin/java.exe'
  if ((Test-Path -LiteralPath $javaExecutable) -and -not $ForceDownloads) {
    return
  }

  $expectedJdkSha256 = Get-OfficialChecksum -Uri $jdkChecksumUri
  Get-VerifiedDownload `
    -Uri $jdkUri `
    -Destination $jdkArchive `
    -ExpectedSha256 $expectedJdkSha256

  $temporaryRoot = Join-Path $toolchainRoot ".jdk-install-$([guid]::NewGuid().ToString('N'))"
  Assert-WithinToolchainRoot -Path $temporaryRoot
  New-Item -ItemType Directory -Force -Path $temporaryRoot | Out-Null
  try {
    Expand-Archive -LiteralPath $jdkArchive -DestinationPath $temporaryRoot
    $extractedHome = Get-ChildItem -LiteralPath $temporaryRoot -Directory |
      Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'bin/java.exe') } |
      Select-Object -First 1
    if ($null -eq $extractedHome) {
      throw 'The Microsoft JDK archive did not contain bin/java.exe.'
    }
    Remove-ToolchainPath -Path $jdkHome
    Move-Item -LiteralPath $extractedHome.FullName -Destination $jdkHome
  } finally {
    Remove-ToolchainPath -Path $temporaryRoot
  }
}

function Install-AndroidCommandLineTools {
  $sourceProperties = Join-Path $androidCliRoot 'cmdline-tools/source.properties'
  $installedRevision = if (Test-Path -LiteralPath $sourceProperties) {
    (Select-String -LiteralPath $sourceProperties -Pattern '^Pkg.Revision=(.+)$').Matches.Groups[1].Value
  } else {
    ''
  }
  if ((Test-Path -LiteralPath $standaloneSdkManager) -and
      $installedRevision -eq $commandLineToolsRevision -and
      -not $ForceDownloads) {
    return
  }

  Get-VerifiedDownload `
    -Uri $commandLineToolsUri `
    -Destination $commandLineToolsArchive `
    -ExpectedSha256 $commandLineToolsSha256

  $temporaryRoot = Join-Path $toolchainRoot ".android-cli-install-$([guid]::NewGuid().ToString('N'))"
  Assert-WithinToolchainRoot -Path $temporaryRoot
  New-Item -ItemType Directory -Force -Path $temporaryRoot | Out-Null
  try {
    Expand-Archive -LiteralPath $commandLineToolsArchive -DestinationPath $temporaryRoot
    $extractedTools = Join-Path $temporaryRoot 'cmdline-tools'
    if (-not (Test-Path -LiteralPath (Join-Path $extractedTools 'bin/sdkmanager.bat'))) {
      throw 'The Android command-line tools archive is incomplete.'
    }
    Remove-ToolchainPath -Path $androidCliRoot
    New-Item -ItemType Directory -Force -Path $androidCliRoot | Out-Null
    Move-Item -LiteralPath $extractedTools -Destination (Join-Path $androidCliRoot 'cmdline-tools')
  } finally {
    Remove-ToolchainPath -Path $temporaryRoot
  }
}

function Install-SdkCommandLineToolsLayout {
  $sourceProperties = Join-Path $sdkCommandLineTools 'source.properties'
  $installedRevision = if (Test-Path -LiteralPath $sourceProperties) {
    (Select-String -LiteralPath $sourceProperties -Pattern '^Pkg.Revision=(.+)$').Matches.Groups[1].Value
  } else {
    ''
  }
  if ($installedRevision -eq $commandLineToolsRevision -and
      (Test-Path -LiteralPath $sdkManager) -and
      -not $ForceDownloads) {
    return
  }

  $standaloneTools = Join-Path $androidCliRoot 'cmdline-tools'
  if (-not (Test-Path -LiteralPath $standaloneSdkManager)) {
    throw 'The verified Android command-line tools installation is incomplete.'
  }

  Remove-ToolchainPath -Path $sdkCommandLineTools
  New-Item -ItemType Directory -Force -Path (Split-Path $sdkCommandLineTools) | Out-Null
  Copy-Item -LiteralPath $standaloneTools -Destination $sdkCommandLineTools -Recurse
}

New-Item -ItemType Directory -Force -Path @(
  $toolchainRoot,
  $downloadsRoot,
  $sdkRoot,
  $androidUserHome,
  $gradleUserHome
) | Out-Null

Install-Jdk17
Install-AndroidCommandLineTools
Install-SdkCommandLineToolsLayout

$javaExecutable = Join-Path $jdkHome 'bin/java.exe'
$adbExecutable = Join-Path $sdkRoot 'platform-tools/adb.exe'
$env:JAVA_HOME = $jdkHome
$env:ANDROID_HOME = $sdkRoot
$env:ANDROID_SDK_ROOT = $sdkRoot
$env:ANDROID_USER_HOME = $androidUserHome
$env:GRADLE_USER_HOME = $gradleUserHome
$env:Path = "$jdkHome\bin;$sdkRoot\platform-tools;$env:Path"

$packages = @(
  'platform-tools',
  'platforms;android-36',
  'build-tools;36.0.0',
  'ndk;28.2.13676358'
)
$accept = 1..100 | ForEach-Object { 'y' }
$accept | & $sdkManager "--sdk_root=$sdkRoot" --licenses | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Android SDK license acceptance failed.' }
$accept | & $sdkManager "--sdk_root=$sdkRoot" @packages | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Android SDK package installation failed.' }

$requiredPaths = @(
  $javaExecutable,
  $adbExecutable,
  $sdkManager,
  (Join-Path $sdkRoot 'platforms/android-36/android.jar'),
  (Join-Path $sdkRoot 'build-tools/36.0.0/aapt2.exe'),
  (Join-Path $sdkRoot 'ndk/28.2.13676358/source.properties')
)
foreach ($requiredPath in $requiredPaths) {
  if (-not (Test-Path -LiteralPath $requiredPath)) {
    throw "Required toolchain component is missing: $requiredPath"
  }
}

$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$javaVersion = (& $javaExecutable -version 2>&1 | Out-String)
$javaExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference
if ($javaExitCode -ne 0) {
  throw "JDK version check failed: $javaVersion"
}
if ($javaVersion -notmatch 'version "17\.') {
  throw "Expected JDK 17, got: $javaVersion"
}
$flutterInfo = (& flutter --version --machine | ConvertFrom-Json)
if ($flutterInfo.frameworkVersion -ne '3.44.7') {
  throw "Expected Flutter 3.44.7, got $($flutterInfo.frameworkVersion)."
}

$localPropertiesPath = Join-Path $repositoryRoot 'android/local.properties'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$escapedSdkRoot = $sdkRoot.Replace('\', '\\')
$localProperties = if (Test-Path -LiteralPath $localPropertiesPath) {
  [IO.File]::ReadAllText($localPropertiesPath)
} else {
  ''
}
if ($localProperties -match '(?m)^sdk\.dir=.*$') {
  $localProperties = [regex]::Replace(
    $localProperties,
    '(?m)^sdk\.dir=.*$',
    "sdk.dir=$escapedSdkRoot"
  )
} else {
  $localProperties = $localProperties.TrimEnd() + "`r`nsdk.dir=$escapedSdkRoot`r`n"
}
[IO.File]::WriteAllText($localPropertiesPath, $localProperties, $utf8NoBom)

Push-Location $repositoryRoot
try {
  & flutter doctor -v
  if ($LASTEXITCODE -ne 0) { throw 'flutter doctor reported an error.' }

  if (-not $SkipProfileBuild) {
    & flutter pub get
    if ($LASTEXITCODE -ne 0) { throw 'flutter pub get failed.' }
    & flutter build apk --profile --no-pub
    if ($LASTEXITCODE -ne 0) { throw 'Android Profile APK preflight failed.' }
  }
} finally {
  Pop-Location
}

Write-Host "JDK 17: $jdkHome"
Write-Host "Android SDK: $sdkRoot"
Write-Host 'Android toolchain setup completed.'
