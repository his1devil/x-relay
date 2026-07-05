# HALX × vibTTY — 原生托管设计

让 HALX（iOS）驱动并渲染一个由 **vibTTY 托管**的常驻 Claude Code 会话，取代现在
独立 Node agent 每条消息重启 `claude -p` 的做法。本文基于 vibTTY 的实际代码
（`/Users/antai/Development/desktop/glint/vibTTY/`）。

已与用户确认的决策：
- **两种 agent 模式共存**——保留 Node agent（用于测试），同时新增 vibTTY 原生桥。
  手机可配对任一方；中继 + HALX 协议两者共用。
- **渲染 = 结构化 IM（主）+ 可选的终端镜像视图。**
- **权限 = 阻塞式 PreToolUse hook → 金色 Allow/Deny 卡。**

---

## 0. vibTTY 已经具备的能力（已核对源码）

- **PTY 托管**：每个 pane 是一个 `ghostty_surface_t`，fork 出 shell；配置支持
  `working_directory`、`initial_input`（如 `claude --continue\n`）、注入环境变量
  （`VIBTTY_PANE_ID`、`VIBTTY_AGENT_SOCK`）。其 cmux libghostty 分叉还暴露了
  `command` 配置字段（可直接跑 `claude`）——目前未使用。
- **输入注入**：`ControlBridge`（`Agent/ControlBridge.swift`）——一个 token 鉴权的
  Unix socket（`~/.vibtty/run/control.sock`），命令有 `list` / `focus` /
  `send-text(pane,text,enter)` / `send-key(pane,keys)`，接到
  `ghostty_surface_text` / `ghostty_surface_key`。这就是"驱动" API，只差网络传输。
- **Agent 状态**：Claude hooks → `~/.vibtty/hooks/vibtty-report.sh` → `agent.sock`
  → `AgentBridge` → `PaneAgentState {kind,status,detail,…}`，状态有
  `idle/thinking/tool/needsPermission/compacting/justCompleted/failed`。状态机已
  可用（hooks + 1Hz 按 pid 兜底校正）。
- **镜像原语**（在分叉的 `ghostty.h` 里，大多未用）：
  `ghostty_surface_render_grid_json`（把可视区 + 回滚 + 光标/模式导出为 JSON，
  注释写明"for mobile mirrors"）、`ghostty_surface_set_pty_tee_cb`（原始字节流输出，
  注释"broadcast to a paired iPhone"）、`ghostty_surface_process_output`（字节流输入）、
  `io_mode = MANUAL`（由宿主自己驱动 IO）、iOS UIView 平台。
- **Pane 标识**：`"<workspaceUUID>:<paneSeq>"`——同时用作 `VIBTTY_PANE_ID`、
  控制 socket 的 `pane` 参数、agent 事件的 `pane`、以及回滚快照文件名。

要补的缺口：网络传输 + 配对、把实时输出真正接出来、补全 hook payload
（tool/prompt/`session_id`/transcript 路径现在被丢弃）、一个"新建跑 claude 的 pane"
命令、一个阻塞式权限 hook。

---

## 1. 两种模式共存（同一中继 + 同一 HALX）

中继（`server/relay.js`，盲转发）和 HALX↔中继协议是契约。任何会讲这套协议的
"agent"都能服务手机。我们跑两种：

- **模式 A — Node agent**（`server/agent.js`，现状）。每条消息 `claude --resume -p`，
  transcript tail，AES-GCM。保留用于测试 / 无 vibTTY 的 headless 场景。
- **模式 B — vibTTY 原生**（新，本文）。vibTTY 在 pane 里托管常驻 `claude`，用
  ControlBridge 驱动，tail transcript，观察 hooks，并自己（Swift）连中继。同一个
  `claude` 既能本地用（显示 pane = TUI），又能远程用（HALX）——无缝切换。

手机一次配对一个 room；谁拥有该 room 谁来应答。（未来：HALX 列出多台 Mac/agent。）

---

## 2. 模式 B 架构

```
 iOS HALX ──ws──▶ 中继 (room, 密文) ──ws──▶ vibTTY RemoteBridge (Swift)
   结构化 IM              盲管道                  │
   + 可选镜像                                     ├─ ControlBridge ──▶ claude pane (PTY)   [驱动]
   + Allow/Deny 卡                                ├─ transcript tail (~/.claude/…jsonl)    [读]
                                                   ├─ AgentBridge / PaneAgentState          [状态]
                                                   ├─ 阻塞式 PreToolUse hook ◀──────────────[权限]
                                                   └─ render_grid_json / pty_tee            [镜像, 可选]
```

