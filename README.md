# 悬浮提词器 iOS App（源码 + 安装说明）

这是一个**真正的 iOS 原生 App**（Swift + SwiftUI），装到 iPhone 上以后有独立图标，点开就用。
直播时点「悬浮到抖音上方」，提词小窗会通过苹果官方的**画中画**通道浮在抖音直播画面之上，两个 App 互不影响。

---

## 一、App 功能对照你的需求

| 你的需求 | 实现情况 |
|---|---|
| 字体大小、行间距、颜色可调 | ✅ 设置页「字体」：14–72px、1.0–3.0 行距、6 个预设色 + 自定义取色 |
| 背景框颜色、透明度、随意拖动摆放 | ✅ 「字幕背景框」：颜色 6 色 + 自定义、透明度 0–100%、宽高可调；提词页直接用手指拖字幕框 |
| 2 种滚动方式：匀速（带进度条/倍速）+ AI 语速跟读 | ✅ 匀速 0.2–5 倍速 + 可拖动进度条；AI 跟读用**实时语音识别 + 滑动窗口文本匹配**：你说到稿子第几个字，字幕就滚到那个位置，语速快慢/停顿都跟得住，不念就不动 |
| 每篇最多 20000 字，可编辑、删除 | ✅ 首页可新建多篇稿件，实时字数统计，超 20000 字自动截断，支持编辑/左滑删除 |

额外：稿件和样式都存在手机本地，不上传任何服务器；字幕框位置、样式下次打开还在。

---

## 二、为什么需要"打包"这一步

iPhone 只能安装**经过苹果签名**的 App。你这台 Mac（2016 款 / macOS 12）装不了新版 Xcode，
所以我们在 GitHub 的免费 macOS 服务器上编译（不花钱），编译出来的 `.ipa` 再用
**Sideloadly**（免费工具）配合你的 Apple ID 签名装进手机。

> 免费 Apple ID 签名的 App **7 天后过期**，过期后图标点不开，重连电脑用 Sideloadly 再点一次 Start 即可（数据保留）。
> 想一劳永逸就买苹果开发者账号（688 元/年），装一次可用一年。

---

## 三、打包步骤（约 20 分钟，只需做一次）

### 第 1 步：注册 / 登录 GitHub
1. 电脑浏览器打开 https://github.com ，点右上角 **Sign up**（已有账号就直接 **Sign in**）
2. 用邮箱注册，验证邮箱即可，全程免费

### 第 2 步：新建仓库
1. 登录后点右上角 **＋** → **New repository**
2. **Repository name** 填：`teleprompter`
3. 选 **Private**（私有，别人看不到）
4. 点 **Create repository**

### 第 3 步：上传本项目文件
1. 在新仓库页面点 **uploading an existing file**（或 **Add file → Upload files**）
2. 打开本文件夹 `ios-app`，把里面的 **全部内容**（`.github`、`Sources`、`project.yml`、`tools`、`README.md`）拖进浏览器上传框
3. 下面点 **Commit changes**

> ⚠️ 注意：`.github` 是隐藏文件夹（Mac 上按 `Command + Shift + .` 可以显示隐藏文件）。
> 如果上传后仓库里看不到 `.github`，用下面的"备用方法"手动补上。

**备用方法（补 .github/workflows/build-ipa.yml）**
仓库页面 → **Add file → Create new file** → 文件名输入
`.github/workflows/build-ipa.yml` → 把本文件夹里同名文件的内容整段粘贴进去 → **Commit changes**。

### 第 4 步：让 GitHub 自动编译
1. 仓库顶部点 **Actions** 标签（第一次会提示启用，点 **I understand my workflows, go ahead and enable them**）
2. 左侧点 **Build IPA** → 右侧 **Run workflow** → 绿色按钮 **Run workflow**
3. 等 5–8 分钟，页面上出现绿色的 ✓ 就说明编译成功
4. 点进这次运行 → 页面底部 **Artifacts** → 下载 **Teleprompter-ipa**（一个 zip）→ 解压得到 **Teleprompter.ipa**

### 第 5 步：把 .ipa 装进 iPhone
1. Mac 上打开 https://sideloadly.io 下载 **macOS 版 Sideloadly** 并安装（免费）
2. 用数据线把 iPhone 连到 Mac，iPhone 上点「信任此电脑」
3. 打开 Sideloadly：
   - **iOS IPA File** 那一行，把解压出来的 `Teleprompter.ipa` 拖进去
   - **Apple ID** 填你的 Apple ID（用来签名，只发给苹果服务器验证，不经过第三方）
   - 点 **Start**，弹出输入 Apple ID 密码 → 再输一次**双重认证验证码**（手机上会弹）
4. 等进度条走完，iPhone 桌面就会出现「悬浮提词器」图标

