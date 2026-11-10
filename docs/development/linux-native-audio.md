# Linux 原生播放库构建

Linux 应用使用项目自建的 mpv、FFmpeg 和 libplacebo。
版本来自 `scripts/native_audio/common.lock`。
应用构建不再使用发行版提供的 libmpv。

## 准备环境

在 Ubuntu 22.04 的 x64 或 ARM64 环境中，安装 Flutter 和编译依赖：

```bash
sudo apt-get update
sudo apt-get install -y build-essential git clang cmake ninja-build pkg-config \
  python3-pip nasm libssl-dev libass-dev libepoxy-dev libpulse-dev libasound2-dev \
  libegl1-mesa-dev libgles2-mesa-dev libxrandr-dev libxinerama-dev libxss-dev \
  libxpresent-dev libxv-dev libwayland-dev wayland-protocols \
  libgtk-3-dev libsecret-1-dev libwebkit2gtk-4.1-dev libsoup-3.0-dev \
  libsqlite3-dev pax-utils patchelf binutils xvfb
python3 -m pip install --user --requirement scripts/native_audio/requirements.txt
export PATH="$HOME/.local/bin:$PATH"
```

## 构建应用

在仓库根目录，依次运行：

```bash
bash scripts/native_audio/build_linux.sh
flutter pub get
flutter build linux --release
```

原生库安装到 `build/native-audio/linux-output/`。
CMake 从该目录读取头文件和库，再将运行时依赖复制到应用包。
源码版本记录在该目录的 `source-provenance.txt`。

脚本拒绝覆盖已有工作目录和输出目录。
重新构建前，清理上次生成的 `build/native-audio-linux/` 和 `build/native-audio/linux-output/`。
CI 的工作目录位于 `$RUNNER_TEMP/native-audio-linux/`。
`flutter clean` 会删除原生库输出；清理后须重新构建原生库。

## 验证

运行 **Build test** 工作流，检查发布包中的音效输出与依赖。
该工作流分别覆盖 Linux x64 和 ARM64。
输出检查使用包内的 libmpv，不能用系统库或独立探针结果替代。
