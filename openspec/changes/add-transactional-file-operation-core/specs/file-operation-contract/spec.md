## ADDED Requirements

### Requirement: 请求在任何副作用前完成结构校验
`FileOperationService` SHALL 在写 journal 或文件系统前校验 `OperationRequest`。sources MUST 是非空、绝对 file URL，且不得包含重复的标准化目录项 URL、source/destination 同一目录项、source 包含 destination 或 destination 包含 source。不同路径的 hard link MUST 作为不同目录项保留；overlap 判断 MUST NOT 跟随 symlink target。需要目标的 kind MUST 提供 destination；失败 MUST 返回 typed validation error，且不得创建 operation。

#### Scenario: 拒绝重叠目录
- **WHEN** copy 请求把目录复制到其自身后代
- **THEN** service 在产生任何文件系统副作用前拒绝请求，并返回可识别的重叠错误

#### Scenario: 拒绝同一路径重复提交
- **WHEN** sources 以路径标准化前后的两个字符串重复指向同一目录项
- **THEN** service 拒绝请求，而不是把同一目录项规划两次

#### Scenario: 允许 Hard-link 多路径
- **WHEN** sources 包含两个路径不同但 device/inode 相同的 hard links
- **THEN** service 保留两个 operands，并由 hard-link identity map 维护 topology

### Requirement: 各操作的 operand 与 destination 语义确定
Copy/move SHALL 支持一个或多个现存 operands及 container destination；单 item duplicate MAY 使用 exact destination。Rename/replace SHALL 恰好一个 source 和 exact destination。Trash SHALL 使用 nil destination。为满足非空 sources 约束，create SHALL 把 sources 解释为一个或多个尚不存在的 exact operand URL，并使用 versioned `CreateDescriptor`；create/merge/trash 在本 change 启用前 MUST 返回 `featureDisabled`。

#### Scenario: Create 没有伪造 source
- **WHEN** M5 之前调用方提交 create
- **THEN** request 可被结构解析但以 featureDisabled 拒绝，不得创建占位 source 或产生文件副作用

### Requirement: 多 source 在写入前完成目标名称投影
Planner SHALL 在任何 staging 前，按 destination adapter 的 case/Unicode normalization 语义投影所有 final names，同时检测 operation 内同名、现有 destination 冲突和 keep-both reservation 冲突。名称等价规则 unknown 时，多 source 写入 MUST 被阻止；keep-both SHALL 使用 exclusive reservation/commit loop。

#### Scenario: Case-insensitive 目标卷名称碰撞
- **WHEN** 两个 sources 投影为 `Report` 与 `report`，而目标卷认为两者等价
- **THEN** preflight 在第一项提交前请求冲突决策或阻止操作，不产生可避免的 partial commit

### Requirement: 公共服务接口与 UI 解耦
Core SHALL 暴露 actor 隔离的 submit、snapshot、events、resolve、pause、resume、cancel、retry 和 recover 操作。公共类型 MUST NOT 引用 AppKit、`FileOps`、`TransferQueue`、Pane、Window、`NSAlert`、`NSPasteboard`、`NSApplication` 或 UI closure。

#### Scenario: 无 App 启动的 Core 测试
- **WHEN** `RascalFileOperations` 与其 unit tests 单独构建和运行
- **THEN** 测试无需启动 `NSApplication`、轮询 App RunLoop 或调用 production test hook

### Requirement: 操作与事件身份稳定
Service SHALL 生成稳定 `OperationID` 和 `OperationItemID`。每个 `OperationEvent` MUST 携带 operation ID、适用时的 item ID，以及在该 operation 内严格单调递增且持久化后不可复用的 sequence。

#### Scenario: 多阶段事件排序
- **WHEN** 一个 item 依次进入 staging、metadata 和 verifying
- **THEN** 消费者可以仅凭 operation ID、item ID 与 sequence 得到无歧义的顺序

#### Scenario: 重启后继续序列
- **WHEN** 未完成 operation 在进程重启后恢复并发出新事件
- **THEN** 新 sequence 大于该 operation 已持久化的所有 sequence

### Requirement: Event stream 支持独立订阅与重启发现
`events()` SHALL为每个subscriber提供独立broadcast stream。Service SHALL在actor内原子捕获durable replay watermark并注册只接收高于watermark的live subscriber，通过pull-based分页按sequence重放unresolved history，再无缝drain注册后暂存的bounded live events；replay本身 MUST NOT预先塞入有界live queue。纯订阅 MUST NOT生成marker event、分配operation sequence或修改history。每个accepted operation MUST在planned admission事务中写入sequence 1的durable `admitted(snapshot)`，使尚未active的排队operation可被replay发现。Recovery command完成、旧capability失效和完整后继capability列表 MUST通过单一durable `recoveryConverged(completedActionID, availableActions)`事件原子表达，后继动作expected sequence绑定该事件；公开projection不得在相同latest sequence下静默改变。Durable events MUST持久化；高频progress MAY按item合并，但其sequence MUST从durable-reserved range分配，崩溃后允许gap而不得复用。任何live overflow/yield drop MUST可观察地终止该subscriber stream，要求消费者丢弃整个projection（包括EOF前缓冲尾部）、重新订阅并用snapshot/replay收敛；不得依赖sequence gap判断overflow。

