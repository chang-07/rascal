## 0. M0 — OpenSpec 与架构门

- [x] 0.1 使用 OpenSpec 1.6.0 初始化 `spec-driven` 项目并创建 umbrella change `add-transactional-file-operation-core`；记录 Codex 指令目录因沙箱 EPERM 未生成，但 `openspec/config.yaml` 与 change 本体成功。
- [x] 0.2 独立读取当前 Package、FileOps、TransferQueue、FileActionLog、测试/build 脚本并在 design 中分列已验证事实、推断和未知项。
- [x] 0.3 完成四个 capability specs，锁定 request/service/event/snapshot、状态机、metadata/verification、journal/recovery、legacy gate 与 App routing 行为。
- [x] 0.4 完成 architecture design，包含组件/状态/时序/ER 图、接口语义、事务边界、错误模型、文件 allowlist、M1/M2 Go/No-go 与 M1–M4 handoff。
- [x] 0.5 先由四个叶子explorer并行只读审查contract、mutation inventory、验收矩阵与Apple/POSIX/SQLite，再由三个独立reviewer审查数据完整性、接口架构和requirement→task→gate追踪；主Codex处理source quarantine、Replace source disposition、effect ledger、multi-item/replay/SQLite/copyfile等P0/P1。
- [x] 0.6 主 Codex运行 strict validate、status、diff/scope 检查，确认只有 `openspec/**` 改动且所有 artifact complete。
- [x] 0.7 向用户汇报 M0 证据并取得明确批准；批准前不得开始 M1 或修改 `Package.swift`、`Sources/**`、`Tests/**`、`.github/**`、`build.sh`。

## 1. M1 — Core target、领域契约与可注入边界

- [x] 1.1 唯一 writer 在 design 的 M1 allowlist 内新增 `RascalFileOperations` library、unit/integration test targets与 `FileOpsCrashProbe` skeleton；确认 executable 单向依赖 library且 tests不进入发行 product。
- [x] 1.2 在`Core/**`逐项实现design规范性类型附录的public cases/fields/initializers、schema version和token签发校验，并以compile/import scan证明domain只依赖Foundation/Darwin。
- [x] 1.3 实现operation/item双层状态转换器、next-item loop、design规范性item表与聚合规则、precommit staging cleanup收敛、`committedAwaitingCleanup`/`completedWithSkips`/`completedWithSourceRetained`/`rolledBack`、非法转换及known/unknown nonthrowing control差异；用table-driven XCTest覆盖全部边。
- [x] 1.4 定义并注入FileSystemAdapter、OperationJournal、Clock、ID generator、Digest、Failpoint、ServiceDiagnosticSink和专用executor；提供fake/ephemeral测试实现及production `UnavailableOperationJournal` placeholder，使default initializer可编译但只进入safe mode。
- [x] 1.5 实现单active operation actor skeleton、durable submissionOrdinal、actor内原子replay watermark/live注册、pull-based paged replay→bounded buffered-live handoff、progress合并、overflow/drop时stream终止/resync、latest durable/emitted/reserved-through三水位与snapshot folding；证明多subscriber不竞争、长replay不自溢出且重启不复用sequence。
- [x] 1.6 用fake adapter完成全kind cardinality/destination/no-follow overlap、目标名称投影、conflict/metadata decision、precommit cancel+cleanup failure、committed-awaiting-cleanup cancel、pause/resume、retry effect幂等、tokenized recovery和ambiguous recovery测试；retry幂等必须由service读取durable receipt/effect ledger抑制filesystem effect，并以重建executor/service后的测试证明，fake自身Set去重不得作为通过证据。

## 2. M1 — Legacy gate、composition root、build 与 CI

