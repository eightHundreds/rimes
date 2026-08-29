# Capsule

Capsule 是 RIMES 的本机内容库。当前支持 `Prompt`、`Memory`、`Password` 与 `Skill` 四类 Markdown 条目；可以在 Buffer 中搜索，普通条目走标准上屏，密码走独立的并击授权通道。

## 本机数据

默认目录：

```text
~/Library/RimeBuffer/capsule/
├── content-seed-v1
├── entries/
│   └── <uuid>.md
├── master-key
└── passwords/
    └── <uuid>.md
```

- `entries/*.md` 是 Obsidian 可直接读取和编辑的普通 Markdown，front matter 保存 `capsule` 类型、版本、UUID、标题和更新时间，正文保存 Prompt/Memory 内容或 Skill 的绝对路径。
- 首次初始化会加入一条 Memory：标题 `RIMES 默认词条`，正文 `RIMES`。`content-seed-v1` 保证只预设一次；用户删除后不会自动复活。
- `passwords/*.md` 只暴露标题、UUID 和更新时间。网址、App、用户名、当前密码与曾用密码都位于 ChaCha20-Poly1305 密文块中。
- Capsule 根目录和子目录权限为 `0700`，主密钥、seed marker 与 Markdown 文档为 `0600`。整个目录位于用户资料目录，不进入仓库。
- 当前开发版以同一 macOS 用户为信任边界；同用户权限下的恶意进程不在防护范围内。

## Buffer 使用

1. 打开 Buffer，选择 `Capsule`，再从工具栏下拉框选择 `Prompt`、`Memory`、`Password` 或 `Skill`。
2. Capsule 只搜索当前选择的类型：Prompt、Memory、Skill 搜索标题与正文；Password 只搜索可见标题。最多显示五个结果。
3. 普通条目选中后，通过工作台纸飞机或 Return 走 `BufferDeliveryCoordinator -> Delivery.insert` 上屏。
4. 如果没有匹配结果，Prompt 或 Memory 会原地显示对应的新增动作；Skill 仅在输入本身是绝对路径时允许原地新增。点击后立即保存为本机 Markdown，并把新条目变成当前可上屏结果。Password 继续由 CLI 管理完整字段。

### Password

密码结果固定显示八位圆点，不泄露真实长度。选中结果本身不会捕获任何特殊按键；点击纸飞机或按 Return 后，RIMES 才显示非激活的“输入访问密钥”弹窗，并在最长 60 秒内接收四段本地并击验证。验证完成后，RIMES 重新确认精确 `FocusToken` 与 IMK client，签发两秒内有效的一次性许可，解密并插入当前密码。密钥契约不会出现在界面、提示、日志或文档中。

普通 Buffer 在 macOS Secure Input 下仍拒绝投递。密码例外必须同时满足“本机密文记录 + 显式上屏请求 + 弹窗仍有效 + 完整本地验证 + 当前精确目标 + 一次性许可”。弹窗出现前，包含 F/J 在内的普通打字不会被 Capsule 捕获。宿主若停用第三方输入法或不向 RIMES 发送并击，本版本会失败关闭，不回退到剪贴板或 Accessibility 注入。

## CLI 管理

CLI 在 AppKit/IMK 启动前运行。普通条目示例：

```bash
printf '%s' '{
  "type": "memory",
  "title": "项目事实",
  "content": "Capsule 条目使用 Markdown 管理。"
}' | RimeBuffer capsule entry put

RimeBuffer capsule entry list
RimeBuffer capsule entry path
RimeBuffer capsule entry seed
RimeBuffer capsule entry remove <uuid>
```

`entry list` 只输出 UUID、类型、标题和更新时间，不输出正文。`Skill` 的 `content` 必须是文件或文件夹的绝对路径。

密码从标准输入读取 JSON，避免出现在进程参数中；CLI 没有输出明文密码的命令：

```bash
printf '%s' '{
  "title": "示例站点",
  "url": "https://example.invalid/login",
  "app": "Browser",
  "username": "example-user",
  "password": "replace-with-local-secret",
  "previousPasswords": []
}' | RimeBuffer capsule password put

RimeBuffer capsule password list
RimeBuffer capsule password path
RimeBuffer capsule password remove <uuid>
```

更新条目时，在对应 `put` JSON 中加入已有 `id`。

## 验证

```bash
.build/debug/RimeBuffer capsule-smoke
```

Smoke 使用临时目录和测试凭据，覆盖默认词条的一次性预设、普通 Markdown 往返、四类下拉隔离、按当前类型原地添加、标准上屏租约、目录/文件权限、密码明文边界、加解密、标题篡改拒绝、固定脱敏、四段并击形状，以及弹窗开启前绝不接管普通按键。
