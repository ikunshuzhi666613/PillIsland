# PillIsland 药丸灵动岛

给 macOS 做的第三方「灵动岛」：屏幕顶部一颗小黑胶囊，放歌时变成播放器，悬停展开成详细卡片。

> 这是一个模仿 iOS / 新 MacBook Pro 灵动岛的第三方实现，不是苹果官方功能。
> 苹果的系统级灵动岛由 WindowServer 绘制、和摄像头开孔硬件绑定，无法提取或移植。

## 功能

- **待机**：48×26 纯黑小胶囊，不打扰
- **放歌**：左侧专辑封面 + 右侧六根**真实频谱**音律条（跟随当前播放器的声音跳动）
- **悬停**：展开 300×155 卡片——封面、歌名/歌手、可拖动进度条、切歌、播放/暂停
- **暂停**：封面变暗缩小，频谱收成平线
- **歌词**：歌名先显示 1.5 秒，随后在同一行滚动当前歌词（网易云歌词优先，LRCLIB 兜底）
- **点封面**：直接打开正在播放的网易云
- **切歌**：封面 Y 轴翻牌切换，模糊层与封面同步旋转
- **按键动效**：暂停键 Q 弹换图、切歌键三角形传送带推进、按下有灰色圆环
- **暂停 5 秒**自动收起回待机
- 菜单栏图标可显示/隐藏、退出

## 系统要求

- macOS 14 Sonoma 或更高
- Intel / Apple Silicon 均可

## 安装

1. 下载 `PillIsland-1.2.dmg`，把 `PillIsland.app` 拖进「应用程序」
2. 首次打开会被 Gatekeeper 拦下（未做苹果公证）：
   - 右键 PillIsland → 打开 → 再点「打开」
   - 或终端执行：
     ```bash
     xattr -dr com.apple.quarantine /Applications/PillIsland.app
     ```

## 权限

- **屏幕与系统音频录制**：频谱需要抓当前播放器的音频。
  系统不会自动弹窗，需要手动去
  `系统设置 → 隐私与安全性 → 屏幕与系统音频录制` 里点 `+` 添加 PillIsland 并打开。
  不授权也能用，只是音律条会退化成装饰动画。
- 授权后会常驻一个「正在共享」的系统提示，这是 macOS 的硬性提示，无法隐藏。

## 已知限制

- 没有 Apple 开发者证书，未公证，首次打开需手动放行
- 网易云音乐对小于 ~1.5 秒的进度跳转不响应（这是播放器的限制）
- 歌词依赖在线检索，冷门曲目可能找不到
- 切换桌面（Space）时窗口可能短暂消失，属于 WindowServer 合成行为
- 读取的是系统 Now Playing 数据，因此只支持能在控制中心「正在播放」出现的播放器

## 从源码构建

需要 Xcode Command Line Tools（含 swiftc）。

```bash
./build.sh     # 编译并安装到 /Applications/PillIsland.app
./package.sh   # 生成 dist/PillIsland-1.2.dmg 和 zip
```

- 图标由 `make_icon.swift` 生成（Core Graphics 渲染 1024 图，再用 `iconutil` 打包）
- `build.sh` 默认用名为 `PillIsland Dev` 的自签名证书签名；没有该证书时把
  `codesign` 的 `--sign` 参数改成 `-`（ad-hoc）即可

## 第三方

- [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter)（BSD 3-Clause）——
  用于在 macOS 15.4+ 读取系统 Now Playing 信息，已随包附带，许可证见
  `MediaRemoteAdapter/LICENSE`