- [x] 2.1 建立机器可读mutation inventory/closed allowlist与正向入口清单，覆盖Foundation/POSIX/Process/系统副作用；每entry含分类/file/symbol/primitive/gate/milestone，静态扫描对未知、消失或误分类均失败。
- [x] 2.2 实现release永久禁用、debug仅精确env=1启用的`LegacyWriteCapability`，并在FileOps/TransferQueue/FileActionLog Undo/Redo/FolderSync/Batch Rename/Archive/SFTP/QuickActions/AppUninstaller/permanent-delete精确symbol做执行层guard；真实File Provider lane建立前，所有TransferQueue legacy move在release/default-debug关闭；same-local debug fixture使用exclusive no-replace rename且EEXIST/EXDEV均不fallback；用production-source逐进程probe、backend closed static scan、clean build log+source/diff manifest+App/Mach-O identity+binary SHA和debug legacy App smoke组成三类before/after lane证据，任意可执行文件或独立harness不得单独记pass。
- [x] 2.3 仅在AppDelegate唯一composition root构造service与`@MainActor` bridge skeleton，并单点反馈legacy gate denial，不提前修改/注入window tree；静态测试证明App无第二service构造点或新singleton。
- [x] 2.4 修复 `build.sh` 无本地证书时的 pipefail路径，显式只构建FinderTwo product、支持独立scratch、禁止任取stale binary或吞掉codesign错误，并在隔离证书查询失败场景以codesign verify/details证明ad-hoc签名与 app bundle组装。
- [x] 2.5 建立macOS CI fast lane workflow与本地等价脚本，绑定本次build产物执行default-debug拒绝、隔离debug legacy兼容、release拒绝、Swift tests、boundary scan、605/0 smoke和GUI结构检查；把design中的每个M1 scenario ID映射到真实lane/test evidence并逐项计算PASS/FAIL/NOT-EVALUATED，禁止按`local_required`常量直接写PASS；按`FT-0001`…`FT-0605`运行顺序生成manifest，只规范化明确测量值并保留阈值/语义ID，独立硬断言summary后冻结label/ID manifest SHA。
- [x] 2.6 主Codex先用独立scratch串行运行M1本地scenario manifest，证据记录HEAD/status-v2/diff与untracked content SHA/build hash；任何mandatory skip、shared cache或未绑定binary均失败。
  - 2026-07-22 本地闭环：`m1-fast/20260722T140006Z-43141` 的 `lane.exit=0`；79个精确Swift测试、21条结构化事件、Core/build、605/0 smoke、GUI 0 failure、debug/default/release gate及全部负控通过。`M1-CI-001`仍按2.7保留为远端未评估。
- [ ] 2.7 本地门通过后，主Codex向用户单独申请commit/push测试分支以触发GitHub macOS workflow；未授权时M1标记blocked，不把本地结果当M1-CI-001 pass或skip。
- [ ] 2.8 获得授权后运行并核验真实GitHub macOS workflow、上传可归因evidence；随后停止writer并行完成数据完整性、接口/并发、测试充分性reviewer与verifier，问题由原writer在allowlist内返工。
- [ ] 2.9 主Codex依据本地+远端真实结果判M1 Go/No-go；触发Core/AppKit耦合或4/6 UI owner结构性重写时新增ADR并停止，其他情况下向用户汇报并等待批准M2。

## 3. M2 — Native Copy 内核

- [ ] 3.1 在M2 allowlist内实现directory-FD anchored resolution、versioned composite identity、目标case/Unicode名称投影，并把capability拆为不可降级Safety与copy-only可降级Fidelity；Safety unknown时写入禁用。
- [ ] 3.2 实现显式 tree traversal与错误传播、symlink no-follow、package顶层单元、hard-link identity map和 sparse inventory；禁止把枚举失败当空目录。
- [ ] 3.3 实现 target-volume exclusive staging、基于 `copyfile` family/fcopyfile 的 data+metadata copy、线程安全 progress/pause/cancel callback与 exclusive rename commit；禁止 COPYFILE_MOVE/UNLINK/SKIP并暂禁 clone shortcut。
- [ ] 3.4 实现逐字段finder-compatible metadata manifest/apply/verify，覆盖mode、mtime、birth/added time、FinderInfo/tags、xattr、resource fork、ACL、BSD flags、symlink metadata、hardlink/sparse；只有Fidelity缺口可portable decision，move保持不可降级。
- [ ] 3.5 实现 structural verification及可选 SHA-256/canonical tree manifest，所有 verification mismatch均阻止 commit并登记 staging。
- [ ] 3.6 实现commit前取消、mid-file/mid-tree pause/cancel和staging cleanup/登记；只有staging确认不存在才cancelled，否则cleanupRequired/recoveryRequired；compile/test证明copy无source mutation接口。
- [ ] 3.7 建立按path/call/byte注入enumerate/read/write/metadata/commit错误的fault tests，覆盖ENOSPC、EACCES、destination/source race、相同basename、case/Unicode碰撞、keepBoth race和每个safe point。

