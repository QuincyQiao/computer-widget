#!/bin/zsh
# 编译、自测、替换正在运行的那个并打开。只编译和自测：COMPUTER_STAGE_ONLY=1 ./重新构建.command
set -euo pipefail
project_dir="${0:A:h}"
build_dir="$project_dir/.build"
app_dir="$project_dir/ComputerWidget.app"
staging_root=$(/usr/bin/mktemp -d /private/tmp/computer-widget-build.XXXXXX)
trap 'rm -rf -- "$staging_root"' EXIT
staged_app="$staging_root/ComputerWidget.app"
mkdir -p "$build_dir/ComputerWidget.iconset" "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources"

print -r -- "正在编译电脑活动小组件……"
/usr/bin/xcrun swiftc -O -target arm64-apple-macosx15.0 \
    -framework AppKit -framework SwiftUI -framework IOKit -framework ServiceManagement \
    "$project_dir/ComputerWidget.swift" -o "$build_dir/ComputerWidget"
"$build_dir/ComputerWidget" --self-test
cp "$build_dir/ComputerWidget" "$staged_app/Contents/MacOS/ComputerWidget"
cp "$project_dir/Info.plist" "$staged_app/Contents/Info.plist"
"$build_dir/ComputerWidget" --make-icon "$build_dir/icon-1024.png"
for size in 16 32 128 256 512; do
    /usr/bin/sips -z "$size" "$size" "$build_dir/icon-1024.png" \
        --out "$build_dir/ComputerWidget.iconset/icon_${size}x${size}.png" >/dev/null
    doubled=$(( size * 2 ))
    /usr/bin/sips -z "$doubled" "$doubled" "$build_dir/icon-1024.png" \
        --out "$build_dir/ComputerWidget.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$build_dir/ComputerWidget.iconset" -o "$staged_app/Contents/Resources/ComputerWidget.icns"
/usr/bin/plutil -lint "$staged_app/Contents/Info.plist"
/usr/bin/codesign --force --sign - --timestamp=none "$staged_app"
/usr/bin/codesign --verify --strict "$staged_app"

# 自动同步只打包和自测；安装器另外处理运行状态、回退及本机设置。
if [[ -n "${SOFTWARE_SYNC_STAGE_ONLY:-}" ]]; then
    /usr/bin/ditto --norsrc --noextattr "$staged_app" "$build_dir/ComputerWidget.app"
    print -r -- "已打包：$build_dir/ComputerWidget.app"
    exit 0
fi
if [[ -n "${COMPUTER_STAGE_ONLY:-}" ]]; then
    print -r -- "编译和自测通过，没有替换正在运行的小组件"
    exit 0
fi

# 新版编好、验过签名，再让正在跑的那个退出（它会记下窗口位置）
"$build_dir/ComputerWidget" --quit-running
/usr/bin/ditto --norsrc --noextattr "$staged_app" "$app_dir"
/usr/bin/codesign --verify --strict "$app_dir"
/usr/bin/open "$app_dir"
print -r -- "已构建并打开：$app_dir"
