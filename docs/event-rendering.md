# 事件类型全量梳理与渲染/交互方案

基于全量扫描 16 个 transcript / 23,261 条记录。Claude Code 的 `~/.claude/projects/**/*.jsonl` 每行一条记录，`type` 决定大类；消息体在 `message.content`（字符串或 block 数组）；**工具结果的富元数据在记录顶层的 `toolUseResult`**（当前未充分利用，见 §5）。

## 1. 顶层 type 分布

| type | 量 | 处理 |
|---|---|---|
| `assistant` | 8824 | 渲染（text/thinking/tool_use block）|
| `user` | 4207 | 渲染（真实 prompt）或挂载 tool_result / image |
| `attachment` | 3454 | 多数内部，少数要渲染（image/file/queued_command）见 §4 |
| `permission-mode` | 1398 | 模式切换 → 细系统注记（default/acceptEdits/plan）|
| `last-prompt` | 1384 | 内部（与 user prompt 重复）→ 隐藏 |
| `mode` | 1372 | normal → 隐藏；非 normal 可注记 |
| `bridge-session` | 890 | 内部 → 隐藏 |
| `system` | 730 | 按 subtype 处理，见 §3 |
| `file-history-snapshot` | 670 | 内部 → 隐藏 |
| `queue-operation` | 332 | 排队（task-notification）→ 内部，可选注记 |

## 2. 消息 block（已实现，部分待增强）

| block | 量 | 现状 | 增强 |
|---|---|---|---|
| `assistant/text` | 2370 | ✅ RichText 块级 markdown | 表格/嵌套列表/代码高亮 |
| `assistant/thinking` | 2688 | ✅ 可折叠 | 流式指示、签名隐藏 |
| `assistant/tool_use` | 3772 | ✅ 工具 embed | 见 §3 富化 |
| `user/tool_result` | 3772 | ✅ 挂回 tool_use | 用 `toolUseResult` 富数据 §5 |
| `user/str` `user/text` | 436 | ✅ 真实 prompt（过滤 caveat）| — |
| **`user/image`** | 3 | ❌ 未渲染 | 渲染图片块（base64/source）→ 缩略图，点开大图 |

## 3. 工具 embed（17 种，按频次）

已实现通用 + Bash/Edit/Read/Write/Search/Todo/Question/generic。逐项渲染/交互方案：

| 工具 | 量 | 渲染 | 交互 | 富数据(`toolUseResult`) |
|---|---|---|---|---|
| **Bash** | 1286 | 绿框 Terminal + `$cmd` + 输出 | 展开/折叠、复制命令 | `stdout`/`stderr` **分离**、`interrupted`、`code` → 真实退出码/错误流分色 |
| **Edit** | 1116 | 珊瑚框 + mini diff → Diff 屏 | 点进全屏 diff | **`structuredPatch`（真实 hunk+行号）**、`originalFile`、`userModified` → Diff 屏用真行号而非推导 |
| **Read** | 653 | 蓝框 + 文件名 + 行数 | 点开看内容 | `file.content`、`numLines`、`isImage` → 图片文件显示缩略图 |
| **Write** | 378 | 珊瑚框 Created + 预览 | 点开 | `structuredPatch`（新建即全增）|
| **TaskUpdate/Create** | 200 | 蓝框 To-dos + 勾选态 | — | `statusChange`、`updatedFields` → 高亮"X→完成" |
| **AskUserQuestion** | 16 | 金框 问题+选项卡 | **可点选项回传**（远程时）| `questions`/`answers` → 已答的显示选中项 |
| **WebFetch/ToolSearch** | 37 | 灰框 + query | 展开结果 | `matches`/`query` |
| **SendUserFile** | 20 | 文件卡 | 点开/下载 | `caption`、`attachments`、`bytes` → 文件名+大小，图片缩略 |
| **DesignSync** | 28 | generic | — | `method`/`path` |
| **ScheduleWakeup/Monitor/Agent/TaskStop/EnterPlanMode/ExitPlanMode** | 共~38 | generic（图标区分）| — | 各自 metadata |

## 4. system / attachment（多数隐藏，少数渲染）

**system subtype**（730）：
- `turn_duration`(278) → 可在 turn 末尾显示"用时 Xs"细注记
- `stop_hook_summary`(273) → 隐藏（hook 噪声）
- `away_summary`(129) → "你离开期间的总结"卡（产品点：回来看摘要）
- `compact_boundary`(5) → "上下文已压缩"分隔线
- `scheduled_task_fire`(24)/`local_command`(16)/`bridge_status`(5) → 细注记/隐藏

**attachment type**（3454，绝大多数内部）：
- `hook_permission_decision`(2729) → **权限决定记录**：渲染成"✓ 已批准 / ✕ 已拒绝 <工具>"系统注记（驱动 §6 的已决状态）
- `queued_command`(61) → "已排队"提示
- `edited_text_file`/`file`/`directory`/`image`(58) → 用户附件 → 渲染附件卡/缩略
- 其余(`task_reminder`/`deferred_tools_delta`/`*_listing`/`date_change`/`plan_*`...) → 隐藏

**permission-mode**(1398)：`default`/`acceptEdits`/`plan` 切换 → 细注记"权限模式 → acceptEdits"。

## 5. 关键升级：用好 `toolUseResult` 富数据

当前只用 tool_use 的 `input` + 扁平化的 tool_result `content`。但记录顶层 `toolUseResult` 有结构化数据（高价值，待接入解析器）：

- **`structuredPatch`**（1465）：Edit/Write 的真实 diff hunk（`oldStart/oldLines/newStart/newLines/lines`）→ **Diff 屏直接用真行号 + 上下文**，不再从 old/new 字符串推导。
- **`stdout`/`stderr`/`interrupted`/`code`**（1261）：Bash 结果 → 分流分色 + 真实退出码 + 中断标记。
- **`file.content`/`numLines`/`isImage`**：Read → 内容预览 + 图片缩略。
- **`questions`/`answers`**：AskUserQuestion → 显示已选答案。
- **`gitOperation`/`taskId`/`statusChange`/`matches`** 等：各工具的专属富化。

实现：解析器除了挂 `content` 字符串，再把记录的 `toolUseResult` 解码进 `ToolResult`（新增可选结构化字段），各 embed 优先用结构化数据。

## 6. 交互方案：权限（P0 核心）

历史 transcript 里权限多已决（`hook_permission_decision` 记录结果）。**实时驱动**时要做交互式审批：
1. **agent 侧**：装/用 `PreToolUse` hook（或 `--permission-prompt-tool`），把待批工具 + 入参（命令/diff）作为 `permission` 事件推给手机；不自动放行。
2. **app 侧**：渲染金框"需要授权"卡 + 入参预览 + **Allow / Deny** 按钮。
3. 点击 → 经中继回传决定 → agent 放行/拒绝该工具 → 后续 transcript 流回。
4. 历史会话：用 `hook_permission_decision` 渲染"✓你已批准 / ✕你已拒绝"的已决态。

其它交互：消息长按复制、代码块复制、tool 输出展开、diff 点进、停止/打断 turn（agent `interrupt` 命令）、附件/图片点开。

## 优先级落地顺序（与 ios-roadmap 对齐）

1. （已做）乐观回显 + 工作指示、主题持久、离线横幅
2. `toolUseResult` 结构化接入 → Bash 分流 / Edit 真行号 diff（§5）
3. 交互式权限 Allow/Deny（§6）
4. user/image + 附件渲染、away_summary 卡、compact 分隔
5. 长按复制/代码复制、停止 turn、turn 用时注记
