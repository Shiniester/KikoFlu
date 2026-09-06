# Windows Android development

KikoFlu pins Flutter 3.44.7 and Dart 3.12.2. Use FVM for the Flutter SDK and
the standard per-user Android SDK for everyday development. The toolchain under
`build/toolchains` is reserved for repeatable performance runs and is not the
normal Android Studio SDK.

## Required versions

| Component | Version |
| --- | --- |
| Flutter | 3.44.7 |
| Dart | 3.12.2, bundled with Flutter |
| Java | Microsoft OpenJDK 17 |
| Android platforms | 33 through 36; target SDK 36 |
| Android Build Tools | 35.0.0 and 36.0.0 |
| Android NDK | 28.2.13676358 |
| CMake | 3.22.1 |

Android Studio itself should track the latest stable release. The Android
Gradle Plugin and Kotlin versions remain pinned by the repository; installing
or updating Android Studio must not rewrite them.

## One-time setup

1. Install the Windows x64 standalone build of
   [FVM](https://fvm.app/documentation/getting-started/installation), add it to
   the user `Path`, and use a user-local cache directory.
2. Install and select the repository SDK:

   ```powershell
   fvm install 3.44.7
   fvm global 3.44.7
   fvm use 3.44.7
   ```

3. Install the latest stable
   [Android Studio](https://developer.android.com/studio/install) and use
   `%LOCALAPPDATA%\Android\Sdk` as the Android SDK directory.
4. In Android Studio's SDK Manager, install:

   - Android SDK Platform 33, 34, 35, and 36
   - Android SDK Build-Tools 35.0.0 and 36.0.0
   - Android SDK Platform-Tools
   - Android SDK Command-line Tools (latest)
   - Android Emulator
   - NDK (Side by side) 28.2.13676358
   - CMake 3.22.1
   - Google APIs Intel x86_64 Atom System Image for API 36

5. Set these user environment variables. `JAVA_HOME` must identify the JDK
   root, not its `bin` directory.

   ```text
   JAVA_HOME=C:\Program Files\Microsoft\jdk-17.0.20.101-hotspot
   ANDROID_HOME=%LOCALAPPDATA%\Android\Sdk
   ANDROID_SDK_ROOT=%LOCALAPPDATA%\Android\Sdk
   ```

   Add the FVM executable directory, the FVM global Flutter SDK `bin`,
   `%JAVA_HOME%\bin`, and `%ANDROID_HOME%\platform-tools` to the user `Path`.
   Open a new terminal after changing the environment.

6. Point Flutter at the selected JDK and Android SDK, then accept the licenses:

   ```powershell
   flutter config --jdk-dir "$env:JAVA_HOME"
   flutter config --android-sdk "$env:ANDROID_HOME"
   flutter doctor --android-licenses
   ```

7. Run `emulator -accel-check`. If hardware acceleration is unavailable,
   enable Windows Hypervisor Platform and Virtual Machine Platform, reboot, and
   run the check again.

## Emulator and physical device

Create a Pixel-series virtual device named `KikoFlu_API_36` using the API 36
Google APIs x86_64 image. Confirm that it appears after starting it:

```powershell
emulator -list-avds
emulator -avd KikoFlu_API_36
flutter devices
```

For a physical device running Android 11 or newer, enable Developer options,
USB debugging, and Wireless debugging. Pair and connect using the address and
codes shown by the device:

```powershell
adb pair <host>:<pairing-port>
adb connect <host>:<debug-port>
adb devices
flutter devices
```

Wireless debugging avoids vendor-specific Windows USB drivers. Pairing details
are device-local and must not be committed.

## Verify the project

From the repository root, open a new terminal and run:

```powershell
fvm --version
flutter --version
dart --version
java -version
adb version
flutter doctor -v
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
flutter run -d emulator-5554
```

Use the actual device ID reported by `flutter devices` if it differs from
`emulator-5554`.

`flutter --version` must report 3.44.7 and `java -version` must report Java 17.
`flutter doctor -v` must recognize the Android toolchain and accepted SDK
licenses. Flutter 3.44.7 no longer prints a separate Android Studio validator;
use `flutter config --list` to confirm that `android-studio-dir` points to the
installation when automatic discovery is insufficient. Existing notices about
future Flutter support for the repository's pinned Android Gradle Plugin or
Kotlin versions are project upgrade work, not a reason to let Android Studio
rewrite the build files.

## Performance toolchain

`tool/performance/setup_android_toolchain.ps1` installs a separate, pinned SDK
under the ignored `build/toolchains` directory for performance comparisons.
Use it only with the performance workflow described in
`tool/performance/README.md`. Deleting `build` may delete that isolated copy but
must not affect the standard Android Studio SDK configured above.