#### Scenario: App 重启恢复 UI
- **WHEN** App 在存在 unresolved operations 时重新订阅 events
- **THEN** subscriber 可从 replay 发现稳定 IDs、重建状态，并用 snapshot 收敛到 latest sequence

#### Scenario: 排队 operation 尚未启动
- **WHEN** 前一个 operation 占据active slot，而新的accepted operation仍停留在planned
- **THEN** 新subscriber或重启后的subscriber可从durable admitted事件发现该ID及planned snapshot

#### Scenario: 恢复动作产生后继 capability
- **WHEN** 一个tokenized recovery action完成并产生新的resume、rollback或finalize动作
- **THEN** completed action与完整后继动作列表在同一durable recoveryConverged事件中可replay，且后继expected sequence等于该事件sequence

#### Scenario: 慢 Subscriber 缓冲溢出
- **WHEN** subscriber 消费速度不足导致 AsyncStream yield 被丢弃
- **THEN** 该 stream 明确结束，bridge 重新订阅并从 durable watermark/snapshot恢复，而不是继续使用缺事件的投影

### Requirement: 状态机只允许规范转换
Operation SHALL 使用 `planned`、`preflight`、`waitingForDecision`、`staging`、`paused`、`metadata`、`verifying`、`committing`、`committedAwaitingCleanup`、`sourceQuarantining`、`cleaningSource`、`completed`、`completedWithSkips`、`completedWithSourceRetained`、`cancelled`、`failedRecoverable`、`recoveryRequired`、`cleanupRequired` 和 `rolledBack` 状态。每个顶层 item SHALL 有独立 `OperationItemState`；operation state只是 active item phase与聚合结果。Item完成后 MUST 显式调度下一 item或聚合终态。任何未在设计状态图或规范性Item转换表中声明的转换 MUST 被拒绝并记录 typed invariant error。`cancelled` 只可用于零 committed item且 staging 已确认不存在；已有 receipt 的 stop/cancel/failure MUST 通过 partial flags、item states与可恢复状态准确表达。Tokenized rollback完成后，实际补偿且有durable receipt/effect result的item MUST为`rolledBack`，无receipt且owned staging确认不存在的item MUST为`cancelled`，原receipt/effect ledger不得删除；已补偿receipt不再计入live `hasPartialCommit`，terminal `rolledBack` snapshot MUST报告false。`completedWithSkips`、`completedWithSourceRetained`、`failedRecoverable`、`cleanupRequired`与`rolledBack` MUST按design聚合规则唯一决定，不得由UI猜测。

#### Scenario: 禁止跳过验证提交
- **WHEN** 执行器尝试从 `staging` 直接转到 `committing`
- **THEN** 状态机拒绝转换，operation 不得标记完成

#### Scenario: 终态不可重新执行
- **WHEN** 调用方对 `completed` operation 再次请求 resume
- **THEN** 调用为无副作用的幂等结果或明确非法操作错误，且不得重复写文件

#### Scenario: 多 Item 中途停止
- **WHEN** 前一个 item 已提交且后一个 item 因 `.stop` 或失败不再执行
- **THEN** operation 不得标为普通 cancelled/completed，并在 snapshot 中列出 committed receipt、未执行 items 和可用恢复动作

### Requirement: 决策请求是可持久化数据
冲突和 metadata 降级 SHALL 以带稳定 `DecisionToken`、选项、作用范围和相关身份快照的数据事件表达。Core MUST NOT 直接展示 UI；只有匹配且尚未消费的 token 才可被 resolve。

#### Scenario: 等待冲突决策
- **WHEN** `.ask` policy 在 preflight 发现 destination 冲突
- **THEN** operation 进入 `waitingForDecision` 并发出 typed decision request，最终路径保持原样

#### Scenario: 拒绝过期决策
- **WHEN** destination 已变化或 token 已被消费后再次 resolve
- **THEN** service 拒绝该决策并重新 preflight 或进入可解释失败状态

### Requirement: 暂停与取消具有阶段限定语义
Pause SHALL 只在 staging 数据阶段的安全点生效。Commit 前 cancel MUST 保持最终 destination 原样；只有 staging 已确认不存在时才可进入 `cancelled`，否则进入 `cleanupRequired`/`recoveryRequired`并保留 ownership。Commit 开始后 MUST NOT 中断 commit；destination receipt durable后 MUST 进入可注入的 `committedAwaitingCleanup` safe point。该点收到 cancel时 source保持原路径并终结为 `completedWithSourceRetained`；source quarantine开始后取消不再生效。

#### Scenario: 文件中途取消 copy
- **WHEN** copy 在 staging 数据写入中途收到 cancel
- **THEN** 最终 destination 不出现 partial，source 不变，staging 被清理或准确登记

#### Scenario: commit 后取消 move
- **WHEN** move 的 destination 已提交但 source cleanup 尚未开始时收到 cancel
- **THEN** destination 保留、source 保留，状态为 `completedWithSourceRetained`，UI 不得显示为 move 完成

