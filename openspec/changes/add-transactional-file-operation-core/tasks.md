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
- [x] 2.3a 修复用户实测的legacy denial弹窗风暴：AppDelegate反馈非重入、一次进程最多展示一个明确告警，重复或异capability通知不排队；验证合并不改变backend fail-closed gate。
  - 2026-07-23 本地证据：`m1-fast/20260723T023020Z-59830` 的 `lane.exit=0`；presentation gate动态探针要求首次claim成功、后续两次失败，default-debug/debug-legacy/release gate、83个Swift测试、22条事件、605/0 smoke与GUI 0 failure全部通过。
- [x] 2.4 修复 `build.sh` 无本地证书时的 pipefail路径，显式只构建FinderTwo product、支持独立scratch、禁止任取stale binary或吞掉codesign错误，并在隔离证书查询失败场景以codesign verify/details证明ad-hoc签名与 app bundle组装。
- [x] 2.5 建立macOS CI fast lane workflow与本地等价脚本，绑定本次build产物执行default-debug拒绝、隔离debug legacy兼容、release拒绝、Swift tests、boundary scan、605/0 smoke和GUI结构检查；把design中的每个M1 scenario ID映射到真实lane/test evidence并逐项计算PASS/FAIL/NOT-EVALUATED，禁止按`local_required`常量直接写PASS；按`FT-0001`…`FT-0605`运行顺序生成manifest，只规范化明确测量值并保留阈值/语义ID，独立硬断言summary后冻结label/ID manifest SHA。
- [x] 2.6 主Codex先用独立scratch串行运行M1本地scenario manifest，证据记录HEAD/status-v2/diff与untracked content SHA/build hash；任何mandatory skip、shared cache或未绑定binary均失败。
  - 2026-07-22 本地闭环：`m1-fast/20260722T140006Z-43141` 的 `lane.exit=0`；79个精确Swift测试、21条结构化事件、Core/build、605/0 smoke、GUI 0 failure、debug/default/release gate及全部负控通过。`M1-CI-001`仍按2.7保留为远端未评估。
- [x] 2.7 本地门通过后，主Codex向用户单独申请commit/push测试分支以触发GitHub macOS workflow；未授权时M1标记blocked，不把本地结果当M1-CI-001 pass或skip。
  - 2026-07-23 用户明确授权推送到其GitHub；目标固定为`git@github.com:swnb/rascal.git`的`feat/transactional-file-ops-m1`。
- [x] 2.8 获得授权后运行并核验真实GitHub macOS workflow、上传可归因evidence；随后停止writer并行完成数据完整性、接口/并发、测试充分性reviewer与verifier，问题由原writer在allowlist内返工。
  - GitHub Actions run `29974780612`（macOS 15）在精确提交`79c21ac7238ac8b72f1eef223aba718be2d2f0a0`通过；artifact `m1-fast-evidence-29974780612` digest=`sha256:1505f1510c5332630ce0e808dd3c0f2c2f841c44f501bd1db625231a6e7d5fb8`。下载核验`head.txt/head-end.txt`一致、`lane.exit=0`、83/83 Swift、22条事件、605/0 smoke、GUI 0 failure和全部scenario PASS。
- [x] 2.9 主Codex依据本地+远端真实结果判M1 Go/No-go；触发Core/AppKit耦合或4/6 UI owner结构性重写时新增ADR并停止，其他情况下向用户汇报并等待批准M2。
  - M1判定Go：独立数据完整性、接口/并发、测试充分性reviewer与verifier的P0/P1已关闭，Core边界和UI owner阈值未触发No-go；用户已明确授权自主继续所有后续里程碑，因此直接进入M2。

## 3. M2 — Native Copy 内核

