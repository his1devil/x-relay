# Session 消息页性能与体验 Review

Review date: 2026-07-09  
Scope: iOS session message screen, remote Claude/Codex transcript loading, streaming output, keyboard coupling, history pagination, rich tool-output rendering.

## 目标

当前项目是一个远程连接 Claude Code / Codex 的 iOS app。消息页不是普通 IM：它同时承载用户消息、assistant 长文本、thinking、工具调用、diff、terminal/search/output、图片附件、权限请求、流式增量和历史分页。目标不是简单“能滚动”，而是接近 Discord 类 IM 的体验：

- 进入 session 后首屏尽快可读，不出现明显 blank / jump。
- 键盘弹出、收起、交互式下拉时，composer 与最新消息同步贴合。
- streaming 输出时，用户停在底部就安静跟随；用户翻历史时不被强拉。
- 历史分页提前预取，用户不需要硬拉到橡皮筋顶端才加载。
- 大会话、工具调用密集会话、含 base64 / 图片 / 大 stdout 的会话仍保持稳定帧率。

## 外部基准：Discord/IM 流畅度依赖什么

Discord 的公开工程文章给出一个非常有参考价值的判断：即使他们大量使用 React Native，核心聊天列表仍因为长列表、动态高度和键盘/输入框行为而使用原生 `UITableView` / native bridge；rich message 渲染也强调结构化解析与 native 渲染，而不是在滚动路径里临时做重活。

结合 Apple 对高性能列表和 SwiftUI 性能的官方建议，可以抽象出几个原则：

1. 长消息列表需要强虚拟化、复用、可控 batch update，而不是让整个声明式树频繁重算。
2. 列表 identity 必须稳定；SwiftUI/UICollectionView 都依赖稳定 identity 来避免全量 tear-down。
3. 键盘、输入框、底部 inset、content offset 必须由单一布局权威控制。
4. rich message 的 markdown parsing、tool preview、image decode 应尽量前置或缓存；滚动时只消费轻量 render model。
5. 历史消息分页要 cursor-based、byte/record bounded、可预取；不要把“初始 tail 拆包”伪装成完整分页。

## 当前消息页架构快照

入口仍叫 `ExyteThreadView`，文件注释也还描述 Exyte/Chat，但当前主消息列表实际已经切到 native SwiftUI：

- `ExyteThreadView` 创建 `ThreadModel` 和 `ExyteThreadAdapter`：`ClaudeRemote/Views/ExyteThreadView.swift:15-28`
- 主列表实际渲染为 `NativeTimelineList`：`ClaudeRemote/Views/ExyteThreadView.swift:170-186`
- Composer 目前通过 `.safeAreaInset(edge: .bottom)` 放在消息列表底部：`ClaudeRemote/Views/ExyteThreadView.swift:207-212`
- `NativeTimelineList` 使用 `ScrollView + LazyVStack + scrollPosition + defaultScrollAnchor`：`ClaudeRemote/Views/NativeTimelineList.swift:82-191`
- 远程 Claude 路径使用增量 decode + cached records + rebuild timeline：`ClaudeRemote/Model/ThreadModel.swift:610-653`
- Codex 路径仍是 full reparse：`ClaudeRemote/Model/ThreadModel.swift:586-607`
- 服务端订阅首包固定 tail 600KB / 400 行，再按 64KB 拆成 newest + prepend：`server/agent.js:340-383`

这说明当前代码已经有不少正确方向：首屏 curtain、pending older buffer、tail 增量 decode、长 assistant text 折叠、tool run 折叠、markdown cache、safeAreaInset composer。但要达到 Discord 手感，瓶颈已经从“单个测高 bug”变成“列表引擎 + 数据增量粒度 + streaming/keyboard 协调”的系统问题。

## P0 问题与结论

