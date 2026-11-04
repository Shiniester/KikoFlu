#!/bin/bash

# iOS 无签名 IPA 简化构建脚本（使用 Xcode Archive 方式）
# 适用于 Xcode 26.1 等较新版本

set -e

echo "🚀 开始构建 iOS 无签名 IPA（简化版）..."

# 检查依赖
echo "🔍 检查依赖环境..."
if ! command -v flutter &> /dev/null; then
    echo "❌ Flutter 未安装"
    exit 1
fi

if ! command -v pod &> /dev/null; then
    echo "❌ CocoaPods 未安装"
    exit 1
fi

echo "✅ 依赖检查通过"
echo ""

# 清理
echo "🧹 清理之前的构建..."
flutter clean
rm -rf ios/Pods ios/Podfile.lock

# 获取依赖
echo "📦 获取 Flutter 依赖..."
flutter pub get

# 安装 iOS 依赖
echo "📦 安装 iOS 依赖（首次可能需要较长时间）..."
cd ios
pod install
cd ..

# 使用 xcodebuild 构建（不需要模拟器）
echo "🔨 构建 iOS Release 版本（无签名）..."
cd ios

xcodebuild \
    -workspace Runner.xcworkspace \
    -scheme Runner \
    -sdk iphoneos \
    -configuration Release \
    -archivePath build/Runner.xcarchive \
    -arch arm64 \
    archive \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGN_ENTITLEMENTS="" \
    PROVISIONING_PROFILE="" \
    ONLY_ACTIVE_ARCH=NO

cd ..

# 检查 archive 是否成功
if [ ! -d "ios/build/Runner.xcarchive" ]; then
    echo "❌ Archive 失败"
    exit 1
fi

echo "✅ Archive 成功！"
echo ""

# 手动打包 IPA（跳过 xcodebuild export，避免签名问题）
echo "� 打包无签名 IPA..."

# 清理之前的打包文件
rm -rf build/Payload
rm -f Iroru-unsigned.ipa

# 创建 Payload 目录并复制 .app
mkdir -p build/Payload
cp -r ios/build/Runner.xcarchive/Products/Applications/Runner.app build/Payload/

# 打包成 IPA
cd build
zip -qr Iroru-unsigned.ipa Payload
cd ..

# 移动到项目根目录
mv build/Iroru-unsigned.ipa ./

# 验证文件
if [ -f "Iroru-unsigned.ipa" ]; then
    echo "✅ 构建完成！"
    echo ""
    echo "📱 无签名 IPA 文件信息："
    ls -lh Iroru-unsigned.ipa
    echo ""
    echo "📍 文件位置:"
    echo "$(pwd)/Iroru-unsigned.ipa"
else
    echo "❌ 打包失败"
    exit 1
fi

echo ""
echo "📝 用户可以使用以下工具自签名："
echo "   - AltStore (https://altstore.io/)"
echo "   - Sideloadly (https://sideloadly.io/)"
echo "   - iOS App Signer"