- [x] 3.1 在M2 allowlist内实现directory-FD anchored resolution、versioned composite identity、目标case/Unicode名称投影，并把capability拆为不可降级Safety与copy-only可降级Fidelity；Safety unknown时写入禁用。
- [x] 3.2 实现显式 tree traversal与错误传播、symlink no-follow、package顶层单元、hard-link identity map和 sparse inventory；禁止把枚举失败当空目录。
- [x] 3.3 实现 target-volume exclusive staging、基于 `copyfile` family/fcopyfile 的 data+metadata copy、线程安全 progress/pause/cancel callback与 exclusive rename commit；禁止 COPYFILE_MOVE/UNLINK/SKIP并暂禁 clone shortcut。
- [x] 3.4 实现逐字段finder-compatible metadata manifest/apply/verify，覆盖mode、mtime、birth/added time、FinderInfo/tags、xattr、resource fork、ACL、BSD flags、symlink metadata、hardlink/sparse；只有Fidelity缺口可portable decision，move保持不可降级。
- [x] 3.5 实现 structural verification及可选 SHA-256/canonical tree manifest，所有 verification mismatch均阻止 commit并登记 staging。
- [x] 3.6 实现commit前取消、mid-file/mid-tree pause/cancel和staging cleanup/登记；只有staging确认不存在才cancelled，否则cleanupRequired/recoveryRequired；compile/test证明copy无source mutation接口。
- [x] 3.7 建立按path/call/byte注入enumerate/read/write/metadata/commit错误的fault tests，覆盖ENOSPC、EACCES、destination/source race、相同basename、case/Unicode碰撞、keepBoth race和每个safe point。

## 4. M2 — Copy 入口切换与硬门

- [x] 4.1 建立两个UUID不同的真实APFS fixture与metadata manifest工具，逐字段覆盖M2-META-001全部metadata及file/tree/package、symlink/hard-link/sparse、同/跨卷、真实ENOSPC。
- [x] 4.2 完成`@MainActor` internal-copy bridge的decision/progress/error/resync/refresh流程；新增package-internal `VolatileOperationJournal`只承诺当前进程一致性；唯一composition root以显式constructor injection传播，Core无UI类型、一次submit一个ID、replace/merge unavailable，release UI仍使用unavailable graph。
  - 原生bridge错误反馈与legacy denial一样按应用进程合并为一次；12个预期的deferred-volume失败通过显式probe抑制UI但仍保留typed snapshot，避免错误突发形成sheet/modal弹框队列。
- [x] 4.3 在`#if DEBUG && RASCAL_ENABLE_M2_NATIVE_COPY == 1`精确gate迁移paste-copy、list/icon drag-copy、pane-to-pane、Drop Stack copy与duplicate；`FT_RUN_TESTS`不授权，release同名env仍拒绝；移除`FileManager.copyItem`、旧TransferQueue和silent fallback，不启用release主干。
- [x] 4.4 建立正向入口 trace + primitive静态扫描，证明常用 copy入口总数未缩水且每个只进入新 service。
- [x] 4.5 按M2-PERF-001固定protocol关闭clone、各1次预热+至少7次交替随机轮次，运行Rascal与`/bin/cp` 1GiB benchmark，记录每次/median/p95/cache限制及idle→peak RSS；median≥70%、RSS≤64MiB。
- [x] 4.6 主Codex按stable scenario IDs重跑全部Unit/Fault/Volume/UI/static/performance/build/smoke/GUI，并单独验证M2-RELEASE-DISABLED-001；M2 mandatory不得skip，case-sensitive/ExFAT以deferred-disabled三重证据验收。
  - 2026-07-23 精确实现提交`5cdefc887cffb15c5ca9c6a4d7cb1e91f2deb30a`：本地`swift test`为103/103；`m2-ui-smoke/exact-commit`为608/0且六条copy route各一个OperationID、legacy=0；mutation inventory为84 entries/398 matches。
  - `m2-copy-static/exact-commit-absolute`含release动态禁写PASS；`m2-apfs/exact-commit`含双UUID APFS与真实ENOSPC PASS；`m2-deferred-disabled/exact-commit`含case-sensitive APFS/ExFAT runtime+bridge+no-fallback三重PASS；以上均无mandatory skip。
  - `m2-performance/exact-commit`按1次预热+7轮交替测量：Rascal median=2.062815s、`/bin/cp` median=2.349145s、throughput ratio=1.1388、idle→peak RSS=114688 bytes，两个阈值均PASS。
  - GitHub macOS 15 run `29982617683`在同一提交通过；artifact `m1-fast-evidence-29982617683` digest=`sha256:053330df1b58358ca4990612230780cba71e780dba3d5e42b107cbcc7067c653`，下载核验head/head-end一致、lane.exit=0、冻结M1集合83/83、605/0 smoke、GUI 0 failure和全部scenario PASS。
