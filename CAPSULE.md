# Capsule

Capsule 是与 Buffer、Mailbox 同级的 RIMES 本机内容库。当前支持 `Prompt`、`Memory`、`Password` 与 `Skill` 四类条目，并在独立 Capsule 窗口中提供搜索和增删改查。Capsule 不属于 Buffer 插件目录，也不受 Buffer 插件启停或工作台生命周期控制。

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

## 独立窗口

- `⌘⇧C` 全局打开或关闭 Capsule；也可以从输入法菜单或「设置 → Capsule」进入。
- 窗口按 `Prompt`、`Memory`、`Password`、`Skill` 分类搜索，并提供新增、查看、修改和删除。它是可输入的普通 AppKit 管理窗口，不是 Buffer，也不是上屏目标。
- Prompt 与 Memory 编辑 Markdown 正文；Skill 保存本机文件或文件夹的绝对路径；Password 编辑网址、App、用户名、当前密码与曾用密码。
- Password 列表只显示标题与固定长度掩码；网址、App、用户名始终使用安全文本控件。当前密码与曾用密码可通过「查看明文」短时查看，15 秒后自动恢复掩码；窗口失焦、应用失活、锁屏/睡眠/会话退出，以及切换条目或类型、新建、保存、删除、重载和关闭都会立即隐藏。明文视图不可选择、不可复制，也不会写入日志、tooltip、辅助功能标签或 UserDefaults。
- 未保存草稿在切换条目、类型、页面或关闭窗口前会要求确认；保存与删除携带已加载文件的 SHA-256 revision，并在 Store 文件锁内比较，另一窗口或 CLI 已更新时拒绝覆盖。直接在 Obsidian 修改普通 Markdown 后，旧窗口也必须重新载入才能保存。
- 当前独立管理窗口只负责内容管理，不直接向外部输入框上屏。原先依附 Buffer workspace 的 Capsule 搜索、保护投递和并击拦截已经移除，因此 Capsule 不参与普通输入按键路径。后续若增加独立上屏，应采用 Capsule 自己的非激活快速面板和外部焦点授权协议，不能重新依附 Buffer，也不能退化为剪贴板或 Accessibility 注入。

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
.build/debug/RimeBuffer capsule-window-smoke
```

Smoke 使用临时目录和测试凭据，覆盖默认词条的一次性预设、普通 Markdown 往返、四类筛选、独立窗口 CRUD 与并发 revision 规则、目录/文件权限、密码明文边界、加解密、标题篡改拒绝和固定脱敏。测试不会读写用户真实 Capsule 目录。
