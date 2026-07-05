# Claude Remote — iOS roadmap / 待办梳理

Baseline 已完成：Discord 风渲染（消息/工具 embed/diff/markdown/thinking）、本机实时数据、真字体、明暗主题、Lock/New Session、性能优化（懒加载/增量 tail/markdown 缓存/滚动锚底）、中继接通（读+驱动）、QR 配对、真机安装。

下面是**尚未做完**的，按优先级分层。

## P0 — 下一步高性价比（建议先做）

- **乐观本地回显**：手机发消息后立即在本地显示 user 气泡 + "Claude 正在处理…"，不等流回。现在要等 agent 跑完才出现，体感慢。
- **交互式权限 Allow/Deny**（产品核心）：agent 把 `PreToolUse`/权限事件推给手机 → app 渲染金色权限卡 + Allow/Deny → 回传决定 → agent 用 `--permission-prompt-tool`/权限 MCP 应用。这是"离开工位也能批 claude"的杀手锏。
- **持久化主题**：现在明暗选择重启就丢，存 UserDefaults。
- **离线/重连横幅**：连接断了在 UI 顶部给明确提示 + 重试，不只一个状态点；Mac 睡了显示"Mac offline"。
- **远程线程增量解析 + 大会话尾部优先**：现在 (a) 每来一段 delta 都从全部累计行重建时间线（长会话 O(n)）；(b) 订阅时 agent 把**整份文件**行发过来（几 MB 的会话 = 巨大 ws 消息 + 大解析）。改成：先发尾部 N 行秒开，滚到顶再懒加载历史；客户端只解析新增行。

## P1 — 功能补全

- **搜索真生效**：会话列表搜索框过滤；可选线程内搜索。
- **agent 实时状态**：复用 hook 事件，把 thinking/tool/needs-permission/done 推上来 → 列表状态徽章 + 线程"正在输入…"。
- **从手机新建会话**：New Session 的 Start 真正派发（agent `new` 命令：选 cwd + `claude --session-id <new> -p`）。
- **停止/打断**：给正在跑的 turn 发中断。
- **跳到最新**：滚上去看历史时显示"↓ 最新"按钮；线程下拉刷新。
- **设置页**：主题/字号/管理已配对的 Mac/权限默认值。
- **Diff/Markdown 增强**：diff 真行号 + 语法高亮 + 大 diff 性能；markdown 表格/嵌套列表/代码块高亮/可点链接/图片。

## P2 — 体验与平台

- **APNs 推送**：会话需要授权/完成/报错时推到手机（"离开工位"闭环）。需要 push token 流程 + agent/relay 触发推送。
- **多 Mac / 切换**：配对多台、显示当前连的是哪台。
- **图片附件**：渲染 transcript 里的 image 块。
- **iPad / 横屏**：现在只 iPhone 竖屏。
- **本地化** zh/en、**App 图标**（现占位）、**启动屏**。
- **无障碍**：Dynamic Type、VoiceOver、reduce-motion。
- **后台/前台**：ws 后台被挂起 → 前台重连（已部分做）；配合推送。

## 后端 / 安全track（影响 app 但属服务端）

- **跨网**：把 `relay.js` 部署到公网、`wss://`（出差/蜂窝可用）。
- **加密升级**：从共享密钥 AES → Noise/前向安全 + 配对设备白名单/吊销。
- **大消息分片** + 心跳 ping。
- 最终把 Node agent **搬进 vibTTY**（Swift，复用 ControlBridge/hooks）。

## 已知小问题

- 远程会话 host 显示 "remote · <cwd>"，可更友好（显示 Mac 名）。
- 测试用的 `claudetest` 会话会出现在列表里（无害）。
- 截图/dev env 钩子（CR_*）发布前清理或编译期剔除。
