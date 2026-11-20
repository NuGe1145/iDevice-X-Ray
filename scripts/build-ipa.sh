#!/bin/bash
# 打包未签名 ipa。
#
#   ./scripts/build-ipa.sh
#
# 产出的 ipa 不含签名、不含描述文件、不含任何人的 Team ID，谁装谁用自己的
# Apple ID 签（Sideloadly / AltStore / SideStore / Xcode 都行）。这是没有
# Mac 也能安装的唯一方式，也是 CI 发布的形态。
#
# 版本号来自 git：v* 标签是 MARKETING_VERSION，提交数是 build number。
# 想覆盖就导出 MARKETING_VERSION / CURRENT_PROJECT_VERSION。
set -euo pipefail
cd "$(dirname "$0")/.."

SCHEME="iDeviceXRay"
PROJECT="iDeviceXRay.xcodeproj"
BUILD="build"
DERIVED="$BUILD/DerivedData"
EXPORT="$BUILD/export"

if [ -z "${MARKETING_VERSION:-}" ]; then
  # 只有 HEAD 正好打了标签才用标签版本；主干上的临时构建按 project.yml，
  # 否则手动构建出来的包会一直挂着上一个正式版的版本号。
  tag=$(git tag --points-at HEAD --list 'v*' 2>/dev/null | sort -V | tail -1 || true)
  if [ -n "$tag" ]; then
    MARKETING_VERSION="${tag#v}"
  else
    MARKETING_VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([0-9][0-9.]*\)"\{0,1\}.*/\1/p' project.yml | head -1)
  fi
fi
if [ -z "${CURRENT_PROJECT_VERSION:-}" ]; then
  CURRENT_PROJECT_VERSION=$(git rev-list --count HEAD 2>/dev/null || echo 1)
fi

# 工程由 XcodeGen 生成，这里确保 pbxproj 与 project.yml 一致
command -v xcodegen >/dev/null 2>&1 && xcodegen generate --quiet

overrides=()
[ -z "${MARKETING_VERSION:-}" ] || overrides+=("MARKETING_VERSION=$MARKETING_VERSION")
[ -z "${CURRENT_PROJECT_VERSION:-}" ] || overrides+=("CURRENT_PROJECT_VERSION=$CURRENT_PROJECT_VERSION")
echo "==> Version ${MARKETING_VERSION:-(project.yml)} build ${CURRENT_PROJECT_VERSION}"

rm -rf "$DERIVED" "$EXPORT"
mkdir -p "$BUILD"

# Swift 会把源码绝对路径写进二进制（调试信息与 #file），remap 掉，否则装的人
# 能看到构建机的家目录。DerivedData 在这个目录下，所以一处覆盖两处。
echo "==> Building (Release, unsigned)"
xcodebuild build \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGN_ENTITLEMENTS="" \
  DEVELOPMENT_TEAM="" \
  "OTHER_SWIFT_FLAGS=-file-prefix-map $PWD=/iDeviceXRay" \
  "OTHER_CFLAGS=-ffile-prefix-map=$PWD=/iDeviceXRay" \
  ${overrides[@]+"${overrides[@]}"} \
  | tail -5

APP="$DERIVED/Build/Products/Release-iphoneos/$SCHEME.app"
[ -d "$APP" ] || { echo "没有找到 $APP" >&2; exit 1; }

echo "==> Packaging"
rm -rf "$BUILD/Payload"
mkdir -p "$BUILD/Payload" "$EXPORT"
cp -R "$APP" "$BUILD/Payload/"
rm -rf "$BUILD/Payload/$SCHEME.app/_CodeSignature"
# 链接器会把每个目标文件的绝对路径记进符号表（N_OSO），remap 管不到，strip 掉。
# dSYM 留在 DerivedData 里，崩溃符号化用它。
xcrun strip -S -x "$BUILD/Payload/$SCHEME.app/$SCHEME" || true
(cd "$BUILD" && zip -qry "export/$SCHEME-unsigned.ipa" Payload)
rm -rf "$BUILD/Payload"

IPA="$EXPORT/$SCHEME-unsigned.ipa"
leaks=$(grep -ac "/Users/" "$DERIVED/Build/Products/Release-iphoneos/$SCHEME.app/$SCHEME" || true)
[ "${leaks:-0}" = "0" ] || echo "警告：二进制里仍有 $leaks 处 /Users/ 路径"

echo
echo "Done:"
ls -lh "$IPA"
