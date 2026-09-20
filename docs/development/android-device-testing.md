# Android 真机 Debug 回归

需要保留手机上的正式版时，使用独立的 `com.meteor.kikoeruflutter.debug`
包。显示名称为 **KikoFlu Debug**，使用 debug 签名；账号、设置和应用私有
数据与正式版分开。当前隔离配置只针对 Debug，不能推断 Profile 也已隔离。

以下 PowerShell 命令在仓库根目录、同一终端内依次执行。工具链准备见
[Windows Android 开发](windows-android.md)。

## 1. 连接设备并记录正式版

手机开启 USB 调试，接受电脑的调试授权并保持解锁。自动测试期间不要手动
操作手机。从设备列表选择状态为 `device` 的目标，所有命令显式指定它。

```powershell
adb devices -l
$deviceId = '<adb devices 显示的设备序列号>'
$releasePackage = 'com.meteor.kikoeruflutter'
$debugPackage = 'com.meteor.kikoeruflutter.debug'
New-Item -ItemType Directory -Force build | Out-Null

adb -s $deviceId shell pm list packages com.meteor.kikoeruflutter
adb -s $deviceId shell dumpsys package $releasePackage |
  Select-String 'versionCode=|versionName=|firstInstallTime=|lastUpdateTime=' |
  Set-Content build/release-package-before.txt
```

记录设备型号、Android 版本、显示刷新率和测试构建的提交及未提交改动。
设备序列号、日志和原始报告保存在被忽略的 `build/` 中。

## 2. 构建并核验测试 APK

播放器配色回归使用真实播放器组件、路由、封面渲染和平台初始化，媒体状态
使用固定样本，无需正式版账号或音频素材；它不验证实际音频输出。

```powershell
fvm flutter pub get
fvm flutter build apk --debug --no-pub `
  --target=integration_test/player_palette_route_test.dart `
  --target-platform=android-arm64
if ($LASTEXITCODE -ne 0) { throw '测试 APK 构建失败' }

$apk = 'build/app/outputs/flutter-apk/app-debug.apk'
$androidSdk = if ($env:ANDROID_HOME) {
  $env:ANDROID_HOME
} else {
  Join-Path $env:LOCALAPPDATA 'Android/Sdk'
}
$aapt = Join-Path $androidSdk 'build-tools/36.0.0/aapt.exe'

function Assert-DebugApk([string]$path) {
  $badging = & $aapt dump badging $path
  if ($LASTEXITCODE -ne 0 -or
      -not ($badging -match "^package: name='com\.meteor\.kikoeruflutter\.debug'") -or
      -not ($badging -match '^application-debuggable')) {
    throw 'APK 包名或构建模式不符合独立 Debug 测试要求'
  }
  $badging | Select-String '^package:|^application-label:|^application-debuggable'
}
Assert-DebugApk $apk
```

示例目标为 ARM64 手机，其他架构需调整 `--target-platform`。每次重新构建后、
安装前都执行 APK 核验；文件名含 `debug` 本身不代表包名已隔离。
核验失败时修正 Debug 构建配置，不卸载正式版、不向正式版包名安装测试 APK。

## 3. 安装并运行自动回归

`flutter drive` 使用已经核验的 APK，避免再次构建出未经检查的安装包。
驱动会安装并启动独立 Debug 应用。

```powershell
$env:KIKOFLU_PERF_RUN_OUTPUT = Join-Path (Get-Location) `
  'build/player-palette-device-result.json'
fvm flutter drive --debug --no-pub -d $deviceId `
  --driver=test_driver/performance_driver.dart `
  --target=integration_test/player_palette_route_test.dart `
  --use-application-binary=$apk *> build/palette-device-test.log
if ($LASTEXITCODE -ne 0) {
  Get-Content build/palette-device-test.log -Tail 80
  throw '真机回归失败'
}
Get-Content $env:KIKOFLU_PERF_RUN_OUTPUT -Raw | ConvertFrom-Json
```

成功条件是本次命令退出码为 0、日志包含 `All tests passed`，且本次生成的
报告包含下列检查；旧报告不能作为本次通过的依据。

