## ADDED Requirements

### Requirement: Legacy 高风险写入默认禁用
Release构建 SHALL禁用全部TransferQueue legacy move、Replace、Merge、FolderSync、Batch Rename以及inventory列为同级高危的file Undo/Redo、permanent delete、Archive/SFTP write、in-place QuickAction和AppUninstaller；这是在真实File Provider lane缺失时对same-local启发式分类的保守处理。Debug构建也 SHALL默认禁用，只有进程显式设置 `RASCAL_ENABLE_LEGACY_WRITES=1`时才可进入登记的隔离legacy调试路径；未登记或未gate的direct mutation MUST使静态门失败。兼容验收 MUST分为default-debug拒绝、debug legacy fixture和release即使env=1仍拒绝三条独立lane。Legacy same-local debug fixture SHALL使用exclusive no-replace rename，destination已存在、跨卷或权限错误时 MUST保留source与旧destination并禁止copy/delete fallback。

#### Scenario: Release 环境变量绕过
- **WHEN** release build 设置 `RASCAL_ENABLE_LEGACY_WRITES=1`
- **THEN** 高风险 legacy 写入仍保持禁用

#### Scenario: Debug 默认行为
- **WHEN** debug build 未设置该变量
- **THEN** 高风险命令不可执行，并向 UI 返回明确 unavailable reason

#### Scenario: Gate Lane 绑定真实构建
- **WHEN** M1以独立进程运行production gate source的debug/release probe
- **THEN** 只有在backend首个mutation前guard的closed static scan、clean build log与source/diff manifest、本次FinderTwo App/Mach-O identity与binary SHA、debug legacy App compatibility smoke同时归因成功时，才可把三条lane记为当前构建的gate证据；任意可执行文件或独立harness本身不得冒充App backend动态证明

#### Scenario: Same-local destination race
- **WHEN** legacy debug fixture在revalidation后、rename前创建同名destination
- **THEN** exclusive rename返回已存在，source与竞态destination内容均保持不变，且不得调用copy/delete fallback

#### Scenario: Undo/Redo 跨卷旁路
- **WHEN** release或default-debug执行closure-based file Undo/Redo
- **THEN** `FileActionLog`中央执行gate在任何closure mutation前拒绝；只有隔离debug legacy fixture可显式opt in，M5之前不得宣称该Undo可恢复

#### Scenario: 隔离 Legacy 兼容 Lane
- **WHEN** debug compatibility smoke在临时fixture显式设置env=1
- **THEN** 只有allowlist内legacy测试可运行；该lane不得被解释为release能力已启用

### Requirement: 用户数据写入口有静态 inventory 与 allowlist
M1 SHALL 建立 production source mutation inventory，并将用户内容 mutation、app-state persistence 与 external/non-undoable side effect 分栏。静态扫描 MUST 只允许 adapter、明确 app-state 边界和已登记 external action 使用破坏性 FileManager/POSIX/system-process API；每个例外 MUST 有 owner、里程碑和理由。

#### Scenario: UI 新增 direct copyItem
- **WHEN** controller 在 allowlist 外新增 `FileManager.copyItem`
- **THEN** CI/static gate 失败，即使 build 与 smoke 通过

### Requirement: App 只有一个 composition root 和 MainActor bridge
App SHALL 在一个 composition root 创建/注入 `FileOperationService`，且 MUST 不新增 service singleton。一个 `@MainActor` bridge SHALL 消费 operation events，驱动 Transfer Activity、decision/recovery UI 和目录刷新；Core 不得反向引用 App 类型。

#### Scenario: 两个窗口观察同一 operation
- **WHEN** UI 多处需要显示同一 transfer
- **THEN** 它们通过 bridge 的稳定 operation snapshot/event 状态更新，而不是各自持有执行器或 closure

### Requirement: 一次用户操作只能进入一个 engine
M4 切换后，`FileOps` MAY 暂作为 UI facade，但 SHALL 只向新 service 提交。旧 `TransferQueue` MUST 不再执行用户数据写入；新 service 失败时 MUST 暴露错误并保持危险能力禁用，不得 silent fallback 到 legacy engine 或双写。

#### Scenario: Core 返回 unsupportedMetadata
- **WHEN** UI 发起已迁移 move 且 Core 阻止 metadata 降级
- **THEN** UI 展示阻止原因，不调用旧跨卷 move

### Requirement: Transfer Activity 使用稳定 operation ID 控制
Activity UI SHALL 以 operation ID 与 item ID 显示进度，并使用 ID 调用 pause/resume/cancel/retry/recover。它 MUST NOT 通过 mutable snapshot 数组下标定位操作；typed error、decision 与 recovery action MUST 可逐项显示。

#### Scenario: 已完成行被清除
- **WHEN** Activity 清除一个终态 operation 后取消另一个 operation
- **THEN** cancel 仍命中正确稳定 ID，而不受数组下标变化影响

### Requirement: M1 以纯 Core 边界作为 Go/No-go
M1 Go SHALL 同时满足：`Core/**` domain 只依赖 Foundation/Darwin，native/journal/digest adapter只额外依赖系统 SQLite3/CommonCrypto且无第三方 runtime；标准 tests不启动 App；fake adapter可走完 plan、decision、cancel、retry、recovery；App只有一个 composition root；`swift test`、build、legacy smoke/gui与静态 gate通过。若 Core必须导入 AppKit/旧 `FileOps`/UI，或简单 dry-run需要结构性重写六个核心 UI状态所有者中的四个以上，M1 MUST No-go并停止生产实现，先新增 ADR。