## 4. M2 — Copy 入口切换与硬门

- [ ] 4.1 建立两个UUID不同的真实APFS fixture与metadata manifest工具，逐字段覆盖M2-META-001全部metadata及file/tree/package、symlink/hard-link/sparse、同/跨卷、真实ENOSPC。
- [ ] 4.2 完成`@MainActor` internal-copy bridge的decision/progress/error/resync/refresh流程；Core无UI类型、一次submit一个ID、replace/merge unavailable，release UI仍禁用。
- [ ] 4.3 在internal/debug gate迁移paste-copy、list/icon drag-copy、pane-to-pane、Drop Stack copy与duplicate；移除`FileManager.copyItem`、旧TransferQueue和silent fallback，不启用release主干。
- [ ] 4.4 建立正向入口 trace + primitive静态扫描，证明常用 copy入口总数未缩水且每个只进入新 service。
- [ ] 4.5 按M2-PERF-001固定protocol关闭clone、各1次预热+至少7次交替随机轮次，运行Rascal与`/bin/cp` 1GiB benchmark，记录每次/median/p95/cache限制及idle→peak RSS；median≥70%、RSS≤64MiB。
- [ ] 4.6 主Codex按stable scenario IDs重跑全部Unit/Fault/Volume/UI/static/performance/build/smoke/GUI，并单独验证M2-RELEASE-DISABLED-001；M2 mandatory不得skip，case-sensitive/ExFAT以deferred-disabled三重证据验收。
- [ ] 4.7 停止 writer后并行完成 metadata/数据完整性、接口/并发、测试假阳性 reviewer与独立 verifier，返工仍由原 writer完成。
- [ ] 4.8 主 Codex按入口旁路、final partial、metadata丢失与 4/6 UI owner规则判 M2 Go/No-go；No-go时新增 ADR重评同仓库扩大重写/新仓库，Go时向用户汇报并等待批准 M3。

## 5. M3 — SQLite Journal 与恢复基础

- [ ] 5.1 在M3 allowlist内实现journal目录process-exclusive advisory lock、owner epoch、单actor-owned SQLite connection，逐连接验证WAL/foreign_keys/FULL并记录版本；schema含operations/items/summary receipts/1:N effects/events/attempts/recovery actions与migration，并把default live journal factory从M1 unavailable placeholder显式接线到SQLite。
- [ ] 5.2 实现append-only intent/pre-effect/effect-result/summary receipt协议、durable event与sequence reservation，以及29/30/31天、99/100/101终态/unresolved混排保留和pending-safe Clear。
- [ ] 5.3 把sqlite/wal/shm作为恢复集合，启动运行migration/integrity/foreign-key检查；无法枚举operations或取得owner lock时进入service-wide只读safe mode且不自动删除任何对象。
- [ ] 5.4 为每个destructive effect实现intent后/effect前、effect返回后/receipt前、receipt durable后/下一effect前三个稳定ACK；CrashProbe driver收到精确ACK后才SIGKILL，每场景独立journal/sandbox。
- [ ] 5.5 用Unit/Fault/process tests覆盖journal open/write/fsync/migration/retention/corruption、event replay、tokenized action幂等、retry effect幂等、second-process lock拒绝、owner SIGKILL后接管和旧epoch action拒绝。

## 6. M3 — Move、Replace 与 Crash Matrix

