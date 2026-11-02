#!/bin/bash
# 打包可分发的 PillIsland（DMG + ZIP）
set -e
cd "$(dirname "$0")"

VERSION="1.3"
APPNAME="PillIsland"
OUT="dist"

rm -rf "$OUT"
mkdir -p "$OUT/stage"
ditto "/Applications/$APPNAME.app" "$OUT/stage/$APPNAME.app"
ln -s /Applications "$OUT/stage/Applications"

cat > "$OUT/stage/使用说明.txt" <<'EOF'
PillIsland 药丸灵动岛
====================

安装
----
1. 把 PillIsland.app 拖到左边的「Applications（应用程序）」文件夹。
2. 首次打开会被系统拦下（未做苹果公证）：
   在「应用程序」里右键 PillIsland → 打开 → 再点「打开」。
   如果还是不行，打开「终端」执行：
     xattr -dr com.apple.quarantine /Applications/PillIsland.app
   然后再双击打开。

运行要求
--------
- macOS 14 Sonoma 或更高
- Intel 和 Apple Silicon 都可以

怎么用
------
- 播放音乐时，屏幕顶部中央会出现一颗小黑胶囊，显示封面和音律条。
- 鼠标悬停胶囊 → 展开播放卡片：封面、歌名、进度条、切歌、播放/暂停。
- 进度条可以按住拖动跳转（部分播放器对小于 1.5 秒的跳转不响应）。
- 暂停超过 5 秒，药丸会自动收起变回待机。
- 菜单栏有一个胶囊图标，可以显示/隐藏药丸、退出。
- 媒体信息取自系统「正在播放」，支持 Apple Music、Spotify、网易云等。

隐私
----
纯本地运行，不联网、不上传任何数据。

已知限制
--------
- 没有用 Apple 开发者证书签名，首次打开需要手动放行（见上）。
- 开机自启没有内置开关，需要的话手动添加：
  系统设置 → 通用 → 登录项 → 添加 PillIsland。
EOF

hdiutil create -volname "$APPNAME" -srcfolder "$OUT/stage" -ov -format UDZO "$OUT/$APPNAME-$VERSION.dmg" >/dev/null
ditto -c -k --sequesterRsrc --keepParent "$OUT/stage/$APPNAME.app" "$OUT/$APPNAME-$VERSION.zip"

echo "✅ 打包完成："
ls -lh "$OUT/$APPNAME-$VERSION.dmg" "$OUT/$APPNAME-$VERSION.zip"