| 优先级 | 区域 | 结论 | 证据 | 建议 |
| --- | --- | --- | --- | --- |
| P0 | 死热路径 | `ExyteThreadAdapter` 已经不是主渲染路径，却仍在订阅 items 并做离屏测高。 | `ExyteThreadView.swift:17-28`, `ExyteThreadAdapter.swift:56-88` | native path 下先移除 adapter / HeightOracle 背景工作，或仅在启用 Exyte list 时创建。 |
| P0 | Streaming follow | 新 Native 列表只监听 `items.last?.id`，尾部 assistant 原位增长时 id 不变，因此不会跟随。 | `NativeTimelineList.swift:246-254`, `ThreadModel.swift:683-688` | 把 `model.revision` 或 tail content stamp 传入列表；`atBottom || working` 时 scroll bottom，否则点亮 new-below。 |
| P0 | 键盘联动 | 键盘 show/hide 只设置 `kbGuard`，没有重新锚定底部；safeAreaInset 移 composer，但 ScrollView 不会自动同步 content offset。 | `NativeTimelineList.swift:262-270`, `KeyboardObserver.swift:3-10` | 监听 `keyboardWillChangeFrame` / tick；仅在 atBottom 时用系统 duration/curve 重新 scroll bottom。 |
| P0 | re-enter 速度 | `ThreadCache` 注释承诺 instant re-entry / haveByte，但当前没有接入。 | `ThreadCache.swift:3-42`, `RelayClient.swift:431-435` | 进入 session 先恢复内存 snapshot，再后台 reconcile；subscribe 带 cursor/haveByte。 |

### 1. 幽灵 Exyte pipeline 是当前最确定的“免费性能”

`ExyteThreadView` 仍然持有：

- `@StateObject private var adapter: ExyteThreadAdapter`
- 初始化时创建 adapter
- `onAppear` 调用 `adapter.configureTwin`
- `ChatPane(rev: adapter.rev, ... adapter: adapter)`
- skeleton fallback 读取 `adapter.messages.isEmpty`

但主 list 实际没有使用 `adapter.messages` 渲染。与此同时，`ExyteThreadAdapter` 在 `init` 中订阅 `model.$items.combineLatest(model.$optimisticUser)`，每次 rebuild 都：

- invalidates tail height oracle
- 如果 twinTheme 已配置，则遍历所有 item，调用 `oracle.measure`
- 构造 `itemsById`
- 构造 Exyte `Message`
- 更新 `messages` 和 `rev`

这相当于每个 transcript update 跑两套列表准备：一套真实 NativeTimelineList，一套已经不用的 Exyte/UITableView adapter。这个优化风险最低、收益最高。

Recommended action:

1. 把 `ExyteThreadAdapter` 从 native list path 移除。
2. `ChatPane` 不再依赖 `adapter.rev`，改为直接观察 `model.revision` / `model.items`。
3. skeleton fallback 改为 `model.items.isEmpty`。
4. 如果还想保留 Exyte A/B，使用 feature flag 懒创建 adapter。

### 2. Streaming follow 现在只处理“新增 row”，漏掉“原位增长 row”

Agent 输出常见形态不是追加一条新 message，而是最后一个 assistant group 内容增长。当前 follow 逻辑：

```swift
.onChange(of: items.last?.id) { ... scrollTo("cr-bottom") ... }
```

当最后一条 assistant group 的 id 稳定、内容继续增长时，这个 onChange 不触发。结果是用户停在底部时，消息会向下长但视口不一定跟到底；如果 keyboard 或布局变化叠加，就会显得“没有和最新消息贴住”。

Recommended action:

- `ThreadModel.applyParsed` 已经在每次 parse 后 `revision += 1`，可把 `revision` 传入 `NativeTimelineList`。
- 列表内部监听 `revision`，逻辑类似旧 `ThreadView`：
  - 如果 `atBottom || model.working`，scroll bottom。
  - 否则不要打扰阅读历史，只设置 `newBelow = true`。
- 更进一步，把 `revision` 拆成：
  - `membershipRevision`: row 增删变化
  - `tailContentRevision`: 最后一条 row 内容变化
  - `historyRevision`: prepend/mount 变化

这样可以避免所有 UI 都对同一个大 revision 过度响应。

### 3. 键盘联动只“防误判”，没有“同步移动”

当前 `NativeTimelineList` 键盘处理只做：

- `keyboardWillShow` -> `kbGuard = true`
- `keyboardWillHide` -> `kbGuard = true`