#### Scenario: Cancel 后 staging 清理失败
- **WHEN** commit前 cancel后 staging因权限、断连或 journal故障无法确认删除
- **THEN** operation进入 cleanupRequired/recoveryRequired，记录 staging identity且 Clear不得删除该记录

#### Scenario: 非法控制命令
- **WHEN** nonthrowing pause/resume/cancel 收到已知 ID 但不允许的 phase
- **THEN** service保持operation/item phase、progress、receipt、terminalFailure与filesystem projection不变，发出该operation下durable `controlRejected` typed event；snapshot的latestSequence随该event前进

#### Scenario: Unknown ID 控制命令
- **WHEN** nonthrowing pause/resume/cancel 收到 journal中不存在的 ID
- **THEN** service无副作用地忽略并记录不带 operation sequence/FK的 transient service diagnostic，不伪造 operation/event

### Requirement: 重试与恢复操作幂等
Resume、retry、rollback 及其他 `RecoveryAction` SHALL 以 journal 与 receipt 作为前置条件并保证 filesystem-effect idempotence。带 `ActionID`/expected sequence 的 recover action SHALL command-idempotent；固定签名 `retry(OperationID)` 不承诺跨新 failure epoch 的 at-most-once，但重复/延迟调用 MUST 通过 effect ledger、identity与 receipt避免二次覆盖、二次 source delete、重复 Trash或 sequence回退。UI SHALL 只在最新 failed snapshot提供 retry并在 attempt active时禁用重复提交。

Commit检查返回`notCommitted`时，Service MUST将其解释为“final effect不存在”而非“staging不存在”，并在同一ActionID下先durable记录、执行及确认`cleanupStaging` effect；cleanup未知或失败时不得把item标为`cancelled`/`skipped`。Receipt已durable而phase projection落后的重启 MUST从每个合法checkpoint仅前推状态，不得再次调用executor staging、metadata或commit effect。

#### Scenario: 重复恢复
- **WHEN** 同一 recover action 因调用方超时被提交两次
- **THEN** 第二次调用返回同一稳定结果或无副作用的已执行结果

#### Scenario: Retry 延迟重复
- **WHEN** 一个无 token 的 retry 调用在 attempt 已开始或已产生 filesystem effect后延迟到达
- **THEN** service可开始/合并安全 attempt，但 effect ledger保证不会再次覆盖已提交 item或删除已清理 source

#### Scenario: Commit 未发生但 staging cleanup 在结果前崩溃
- **WHEN** 多item operation已有先前receipt，当前commit检查为notCommitted，cleanupStaging effect后在result持久化前终止
- **THEN** 重启检查同一effect ID且不重复cleanup；只有completed result durable后当前item才可cancelled/skipped，并且已提交item的rollback/finalize各自只执行一次

#### Scenario: Durable receipt phase projection中断
- **WHEN** commit receipt已durable但item或operation仅落在任一合法中间phase checkpoint
- **THEN** 重启只补齐状态与event projection到terminal，不重放staging、metadata或commit filesystem effect

### Requirement: 错误模型保留故障语义
Core SHALL 至少区分 `sourceChanged`、`destinationChanged`、`permissionDenied`、`noSpace`、`volumeDisconnected`、`unsupportedMetadata`、`verificationMismatch`、`partialCommit`、`journalFailure` 和 `recoveryRequired`。错误 MUST 携带 operation/item/phase、底层 errno 或系统错误的可选诊断，以及安全的后续动作；不得只降级为 Bool、beep 或通用 failed。

#### Scenario: 写满目标卷
- **WHEN** staging write 返回 ENOSPC
- **THEN** operation 暴露 `noSpace`，保留 source 与旧 destination，并且不得映射为 completed

### Requirement: 第一版全局串行执行
第一版 Core SHALL 全局最多运行一个 active operation；每个accepted submit MUST在planned intent的同一durable transaction取得全局`submissionOrdinal`，运行中与重启后均按该ordinal确定队列顺序。并发submit只承诺actor admission形成的durable全序，不承诺调用方task调度先后；decision waiting 不得允许另一个 operation 产生与其冲突的写入。并发调用 snapshot/events/control MUST 保持 actor 隔离和事件顺序。

#### Scenario: 两个并发 submit
- **WHEN** 两个调用方同时提交文件操作
- **THEN** service 为两者分配稳定 ID，并按确定队列顺序一次只执行一个 operation

### Requirement: Sequence reservation 与 snapshot watermark 不混淆
Core SHALL分别维护最后durable event/checkpoint、最后实际emitted event与durable reserved-through上界。Reserved range只用于保证崩溃后不复用sequence，MUST NOT把尚未emitted的reservation上界暴露为snapshot latest watermark。重启后snapshot MAY丢失未checkpoint的transient progress，但新event sequence MUST大于崩溃前reserved-through；decision/recovery expected sequence MUST绑定durable state version。

#### Scenario: Reserve 后在首个 event 前崩溃
- **WHEN** service已durable reserve一段sequence但尚未发出其中任何event即终止
- **THEN** 重启snapshot不把reservation上界伪装成latest event，且下一次分配从旧上界之后开始