### 2.1 进程托管 + 本地⇄远程无缝切换
- 一个 pane 常驻跑 `claude`。首选：设置分叉的 `cfg.command = "claude"`
  （+ `working_directory`、`wait_after_command`），让 pane 本身就是 agent；兜底：
  用现在的 `initial_input = "claude\n"`。
- 这个 pane 就是普通 vibTTY pane：**显示它 = 在 TUI 里本地驱动；隐藏/headless =
  远程驱动。** 同一进程、同一份 transcript、单一所有者。这是相对 `claude -p` 的核心
  优势（上下文常驻、不重启），也是"放到 vibTTY 里托管"的理由。
- 每个被托管的 agent pane 作为一个"会话"广播给手机（`pane` key + cwd + `lastAgent`）。

### 2.2 驱动（手机 → claude）—— 复用 ControlBridge
- HALX `send(id,text)` → 中继 → RemoteBridge → **进程内调用 ControlBridge 同款代码**
  （`WorkspaceStore.controlSendText` → `view.injectText` + Enter）。不需要裸 PTY fd。
- RemoteBridge 跑在 vibTTY 内部，所以直接调注入路径（不走控制 UDS）——但必须遵守
  同样的门禁（`externalControlEnabled`、token）才接受远程输入。
- `send-key`（方向键/回车）可用于菜单式交互。

### 2.3 读 —— 结构化（主）
- claude（TUI）照样写同一份 `~/.claude/projects/<cwd>/<id>.jsonl`。RemoteBridge
  tail 它（把 Node agent 的 tail 逻辑移植到 Swift / FSEvents），把 `thread`
  （尾部优先 ~400 行）+ `event`（新增行）流给 HALX。
- HALX 用**现有** `TranscriptParser` + 原生视图渲染——**HALX 渲染零改动**。这就是
  结构化为主的原因。
- 需要 pane→transcript 映射：从 hook payload 拿 `session_id`（补全后，见 §2.6），
  或监听该 pane cwd 下最新的 jsonl 兜底。

### 2.4 读 —— 终端镜像（可选、按需开启的视图）
- 想要真终端视图：把 `ghostty_surface_render_grid_json` 帧（节流，如变化时 ≤30fps）
  作为新中继消息 `{type:grid,id,frame}` 流出；或用 `pty_tee_cb` 的原始字节增量。
- HALX 在线程里给一个**切换**："结构化 ⇄ 终端"。终端视图渲染 grid JSON
  （带色单元格 + 光标）。该模式下的输入 = 通过 ControlBridge `send-key`/`send-text`
  发原始按键。
- 这复用分叉里已有的原语；纯增量，不影响结构化路径。

### 2.5 状态（实时）
- 复用 hooks → `AgentBridge` → `PaneAgentState`。RemoteBridge 观察
  `WorkspaceStore.paneAgentState[key]`（或 `.vibttyAgentEvent` 通知），把
  `{type:status,id,status,detail}` 流给 HALX → 驱动"Claude 正在处理/思考/待授权"
  指示 + 会话列表徽章。

### 2.6 权限（阻塞式 hook → 金卡）
- 加一个**阻塞式** PreToolUse hook（像 HALX 现在的 `perm-hook` 那样的 `.cjs`），
  经 vibTTY 的 hook 安装器装上，限定改动类工具
  （Bash/Write/Edit/MultiEdit/NotebookEdit）。命中时连到 vibTTY 的权限 socket、
  阻塞等待，然后输出 `permissionDecision: allow/deny`（这会**绕过 TUI 内的交互提示**）。
- vibTTY 把 `{type:permission,id,tool,command,path,preview}` 转给 HALX → 金卡 →
  `{type:permission-decision,id,decision}` → hook 返回。手机离线 ⇒ 自动拒；超时 ⇒ 拒。
  与模式 A 协议一致。
- 这需要**重新接通 vibtty-report.sh / hook payload**，让工具细节 + `session_id`
  保留下来（现在只转发事件名）。状态用的 fire-and-forget 上报保留；权限另开阻塞通道。

### 2.7 网络传输 + 配对（新的 Swift 部分）
- `RemoteBridge`（Swift，在 vibTTY 内）实现与 Node agent **相同的中继协议**：
  连接（URLSession/NWConnection 的 ws 到中继）、`join {room,role:agent}`、AES-GCM
  信封（`iv|tag|ct`）、处理 `list`/`subscribe`/`unsubscribe`/`send`/
  `permission-decision`/`ping`。