- [x] 4.7 停止 writer后并行完成 metadata/数据完整性、接口/并发、测试假阳性 reviewer与独立 verifier，返工仍由原 writer完成。
  - 2026-07-23 四个独立只读 pass 已完成首轮审查：metadata/数据完整性 reviewer 判 1 个 P0、4 个 P1；接口/并发 reviewer 判 4 个 P1；测试 reviewer 判 7 组 P1；verifier 在独立 scratch 重跑 103/103 Swift tests 与当前 HEAD static scan，并校验既有 APFS/deferred/performance/release/remote artifacts 哈希。现有测试与证据本身通过，但门定义存在漏测，M2 暂定 No-go；本项保留未完成直到下列返工关闭并复审。
  - 返工复审发现总门/真实owner probe/共享证据脚本及M2 progress回归超出原M2 allowlist；主Codex已先修订design纳入这四个精确路径与用途约束，未以测试通过代替scope gate。
- [x] 4.7a 关闭数据完整性 P0/P1：verification后、exclusive commit前重新核对operation-owned staging identity+manifest、source composite identity/tree manifest与destination parent/volume；拒绝stage替换/子节点篡改；cleanup按已验证manifest拒绝unexpected child；补目录child ctime/identity、symlink leaf volume、单选外部hard-link与sparse allocated-block语义。
  - 第三轮只读复审新增 syscall-adjacent P1：receipt parent必须贯穿plan→stage→verify→commit；commit authorization与rename绑定同一parent FD；ownership登记使用创建FD/同一parent FD identity；cleanup逐节点anchored recheck+`unlinkat`，parent URL缺失返回`recoveryRequired`。补plan→stage parent替换、commit同名恶意stage与cleanup替换回归。
  - 最终复审继续定位两个更窄窗口：directory/symlink metadata与creation time不得在anchored parent校验后退回path mutation；commit/cleanup最后可注入checkpoint必须位于紧邻`renameatx_np`/`unlinkat`的`fstatat`之前。主Codex已改为descriptor-only metadata/symlink mutation、补最终stage替换与root/descendant逐node cleanup替换回归，并以同尺寸staging digest篡改证明SHA-256差异由verification返回`verificationMismatch`。
- [x] 4.7b 关闭接口/路由 P1：DecisionToken持久化并重验identity snapshot；修复fast-terminal refresh注册竞态与partial-commit refresh；normal UI的nil/disabled bridge fail closed，legacy copy兼容只允许不可由正常UI到达的双环境隔离M1 fixture；保证terminal后无迟到/倒退progress。
  - 最终复审发现event consumer与post-submit resync可能把旧snapshot晚到回写terminal UI；已按`latestSequence`与terminal dominance合并snapshot，resync保留既有sequence基线，并补旧waiting snapshot在completed后重放、late refresh只执行一次的真实service回归。Normal UI legacy兼容拒绝改为不广播denial，由bridge单一presentation owner显示一次typed unavailable，避免双alert。