这能避免 bottom sentinel 在键盘 transition 中误判为离底，但它没有执行核心动作：在键盘改变 viewport 时，保持底部消息与 composer 同步贴合。

`KeyboardObserver` 的注释已经写出真实问题：SwiftUI 的 `safeAreaInset` 会让 composer 跟键盘走，但 `ScrollView` 不会自动 re-anchor 内容到底部。旧 `ThreadView` 曾在 `kb.tick` 变化时 `scrollTo(bottomTargetID, anchor: .bottom)`。

Recommended action:

1. 在 Native path 恢复 keyboard observer。
2. 监听 `keyboardWillChangeFrame`，不仅是 show/hide，支持交互式 dismiss。
3. 仅当当前 `atBottom == true` 时 re-anchor；用户在历史区阅读时不强拉。
4. 使用系统 duration/curve；不要另起不匹配的手写 animator。
5. 避免 keyboard transition 期间触发 `userHasScrolled = true`。

### 4. ThreadCache 没有落地，重进 session 仍会重付成本

`ThreadCache` 注释目标很好：最近 remote session LRU hot-cache，re-enter 从内存立即渲染，并带 `haveByte` 做增量续订。但当前 `rg ThreadCache` 只看到定义，没有调用方。

Recommended action:

- `ThreadModel.stop()` 或 `applyParsed()` 后保存 `rawLines/cachedRecords/decodedLineCount/contextTokens/endByte`。
- `ThreadModel.start()` 先查 cache：
  - 命中：立即设置 `items` / `firstScreenReady` / `isLoading=false`。
  - 后台 subscribe reconcile。
- `RelayClient.subscribe(id:)` 扩展参数：`haveByte`, `historyStart`, `knownLineKey`。
- server 根据 cursor 只发送缺口，不重发整个 tail。

这对“从 session list 返回刚才的 session”非常关键。Discord 的频道切换手感，核心就是热内容瞬开。

## P1 问题与结论

| 优先级 | 区域 | 结论 | 证据 | 建议 |
| --- | --- | --- | --- | --- |
| P1 | Codex parse | Codex session 仍每次 full reparse。 | `ThreadModel.swift:586-607` | CodexTranscript 改成 records cache + incremental build。 |
| P1 | 历史分页 | 当前是 subscribe tail 拆包，不是真 cursor pagination。 | `server/agent.js:340-383`, `ThreadModel.swift:363-442` | 首包只发最近 1.5-2 屏；接近顶部预取 older cursor。 |
| P1 | 拉顶触发 | 用户必须 deliberate pull 到顶，和 Discord 式自然上滑不一致。 | `NativeTimelineList.swift:90-150` | 改为顶部前 N 行/前一屏 prefetch；pull-to-load 作为 fallback。 |
| P1 | 列表引擎 | `LazyVStack` 对 rich dynamic-height transcript 可用，但追 Discord 级别建议 UIKit/UICollectionView。 | `NativeTimelineList.swift:82-191` | 中期引入 UICollectionView/ChatLayout A/B，SwiftUI 只做 cell 内容。 |

### 5. Codex 与 Claude 的增量能力不一致

Claude 路径已经做了：

- 只 decode 新增 raw lines
- cachedRecords 追加
- 从 records snapshot build timeline
- generation guard 丢弃 stale parse

Codex 路径仍是：

- join 当前 raw lines
- `CodexTranscript.timeline(from:)`
- full build

Codex rollout transcript 工具调用密、`response_item` 多、custom tool output 多；如果继续 full reparse，越接近真实 Codex session 越容易在 streaming 和分页时出现卡顿。

Recommended action:

- 为 Codex 增加 `CodexRecord` cache。
- 将 `timeline(from:)` 拆成 `decodeLines` + `build(records:)`。
- 和 Claude 共用 `parseGen`、`decodedLineCount`、tail suffix decode。
- 对 tool output 建立 call_id -> output 的增量索引，避免每次 pass A 全扫。

### 6. 历史加载需要从“拉取旧行”升级为“窗口化消息模型”

server 当前策略：