- 身份持久化（`~/.vibtty/identity.json`——room+key），让二维码稳定；vibTTY 在自己
  UI 里展示配对二维码（设置 → "Remote (HALX)"），受现有 `externalControlEnabled`
  同意开关保护。
- 中继沿用公网部署（`8.160.186.31`，systemd）。之后：wss/TLS + Noise/前向安全 +
  设备白名单（与模式 A 共享）。

### 2.8 新建会话（从手机）
- 加一个控制命令 `spawn {cwd, agent:"claude"}`（以及 HALX "New Session" 派发）→
  vibTTY 在 `cwd` 下用 `cfg.command="claude"` 开一个 pane → 作为新会话广播。补上
  现在"无法程序化新建"的缺口。

---

## 3. 工作拆解

### vibTTY 侧（Swift）—— 新增 `Agent/RemoteBridge.swift` + 少量改动
1. **RemoteBridge**：中继 ws 客户端 + AES-GCM + room/identity + list/subscribe/
   send/permission 消息处理（移植 Node agent 逻辑）。
2. **Transcript tail**（Swift，FSEvents 监听 `~/.claude/projects`，尾部优先）。
3. **驱动**：调现有注入路径（`controlSendText`/`injectText`），受同意门禁约束。
4. **状态**：观察 `paneAgentState` → 流出。
5. **阻塞式权限 hook**：加 `.cjs` + 权限 UDS；重接 hook payload
   （tool/input/session_id/transcript 路径）。
6. **镜像（可选）**：接 `set_pty_tee_cb` 和/或周期性 `render_grid_json`；作为
   `grid` 帧流出。
7. **spawn 命令** + 把 pane 当会话广播；用 `cfg.command="claude"`。
8. **配对 UI**：设置里的二维码 + 同意开关。

### HALX 侧（iOS）—— 多为增量
1. 结构化渲染 / 解析 / 驱动 / 权限卡 **不动**——已经讲这套协议。
2. **新增**：终端镜像视图 + 结构化⇄终端切换（消费 `grid` 帧；发原始按键）。
3. **新增（之后）**：多 agent/Mac 选择器（Node vs vibTTY 的 room）。

### 中继 —— 无改动（盲转发）；`grid` 走现有通用 `data` 透传即可。

---

## 4. 分期
- **P1 — 原生对齐**：RemoteBridge（中继 + 加密 + list/subscribe/send）+ transcript
  tail + 经 ControlBridge 驱动 + 状态。手机能读 + 驱动一个 vibTTY 托管的常驻 claude。
  （仅结构化。）
- **P2 — 权限**：阻塞式 hook + payload 重接 + 模式 B 的金卡。
- **P3 — 新建 + 配对 UI**：从手机新建会话；vibTTY 里的二维码/同意开关。
- **P4 — 终端镜像**：grid 推流 + HALX 切换。
- **P5 — 加固**：wss/TLS、Noise、设备白名单、重连/心跳、单一所有者仲裁；之后
  下线/合并模式 A。

---

## 5. 健壮性 / 待确认的开放点（边做边定）
- **单一所有者**：一个手机 + 本地 TUI 同时驱动同一个 pane，注入和本地打字可能交错。
  建议：串行化驱动（排队），和/或在 pane 上显示"远程正在输入"。需确认仲裁方式。
- **交互提示冲突**：阻塞 hook 绕过了工具提示，但 claude 还有非工具提示
  （如 `/login`、信任弹窗）。决定：检测并转给手机，还是要求本地处理。
- **session_id 映射**：最干净的是从（重接后的）hook payload 读；兜底是"cwd 下最新
  jsonl"。需确认可接受。
- **同意/安全**：远程驱动权力很大。受现有 `externalControlEnabled` + 每次配对审批
  约束；绝不自动开启。
- **镜像开销**：grid 帧可能很重；节流 + 仅在终端视图打开时推。需确认帧率/回滚行数预算。
- **模式 A / B 选择**：配对时用户怎么选——分别发两个二维码（Node vs vibTTY，现状），
  还是统一一个由 HALX 区分？

---

## 6. P1 详细任务分解（下一步动手：原生 RemoteBridge）

目标：vibTTY 托管一个常驻 claude，手机能**读**它的会话/transcript + **发消息驱动**它。
仅结构化渲染，复用现有 HALX（iOS 零改动，除了 §7 的分块重组）。