- [x] 4.7c 关闭测试/证据 P1：六条真实UI owner入口逐条动态trace；post-verification/pre-rename cancel/source/stage race；按path/call/byte且断言命中的完整fault matrix；same/cross APFS字段级metadata工具；修复perf单次duration/RSS失败语义；所有M2 lane强制release target（适用时）、HEAD/status/diff结束态一致、stable scenario manifest与mandatory skip清单。
  - 第三轮只读复审要求冻结精确binding全集与摘要并逐binding聚合，补metadata前cancel selector；生成M2 event trace/volatile journal dump；父bundle绑定嵌套M1 evidence manifest摘要；signal中止或未finalize时不得写成功`lane.exit`。
  - 主总门实跑暴露release probe在预期unavailable failure上进入`NSAlert.runModal`且无超时；已将release/route/deferred三类headless probe统一禁用bridge alerts，改为独立process group硬超时并直接执行签名bundle binary。失效RUN_ID未生成成功`lane.exit`或scenario结果，显式中止负控生成`lane.exit=130`；修复后release六入口与route-owner探针分别定向通过。
  - 最终复审补充：取消合同缺少metadata后/verification前独立binding；父manifest未直接绑定child manifests；成功lane早于整包hash；wrapper外部signal回收、birth time纳秒与release枚举错误仍不够严格。现已补第五取消selector，且mid-file/mid-tree用被阻塞的真实progress/node callback与命中计数证明取消时点；补父子manifest闭合、hash复验后最后写lane、INT/TERM process-group回收自测、`getattrlist`纳秒birth time和枚举错误fail-closed。
  - 当前工作树独立总门进一步证明M1 mutation hard gate会精确拒绝新增测试写点：M2 fast/partial/stale/unavailable projection fixtures增加5个受控`TestRunner` mutation anchors，已把`MUT-0052`从215校准为220并保持`test-demo`、test-trigger-only与M8 owner边界；不得以跳过M1 gate收口。
  - 后续全量Swift门暴露planned admission测试读取可继续推进的current snapshot而产生`.planned`/`.preflight`时序竞态；已改为读取append-only首个durable admitted event中的snapshot并断言state=`planned`、sequence=1，不再把“提交前已持久化”误写成“当前状态必须停留”。
- [x] 4.7d 原 reviewers 对全部 P0/P1做只读复审，独立 verifier 使用新scratch运行定义好的M2总门；只有findings关闭、当前HEAD归因完整且无mandatory skip才完成4.7。
  - 最终只读review：数据完整性、接口/并发与测试/证据三路均为P0/P1/P2=0；数据完整性独立43/43，路由独立7/7，证据双信号与mutation基线定向复验均通过。
  - 独立verifier RUN_ID `20260723T-independent-final3-r12` 从零运行总门：root/5个child/M1 manifests全部自校验并互相绑定；12/12 mandatory、0 skip、2/2 deferred-disabled、43/43 exact bindings、Swift 127/127、route 7/7、APFS双UUID+真实ENOSPC+六组metadata、perf ratio=0.960867且RSS=131072 bytes、M1 smoke 605/0、GUI 0、selected Swift 84/84、mutation inventory 84 entries/409 matches/MUT-0052=220；HEAD/status/diff/untracked首尾一致。
  - 残余非阻断风险：同一冻结协议曾出现perf ratio 0.6088失败，后续为0.7834/1.1717/3.4238/0.9609通过，说明七轮median仍受系统I/O调度显著影响；失败证据保留，后续release gate应增强benchmark稳定性，不得删除阈值。
- [x] 4.8 主 Codex按入口旁路、final partial、metadata丢失与 4/6 UI owner规则判 M2 Go/No-go；No-go时新增 ADR重评同仓库扩大重写/新仓库，Go时向用户汇报并等待批准 M3。
  - M2判定Go：六个入口无legacy旁路或silent fallback，fault/race/cancel证据未出现final partial，Finder metadata字段级同/跨卷证据无静默丢失；constructor injection保持六个UI owner的窄适配，未触发结构性重写4/6阈值。主Codex在本项后停止，不启动M3，等待用户单独批准。

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