- 最多读最近 600KB。
- 最多保留 400 行。
- 按 64KB batch 拆分。
- newest 作为 `.full`，older 作为 `.prepend` 延迟发。

这能减轻首次传输，但它仍有几个根本限制：

- 用户不看历史，也会收到 older batches。
- 超出 400 行的历史没有真正取法。
- base64 巨行会污染首包。
- 客户端 pending older 是 raw lines 级别，不是 message/page/cursor 级别。

Recommended action:

Define protocol v3:

```text
subscribe(id, afterByte?, beforeCursor?, window = tail)
threadPage(id, direction, cursor, records, nextCursor, byteRange, complete)
event(id, records, byteRange)
blob(id, blobRef) // image/base64/tool-output large payload lazy fetch
```

First paint:

- server 只发最近 1.5-2 屏的 logical messages，或者最多 64-128KB。
- 大 blob 用 placeholder + metadata，不在首包里带完整 base64。
- client 先展示最新内容，older cursor 存起来。

History:

- 用户滑到顶部前一屏时自动 fetch older。
- 页面大小按 bytes 和 logical turns 双 cap，而不是纯 line count。
- 每页边界对齐 user turn / assistant group seam，避免 group id 变化。

## P2：rich content 渲染成本

| 优先级 | 区域 | 结论 | 证据 | 建议 |
| --- | --- | --- | --- | --- |
| P2 | Markdown identity | `MarkdownBlock.id = UUID()` 会让同样 block 每次 parse 都是新 identity。 | `RichText.swift:195-210` | block id 改为 `hash(text + blockOrdinal + kind)`。 |
| P2 | Inline markdown | `MarkdownText` 每次 body 都可能构造 AttributedString。 | `MarkdownText.swift` | 增加 AttributedString cache，按 text/theme/font key。 |
| P2 | 图片解码 | transcript image thumb 首次出现时同步 UIImage decode/downscale。 | `TimelineViews.swift:264-285` | 后台 thumbnail cache；row 先占位固定尺寸。 |
| P2 | Tool output preview | `ExpandableMono` 每次 body split 全文计算 preview/lineCount。 | `ToolEmbedView.swift:493-525` | parser/build 阶段预计算 preview、lineCount、overflow。 |
| P2 | Segment grouping | `AssistantGroupView.segments` 每次 body 重新分组。 | `TimelineViews.swift:486-503` | 在 timeline build 阶段生成 display segments。 |

这些不是最先导致大跳动的点，但会在大会话滚动、快速进出、键盘反复弹出时累积成帧率问题。

## 推荐落地路线

### Phase 0: 先砍确定冗余

目标：不改协议、不大改架构，先拿回当前浪费掉的性能。

- 移除 native path 的 `ExyteThreadAdapter` 创建、订阅和 HeightOracle 测高。
- `ChatPane` 改为基于 `model.revision` / `model.items`。
- skeleton fallback 不依赖 `adapter.messages`。
- 恢复 NativeTimelineList 的 streaming follow：监听 content revision。
- 恢复键盘 re-anchor：show/hide/changeFrame + atBottom gate。

Expected result:

- 打开 session 更快。
- streaming 时底部跟随恢复。
- 键盘弹出/收起不再只靠 guard。
- main thread 少跑一套离屏测高。

### Phase 1: 真正的 warm session

目标：回到最近 session 几乎秒开。

- 接入 `ThreadCache`。
- stop/applyParsed 时写 cache。
- start 时先读 cache 并立即 render。
- subscribe 带 `haveByte` / cursor。
- server 只发缺口。

Expected result:

- session list -> session -> back -> session 的路径接近 Discord 频道切换。
- 网络慢时也能先读旧快照，再渐进补齐。

### Phase 2: Cursor pagination + blob lazy loading

目标：大会话不靠 400 行 cap，历史自然预取。

- 协议 v3：cursor-based older fetch。
- 首包按 logical messages / bytes 双 cap。
- base64 / 大 stdout / 图片改 blobRef lazy fetch。
- 顶部前一屏 prefetch，pull-to-load 仅保留为显式手势。

Expected result:

- 巨会话打开不再被 base64 巨行拖慢。
- 上滑历史不再出现“到顶硬拉 -> 等待 -> 插入”的停顿。
- 历史 page 可持续加载到完整 transcript。