### 第 6 步：信任这个 App（只需一次）
iPhone 打开「设置 → 通用 → VPN与设备管理 → 开发者 App」→ 点你的 Apple ID → **信任**

### 第 7 步：打开「设置 → 通用 → 画中画」→ 打开「自动开启画中画」

---

## 四、直播怎么用

1. 打开 App → 新建/选择口播稿 → 点「提词」
2. 点「样式」调字号、颜色、背景透明度；回到提词页用手指拖动字幕框到合适位置
3. 选「匀速滚动」调好倍速（或选「AI跟读」）
4. 点 **悬浮到抖音上方** → 出现小窗 → 按 Home 键 → 打开抖音开播 → 小窗浮在画面上，可拖动、双指缩放
5. 播完回到 App 点「关闭悬浮」

> 📌 悬浮时怎么保住 AI 跟读：App 的音频会话用
> `.playAndRecord + .mixWithOthers + .defaultToSpeaker + .allowBluetoothA2DP`
> 并设置 `microphoneMode = .standard`，让系统允许本 App 与其他 App 同时工作；
> 同时开启 Background Modes 的 audio（后台音频），这样切到抖音后识别不会断。
> 如果识别被系统打断（比如来电），会自动重连；实在跟不上就点「重新对齐」。

---

## 五、技术说明（给开发者看）

- 工程用 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 描述（`project.yml`），CI 里 `xcodegen generate` 生成 `.xcodeproj`
- 悬浮实现：`AVPictureInPictureController` + `AVSampleBufferDisplayLayer`
  （`Sources/PiPRenderer.swift`），每帧把字幕画成 `CVPixelBuffer` 送进 layer，
  实现"自定义内容 + 画中画悬浮"，不依赖摄像头
- AI 跟读：`SFSpeechRecognizer`（zh-CN，优先本地识别）实时拿 partial result →
  去掉标点空格归一化 → 在稿子里做**滑动窗口匹配**（向前容忍 4 字以上才算命中，只前进不后退）
  → 用 `NSLayoutManager` 把「命中的第 N 个字」换算成屏幕纵坐标 → 滚动引擎平滑追过去
  （`Sources/SpeechFollower.swift`、`Sources/ScriptMap.swift`、`Sources/PrompterEngine.swift`）
- 麦克风共存：`AudioSessionManager` 统一配置 `.playAndRecord + .mixWithOthers`、
  `microphoneMode = .standard`，并监听路由变化/中断自动恢复（`Sources/SpeechFollower.swift`）
- 后台保活：`UIBackgroundModes: audio` + 循环静音音轨（`SilentAudio`）
- 数据：`Documents/scripts.json`、`Documents/style.json`
- 最低系统：iOS 16.0

目录结构：

```
ios-app/
├── project.yml                    # 工程描述
├── Sources/
│   ├── TeleprompterApp.swift      # 入口
│   ├── Models.swift               # 数据模型 / 本地存储
│   ├── Views.swift                # 首页列表 + 稿件编辑器
│   ├── PrompterView.swift         # 提词页 + 样式设置面板
│   ├── TextLayout.swift           # 排版计算
│   ├── PrompterEngine.swift       # 滚动引擎（匀速 + 追向识别位置）
│   ├── SpeechFollower.swift       # AI 跟读（语音识别 + 滑动窗口匹配 + 音频会话）
│   ├── ScriptMap.swift            # 第 N 个字 → 屏幕纵坐标
│   ├── PiPRenderer.swift          # 画中画悬浮渲染
│   ├── Info.plist（由 project.yml 生成）
│   └── Assets.xcassets            # App 图标
├── tools/make-icon.swift          # 图标生成脚本（可选）
└── .github/workflows/build-ipa.yml# 云端编译流水线
```

---

## 六、参考的开源项目（都是公开代码，可对照验证方案可行性）

| 项目 | 有什么可参考的 |
|---|---|
| `ThisIsNSH/CueCard`（GPLv3，App Store 免费上架，15K+ 下载） | iPhone 上"浮在其他 App 上方"的提词器，证明公开 API 的 PiP 就能做到全屏悬浮 + 拖动窗口 |
| `gemicn/CustomPictureInPicture` | 基于 iOS 14 `AVPictureInPictureController` 的**完全自定义画中画**，README 里直接点名"悬浮提词器"场景，并给出隐藏系统播放/快进按钮的思路 |
| `0x00000003/AIPromptCam` | iOS "AI 语音跟读提词器"：`SFSpeechRecognizer` + 滑动窗口字符匹配 + 逐行平滑滚动 + 前瞻补偿，本文档的跟读算法即按此思路实现 |

> 本项目没有直接拷贝上述项目代码，只参考其技术路线；如果后续要上架 App Store，
> 注意 `CustomPictureInPicture` 中隐藏系统按钮的部分用的是私有 API，上架会被拒，
> 自签侧载使用没问题。