- [ ] 6.1 实现每个 regular file SHA-256 + canonical tree manifest，跨卷 move无条件提升 effective policy且调用方不可降低。
- [ ] 6.2 实现跨卷move的staged copy→metadata→verify→commit→durable receipt→`committedAwaitingCleanup`→source同卷exclusive quarantine→manifest purge顺序，并禁止COPYFILE_MOVE。
- [ ] 6.3 实现barrier cancel的`completedWithSourceRetained`、quarantine intent/result/identity receipt、node-level purge ledger、unexpected child保护、cleanupRequired和幂等cleanup retry；无法安全quarantine时禁用directory/package move。
- [ ] 6.4 实现同卷move/rename相同journal/receipt/error契约，以及Replace同卷staging、operation-owned recovery area和逐effect backup/commit；standalone/copy replace保留source，move replace receipt后才quarantine。
- [ ] 6.5 实现snapshot签发的resume/rollback/restore backup/finalize commit/discard known staging/retain source actions；ActionID+expectedSequence command幂等，固定retry只承诺effect幂等，identity不唯一只提供人工recoveryRequired。
- [ ] 6.6 建立move/replace deterministic fault tests，覆盖journal、backup、rename/commit、committed-awaiting-cleanup cancel、source quarantine竞态、node purge、source/destination mutation和重复action。
- [ ] 6.7 对backup、commit、source quarantine、每个node purge等destructive effect的三ACK窗口逐一SIGKILL/restart；逐场景断言final永不partial、Replace至少一个完整old/new副本、Move purge阶段destination完整，且重复恢复无二次effect。
- [ ] 6.8 确认 M3 正式 UI move/replace仍禁用；Core tests通过不得提前打开写能力。
- [ ] 6.9 主Codex按M3-JRN/CORRUPT/MOVE/CLEAN/REPLACE/CRASH/UI-DISABLED stable IDs运行全部Unit/Fault/Volume/Crash/static/build兼容门，独立reviewers审查filesystem predicates后判Go/No-go并等待用户批准M4。

## 7. M4 — Copy/Move/Replace 主干切换

- [ ] 7.1 唯一 writer在 M4 allowlist内把 `FileOps` 收窄为只提交新 service的 UI facade，并为 copy/move/replace移除所有 legacy fallback与双写。
- [ ] 7.2 把 Transfer Activity改为稳定 OperationID/itemID/event/snapshot控制，显示 typed decision/error/recovery/partial/source-retained状态，不按 mutable snapshot下标 cancel。
- [ ] 7.3 统一同卷 rename/move与跨卷 move的 receipt/error/recovery UI，并只在 committed receipt后刷新受影响目录。
- [ ] 7.4 让旧streamed copy、Replace pre-trash和旧跨卷source mutation失去全部调用入口；旧TransferQueue不再执行任何用户数据mutation。
- [ ] 7.5 运行入口正向清单、mutation allowlist和 single-engine动态 trace，证明一次用户动作仅一个 ID、一个 engine submission、一个 final commit且 legacy adapter调用为零。
- [ ] 7.6 增加 UI bridge integration tests，覆盖 release/debug gate、conflict/metadata decision、精确错误、recovery action、ID cancel和目录刷新；保留现有 GUI脚本仅作结构兼容。
- [ ] 7.7 主Codex重跑Swift tests、M2 fault/volume/performance、M3 effect-window crash、build、三类legacy gate lane、`605 passed, 0 failed`及冻结assertion manifest、GUI与静态门；任一mandatory skip/failure或ID语义偷换均阻止切换。
- [ ] 7.8 停止 writer后并行完成数据完整性、接口/并发、测试充分性 reviewer与独立 verifier；主 Codex处理全部 P0/P1并复跑受影响 lane。
- [ ] 7.9 只有三个 P0关闭、单 engine与全部 mandatory证据通过后才宣布 M4完成、结束 upstream冻结并批量只读评估上游；向用户汇报并等待是否另行授权 sync/archive。

> M5–M8 不属于本 checklist。它们必须分别新建 `unify-merge-trash-undo`、`harden-sync-batch-and-metadata-operations`、`harden-archive-remote-and-destructive-tools`、`establish-file-operation-release-gates`，不得在本 change 内顺手实施。