### Phase 3: UICollectionView / ChatLayout A/B

目标：追 Discord 级别列表控制力。

Architecture:

- UIKit `UICollectionView` 负责 virtualization、keyboard inset、content offset、batch update。
- SwiftUI 继续负责 row content，但放进 `UIHostingConfiguration` 或受控 hosting cell。
- Diffable data source 处理 membership。
- Tail streaming 使用 visible cell in-place update / reconfigure，不整表 reload。
- Prepend 使用 batch update 前后 content height delta 固定 offset。

Why:

- `ScrollView + LazyVStack` 简洁，但对复杂 dynamic-height rich transcript，可控性不如 UIKit collection/list。
- Discord 公开工程取舍也说明：最核心的 chat list/keyboard/input coupling 值得走 native。

## 建议的验收指标

建议把下面指标写进 perf HUD / signpost / XCTest UI benchmark：

1. Session open:
   - cold open 到 first readable frame < 500ms（缓存命中 < 150ms）
   - skeleton visible duration p95
   - first parse/build duration p95

2. Scroll:
   - 60fps/120fps frame drop count
   - visible row create/reuse count
   - markdown parse count during fast scroll 应接近 0

3. Streaming:
   - tail content update interval
   - atBottom 时 bottom drift <= 2pt
   - not-at-bottom 时 0 forced scroll

4. Keyboard:
   - show/hide/changeFrame bottom drift <= 2pt
   - interactive dismiss 中 composer 与 bottom message 同步
   - keyboard transition 不触发 `userHasScrolled`

5. Pagination:
   - older fetch latency p95
   - prepend anchor drift <= 2pt
   - page byte size / record count cap
   - duplicate line/page drop count

6. Memory:
   - hot cache memory cap
   - thumbnail cache memory cap
   - memory warning 后可安全降级

## Source references

External:

- Discord Engineering, [Why Discord is Sticking with React Native](https://discord.com/blog/why-discord-is-sticking-with-react-native). Used for the key comparison that Discord kept native chat-list/input pieces where long dynamic-height lists and keyboard behavior demanded native control.
- Discord Engineering, [How Discord Renders Rich Messages on the Android App](https://discord.com/blog/how-discord-renders-rich-messages-on-the-android-app). Used for the rich-message principle: parse/structure rich content deliberately and keep rendering predictable.
- Apple Developer, [Demystify SwiftUI performance](https://developer.apple.com/videos/play/wwdc2023/10160/). Used for SwiftUI identity/dependency/lifetime framing.
- Apple Developer, [Make blazing fast lists and collection views](https://developer.apple.com/videos/play/wwdc2021/10252/). Used for the UIKit list/collection performance direction: reuse, prefetching, diffable updates, and cell lifecycle control.
- ChatLayout, [ekazaev/ChatLayout](https://github.com/ekazaev/ChatLayout). Used as a reference architecture for UICollectionView-based chat layout with dynamic cells.
- Exyte, [exyte/Chat](https://github.com/exyte/Chat). Used as current ecosystem context because this project previously integrated Exyte.
- Stream, [SwiftUI Message List docs](https://getstream.io/chat/docs/sdk/ios/swiftui/chat-channel-components/message-list/). Used as ecosystem context for production chat SDK message-list composition.

Local code evidence:

- `ClaudeRemote/Views/ExyteThreadView.swift`
- `ClaudeRemote/Views/ExyteThreadAdapter.swift`
- `ClaudeRemote/Views/NativeTimelineList.swift`
- `ClaudeRemote/Model/ThreadModel.swift`
- `ClaudeRemote/Model/ThreadCache.swift`
- `ClaudeRemote/Model/RelayClient.swift`
- `ClaudeRemote/Model/KeyboardObserver.swift`
- `ClaudeRemote/Views/Components/RichText.swift`
- `ClaudeRemote/Views/Components/MarkdownText.swift`
- `ClaudeRemote/Views/Timeline/TimelineViews.swift`
- `ClaudeRemote/Views/Timeline/ToolEmbedView.swift`
- `server/agent.js`