#### Scenario: Core 复用旧 merge UI
- **WHEN** M1 实现需要引用 `FileOps.mergeDirectory` 或 `FileListController`
- **THEN** M1 判 No-go，不得继续 M2

### Requirement: M2 以完整 Copy 垂直切片作为 Go/No-go
M2 Go SHALL要求所有mandatory fault、同卷与真实跨卷APFS、metadata、取消、竞态和性能证据通过，final path无partial，常用copy入口无旁路。M2只授权internal/debug vertical slice，正式release copy保持禁用直到M3 durable journal和M4主干切换通过。若窄适配需要结构性重写AppDelegate、BrowserWindow、PanesContainer、Pane、FileList、DirectoryModel中四个以上，或任一入口仍可回退legacy，M2 MUST No-go并重新评估新仓库。

#### Scenario: Mandatory volume case 被跳过
- **WHEN** M2 gate 把真实跨卷 APFS 标为 skipped
- **THEN** M2 gate 失败，safe copy 不得在正式构建启用

### Requirement: M4 关闭三条 P0 路径后才能启用主干
M4 Go SHALL同时证明：旧streamed copy无调用入口、Replace不再预删/预Trash目标、跨卷move不在SHA-256/commit前改变source路径；一次操作只进入一个engine；旧TransferQueue不写用户数据；build、Swift tests、fault/crash tests、605项smoke、GUI与旁路扫描全部通过。M1 SHALL冻结605个assertion label/ID manifest及其SHA；M4迁移旧TransferQueue断言时保留稳定ID和安全语义，禁止删一项再用无关断言补足计数。

#### Scenario: 兼容 smoke 只有 604 项通过
- **WHEN** M4 smoketest 报告任一 failure 或未执行完整 605 项
- **THEN** M4 gate 失败，不得宣布主干切换完成

### Requirement: 未验证平台能力保持禁用
任何当前里程碑 mandatory 场景被 skip SHALL 判 gate 失败。未建立真实 SMB、File Provider/iCloud、外置卷或相应 capability lane 时，相关写能力 MUST 保持禁用；unit fake 或同卷 temp directory 不得替代发布声明。

#### Scenario: File Provider 只有 fake 测试
- **WHEN** fake provider contract 通过但没有真实 signed provider/iCloud lane
- **THEN** release UI 不得启用或宣称支持该写能力

### Requirement: 验证证据可归因且与工作区状态绑定
主 Codex SHALL将每个验证运行记录到忽略目录 `.build/verification/<HEAD>/<lane>/<run-id>/`，至少包含命令、退出码、OS/Xcode/Swift/SQLite、HEAD OID、`git status --porcelain=v2`、staged/unstaged binary diff SHA-256、untracked allowlist路径及内容SHA-256、构建产物SHA-256、seed、卷UUID/格式、scenario manifest与skip清单、before/after manifest、hash/metadata diff、event trace、journal dump及整包证据SHA-256。多个verifier MUST使用独立scratch/build path，GUI验证 MUST串行；只有主Codex可更新OpenSpec task和宣布里程碑完成。

#### Scenario: Reviewer 的缓存测试通过
- **WHEN** subagent 在共享 `.build` 给出无法归因的通过结果
- **THEN** 该结果只作为辅助信息，不得替代主 Codex 的串行真实验收

### Requirement: Mandatory 场景由稳定 ID 清单定义
Design中的milestone verification manifest SHALL为每个场景分配稳定ID、lane、适用里程碑、mandatory/deferred-disabled状态、环境preflight、预期filesystem/event结果和对应task。Mandatory环境缺失或skip MUST失败；deferred平台必须以runtime/UI/trace三重证据保持禁用，不得算作skip或pass。

#### Scenario: ExFAT 在 M2 尚未建立 Lane
- **WHEN** M2 manifest把ExFAT标为M8 deferred-disabled
- **THEN** M2不运行一个伪skip测试，但必须证明ExFAT写能力未启用；到M8该场景转为mandatory后环境缺失即失败

### Requirement: Upstream 与后续范围按里程碑隔离
M0–M4 完成前 SHALL 冻结 upstream merge，仅做只读监控。Merge、Trash/Undo、FolderSync、Batch Rename、Archive、SFTP、destructive tools 与 release cleanup MUST 分别进入 M5–M8 后续 OpenSpec changes，不得暗中扩入本 change。未经单独授权 MUST NOT commit、push、PR、sync/archive、发布或部署。

#### Scenario: M2 发现 Batch Rename 公共接口缺口
- **WHEN** worker 认为需要同时迁移 Batch Rename 才能完成 copy
- **THEN** worker 停止并报告越界，不修改该功能或扩大本 change

#### Scenario: M1 远端 CI 尚未获授权
- **WHEN** M1本地门已通过但用户尚未单独授权commit/push测试分支
- **THEN** M1标记blocked并请求授权，不把本地脚本当作GitHub-hosted CI pass或skip