- 点击打开/关闭三轮。
- 上拖后停留并取消，播放器正常退出。
- 上拖完成后进入正式播放器路由。
- 部分展开停留超过 300ms，配色仍冻结。
- 完全展开但手势未结束时，配色仍冻结。
- 手势结束后更新到当前配色，关闭页面没有 Flutter 异常。

报告中的 `run.metrics` 和 `run.frameSamples` 是 Debug 帧耗时。它们包含 JIT、
断言和测试环境开销，只用于定位可疑阶段；功能回归通过不等于流畅度达标。
没有同设备、同模式和同场景的基线，不能据此宣称性能提升。正式性能验收见
[播放器性能验证](player-performance.md)，运行前另外确认包名与数据隔离。

## 4. 留下可手动使用的 Debug 版

自动测试 APK 的入口是测试脚本。需要继续手动体验时，重新构建正常入口，
再次核验，再替换独立 Debug 包。手动使用时在 Debug 版中单独配置账号。

```powershell
fvm flutter build apk --debug --no-pub --target=lib/main.dart `
  --target-platform=android-arm64
if ($LASTEXITCODE -ne 0) { throw '正常入口 Debug APK 构建失败' }
Assert-DebugApk $apk
adb -s $deviceId install -r $apk
if ($LASTEXITCODE -ne 0) { throw 'Debug APK 安装失败' }
adb -s $deviceId shell am start -n `
  "$debugPackage/com.meteor.kikoeruflutter.MainActivity"

adb -s $deviceId shell pm list packages com.meteor.kikoeruflutter
adb -s $deviceId shell dumpsys package $releasePackage |
  Select-String 'versionCode=|versionName=|firstInstallTime=|lastUpdateTime=' |
  Set-Content build/release-package-after.txt
Compare-Object (Get-Content build/release-package-before.txt) `
  (Get-Content build/release-package-after.txt)
```

两份包应同时存在；`Compare-Object` 无输出表示正式版的版本和安装时间记录
没有变化。交付时说明设备、构建模式、通过的场景、剩余问题和报告位置。

## 构建网络受限时

Gradle 仓库连接受阻时，先使用本机已配置的代理，或在依赖齐全时离线构建。
代理地址应来自当前机器配置，以本次 Gradle 命令的 `-Dhttps.proxyHost`、
`-Dhttps.proxyPort` 等参数传入。PowerShell 中包含点号的 Gradle 属性参数
使用引号，如 `'-Ptarget=integration_test/player_palette_route_test.dart'`。

Flutter 3.44.7 的集成测试插件包含动态版本依赖。若失败原因是 Maven 版本
列表请求，可将以下初始化脚本保存到 `build/palette-test-dependencies.gradle`，
仅为本次测试选择其约束内的明确版本：

```groovy
allprojects {
    configurations.configureEach {
        resolutionStrategy.eachDependency {
            if (requested.group == 'androidx.test' &&
                requested.name in ['runner', 'rules'] && requested.version == '1.2+') {
                useVersion '1.2.0'
            }
            if (requested.group == 'androidx.test.espresso' &&
                requested.name == 'espresso-core' && requested.version == '3.3+') {
                useVersion '3.3.0'
            }
        }
    }
}
```

依赖已下载后，可从仓库根目录执行：

```powershell
Push-Location android
try {
  .\gradlew.bat --offline --console=plain `
    --init-script ../build/palette-test-dependencies.gradle `
    '-Ptarget=integration_test/player_palette_route_test.dart' `
    '-Ptarget-platform=android-arm64' :app:assembleDebug
  if ($LASTEXITCODE -ne 0) { throw 'Gradle 构建失败' }
} finally {
  Pop-Location
}
$apk = 'build/app/outputs/apk/debug/app-debug.apk'
Assert-DebugApk $apk
```

此路径产出的 APK 位于 `outputs/apk/debug`，后续驱动和安装使用更新后的
`$apk`。构建正常入口时将 `-Ptarget` 改为 `lib/main.dart`。离线构建缺少依赖
时需要恢复下载；不以修改正式版配置或跳过 APK 核验解决构建问题。