新增文件（建议放 `vibTTY/Agent/Remote/`）：
1. **`RemoteCrypto.swift`** — AES-256-GCM，对齐 Node 的 `iv(12)|tag(16)|ct` base64 信封
   （CryptoKit）。✅验证：能解开 Node agent 用同一 key 加密的一帧（写个单测）。
2. **`RemoteIdentity.swift`** — room(16 hex)+key(32B) 持久化到
   `~/.vibtty/remote-identity.json`；生成 pairing base64（`{url,room,key}`）+ 二维码。
3. **`RemoteBridge.swift`**（核心）—
   - `URLSessionWebSocketTask` 连中继；`join {room, role:"agent"}`；指数退避自动重连。
   - 收：`list` / `subscribe` / `unsubscribe` / `send` / `permission-decision` / `ping`。
   - 发：`sessions` / `thread` / `event` / `sent` / `status`（**经 §7 分块**）。
   - 受 `externalControlEnabled` 同意开关约束才接受 `send`。
4. **`RemoteSessions.swift`** — 枚举会话：扫 `~/.claude/projects/**/*.jsonl`，取
   cwd/name/mtime/snippet（tail，**短截**：≤80 字）。
5. **`RemoteTranscriptTail.swift`** — FSEvents 监听目标 jsonl；`subscribe` 时发尾部
   ~400 行（`thread`），增量发新行（`event`）；尾部优先、增量防抖。
6. **驱动接线** — `send(id,text)` → 找到该 session 对应 pane → 调现有
   `WorkspaceStore.controlSendText` / `injectText` + Enter。

接入点（改现有代码）：
- `WorkspaceStore.init`：按开关启动 `RemoteBridge`（仿现有 `ControlBridge.start()`）。
- `SettingsView`：加 "Remote (HALX)" 开关 + 二维码（复用 `externalControlEnabled` 同意模型）。
- **pane↔session 映射**：P1 先用"pane.workingDirectory 下最新 jsonl"兜底；P2 用 hook 的
  `session_id` 精确化。

顺序 + 验证里程碑（每步都用**现成 HALX app** 验，它已讲这套协议）：
1. Crypto → 单测解开 Node 的帧。
2. Bridge `join`+`list` → HALX 扫 vibTTY 的码 → 看到会话列表。
3. transcript tail → HALX 进会话 → 结构化渲染出来。
4. drive → HALX 发消息 → vibTTY 里的 claude pane 收到并执行。

## 7. 传输健壮性：大帧分块（本次实战教训，提前到 P1）

**踩坑**：手机**蜂窝链路会黑洞大的 WebSocket 帧**——小帧（~500B）能过，30KB 的会话帧、
几百 KB 的 transcript 帧**过不去**（路径 MTU 很小且 PMTUD 失效，大帧的满载包被静默丢弃 →
TCP 队头阻塞 → 连接卡死重连）。临时靠**把服务器 MTU 降到 576**（IPv4 保证的最小值）绕过，
但这脆弱：依赖服务端网络、影响该机所有流量、换网络/服务器就复发。

**健壮做法（两种模式共享的应用层协议）**：发送端把任何 >~1KB 的明文帧切成小块，分多条
小帧发——`{type:"__chunk", cid, seq, total, data}`，每条最终 ws 帧 ≤ ~1KB；接收端按 `cid`
缓冲重组 → 解析 → 再走 `handleApp`。

- **HALX** 加重组逻辑（`handleApp` 处理 `__chunk`）——**Mode A / B 都受益**。
- **Node agent（Mode A）** 与 **vibTTY RemoteBridge（Mode B）** 都实现同款发送端分块。
- 之后即可把服务器 MTU 调回 1500（分块后不再依赖低 MTU）。

→ 因为 transcript 帧本来就大，**分块必须在 P1 就做**（否则蜂窝下进会话永远 loading）。这是
当前 Mode A 调试暴露出来的、对 Mode B 同样致命的问题，已纳入计划最前。

## 8. 修订后的分期（把分块并入 P1）
- **P1** = 原生 RemoteBridge（中继+crypto+join+list+subscribe+send）**+ §7 分块** + transcript
  tail + 经 ControlBridge 驱动 + 状态。→ 手机能读+驱动 vibTTY 托管的常驻 claude（结构化）。
- **P2** 权限：阻塞 hook + payload 重接 + 金卡。
- **P3** 新建会话(`spawn`) + 配对 UI（二维码/同意开关）。
- **P4** 终端镜像：`render_grid_json`/`pty_tee` 推流 + HALX 切换。
- **P5** 加固：wss/TLS、Noise、设备白名单、重连/心跳、单一所有者仲裁；之后下线/合并 Mode A。
