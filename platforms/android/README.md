# RIMES Android

RIMES 的原生 Android 输入法（`InputMethodService`）。它与 macOS 版共用同一份
librime 桥接（`Sources/CRimeBridge/CRimeBridge.cpp`）、同一套按键 keysym 契约、
同一份经审核的 `rime-data` 依赖闭包，并把 Buffer 工作台、方案选单、并击扩展、
用户词库维护和主题等产品层逐一移植到 Android 上。

> 这是原生实现，不是 Windows / Linux 目录里的“数据预览包”。所有按键处理、组字、
> 候选、上屏与设置都在本应用内完成，不依赖系统上已安装的其他 Rime 前端。

## 目录

```
platforms/android/
├── app/src/main/cpp/          CMake：静态 librime + 共享 CRimeBridge + JNI 适配层
├── app/src/main/java/.../     Kotlin：rime/ input/ buffer/ ui/ service/ settings/
├── app/src/test/              JVM 单元测试（按键映射、缓冲、并击、方案存储、路由契约）
├── app/src/androidTest/       模拟器/真机测试（真实 librime 部署与组字、端到端键入）
├── app/src/debug/             仅 debug 变体的 E2E 广播钩子
└── scripts/
    ├── fetch-prebuilt.sh      拉取固定 commit 的 fcitx5-android/prebuilt 静态库
    ├── build-opencc-data.sh   在宿主机构建 OpenCC 标准配置与词典（.ocd2）
    └── e2e-emulator.sh        模拟器端到端：启用输入法、注入按键、读回上屏文本
```

## 架构对齐

| 层 | macOS | Android |
|---|---|---|
| librime 桥 | `CRimeBridge.cpp` dlopen `librime.1.dylib` | 同一文件，`__ANDROID__` 分支直接静态链接 `rime_get_api`；RimeApi vtable 与全部 `BBRime*` 入口不变 |
| librime 运行时 | Squirrel 打包的 librime + lua/octagram/predict | fcitx5-android/prebuilt 固定 commit 的 librime 1.16.1 静态库（已合并 lua/octagram/predict），`--whole-archive` 保留模块注册 |
| 数据 | Squirrel SharedSupport + 仓库 `rime-data` | `scripts/platform-preview/preview.py stage` 的 55 文件闭包 + 宿主机构建的 OpenCC 标准数据，首启按内容指纹种入 `files/rime/shared` |
| 用户目录隔离 | `~/Library/RimeBuffer` | `files/rime/user`（编译产物、userdb、`default.custom.yaml`），升级只替换 shared |
| 会话 | 每个 `IMKInputController` 一个 session | 每个绑定的文本框一个 session（`InputController.bind/unbind`） |
| 组字 | marked text（`CompositionSession`） | `setComposingText`；缓冲捕获时 preedit 投影到工作台轨，不进宿主 |
| 上屏 | `Delivery.insert` 唯一路径 | `Delivery.insert` 唯一路径；密码框拒绝缓冲/转换文本 |
| 按键 | X11 keysym + 修饰掩码 | 同一常量表；硬件键与软键盘共用 `InputController.handleKey` |
| 并击 | `ChordController` 只对 `my_combo` 释放回放 | 同一批处理/结算/互击配对状态机移植；软键盘多点触控与硬件键都可并击 |
| 方案 | `InputSchemaCatalog` + `default.custom.yaml` schema_list | 同一目录、同一 `patch.schema_list` 重写器；并击扩展开关决定 `my_combo` 是否进选单 |
| Buffer | `BufferModel` + `BufferDeliveryCoordinator` | 同一模型：块、插入点、回车轻按/长按、纸飞机、精确焦点令牌校验、最后一块后回到直输 |
| 用户词库 | levers 导出/导入/快照 | 同一 `BBRime*UserDictionary` 入口，经 SAF 选择文件 |
| 主题 | 墨竹 / 翡翠 / 静谧 / 拉斯塔 | 同一调色板数值 |

## 构建

需要 JDK 17+、Android SDK（platform 35、build-tools 35、NDK 27.2、CMake 3.22）、
python3、以及宿主机 C++17 编译器 + CMake（仅用于生成 OpenCC 数据）。

```bash
cd platforms/android
./scripts/fetch-prebuilt.sh          # 固定 commit 的静态 librime 及依赖 -> third_party/prebuilt
./scripts/build-opencc-data.sh       # OpenCC 标准 json/.ocd2 -> third_party/opencc-data
./gradlew :app:assembleDebug         # arm64-v8a + x86_64
./gradlew :app:assembleDebug -PrimesAbis=x86_64   # 仅模拟器
```

`third_party/` 被 gitignore：二进制不进仓库，只按 commit 固定来源，与 macOS 的
`Vendor/` 约定一致。

## 测试

```bash
./gradlew :app:testDebugUnitTest                 # JVM 单元测试
./gradlew :app:connectedDebugAndroidTest -PrimesAbis=x86_64   # 需要已启动的模拟器
./scripts/e2e-emulator.sh                        # 端到端：真实启用输入法并键入
```

首次在设备上启动会编译全部词典（雾凇词库较大），仪器测试与 E2E 脚本都为此预留了
足够超时；后续启动直接复用 `files/rime/user/build`。

## 未对齐项

以下 macOS 能力在本阶段没有移植，原因见 PR 说明：AI 生成（Codex/Claude CLI、
OpenAI 兼容连接器）、Apple 本地翻译、意识流输入的 AI 回退、Clipboard History、
Mailbox（本地网关/MCP）、Capsule 与 iCloud 同步、Sparkle 式自动更新、Octagram
语言模型文件（插件已链接，模型未打包）。
