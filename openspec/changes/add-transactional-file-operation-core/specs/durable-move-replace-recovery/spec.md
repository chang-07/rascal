## ADDED Requirements

### Requirement: Journal 在文件副作用前持久化意图
Core SHALL 使用系统 SQLite3 的 WAL、foreign keys 和 `synchronous=FULL` journal，默认路径为 `~/Library/Application Support/Rascal/Operations/operations.sqlite`。RW journal打开前 MUST取得同目录的process-exclusive advisory lock并生成owner epoch；锁失败进入只读safe mode。Journal MUST由单进程、单actor-owned connection独占，禁止并发writer/checkpoint；每次打开连接 MUST查询确认PRAGMA值并记录 `sqlite3_libversion()`。Operations、items、receipts、append-only events及每个filesystem effect的intent/result MUST在对应durable boundary前后以可恢复顺序提交；journal write/fsync failure MUST阻止后续破坏性动作。

#### Scenario: 首次 journal 写失败
- **WHEN** operation intent 无法 durable persist
- **THEN** Core 返回 `journalFailure`，不创建 staging、不改变 destination 且不删除 source

#### Scenario: 提交事件写失败
- **WHEN** destination 已提交但完成事件无法 durable persist
- **THEN** operation 进入 `recoveryRequired` 或 `partialCommit`，不得报告 completed

#### Scenario: WAL 恢复检查
- **WHEN** service 在 crash 后重新打开 journal
- **THEN** 它把 sqlite、wal、shm 作为同一恢复集合，并同时运行 schema migration、integrity check 与 foreign-key check

#### Scenario: 第二进程争用 Journal
- **WHEN** 另一个 Rascal实例或helper尝试以RW打开同一journal而owner lock仍有效
- **THEN** 第二个service进入只读safe mode，不创建第二个active queue、writer或sequence owner

### Requirement: Journal 数据可审计并受保守保留规则约束
Journal SHALL为每个operation保存ID、kind、state、request、latest sequence、owner epoch、时间和terminal error；每个item保存source/destination、opaque identity、state、staging/quarantine URL、进度和verification；单item receipt保存最终summary，1:N append-only effect ledger保存backup、commit、source quarantine和逐节点purge的intent/result/identity；event使用append-only sequence/payload。未完成、`recoveryRequired`、`cleanupRequired`和source-retained pending记录 MUST永不自动清除；普通终态保留30天且最多100个；Clear MUST只删除无pending effect/recovery的终态记录。

#### Scenario: 清理历史记录
- **WHEN** 用户执行 Clear 且 journal 同时含 completed 与 recoveryRequired operations
- **THEN** 只有符合保留规则的终态记录可删除，recoveryRequired 及其 receipts/events 保持完整

### Requirement: Journal 损坏时禁止猜测磁盘状态
SQLite 打开、integrity、schema migration 或记录解码无法给出唯一状态时，Core SHALL 进入 `recoveryRequired` 并禁用自动覆盖、source delete、backup delete 和 staging delete。恢复 UI MUST 给出只读检查和安全动作，不得把未知状态当作未开始或完成。

#### Scenario: 截断 journal
- **WHEN** 测试以截断或不一致记录重启 service
- **THEN** Core 不自动删除任何 source、destination、backup 或 staging，并报告 recoveryRequired

#### Scenario: 无法枚举 Operation
- **WHEN** journal 全局损坏到无法可靠发现 operation IDs
- **THEN** service 进入全局只读 safe mode，拒绝所有新 mutation，而不是构造一个虚假的单 operation 状态

### Requirement: 跨卷 move 强制完整内容验证
跨卷 move SHALL 复用 staged copy，但 verification policy MUST 强制提升为 `.sha256`，调用方不得降低。只有 source/staging SHA-256、结构和 required metadata 验证完成且 destination exclusive commit 持久记录后，Core 才可进入 source cleanup。

#### Scenario: 调用方请求 structural move
- **WHEN** 跨卷 move 请求提供 `.structural`
- **THEN** service 自动提升为 `.sha256` 并在 snapshot/receipt 中记录有效策略

#### Scenario: Digest 不匹配
- **WHEN** 跨卷 move verification 得到不同 digest
- **THEN** destination 不提交、source 不删除，并返回 `verificationMismatch`

### Requirement: Source cleanup 是独立且不可误报的阶段
Destination receipt durable后，cross-volume move SHALL先进入 `committedAwaitingCleanup`。未取消时，Core MUST先写durable quarantine intent，再在source卷以directory-FD/no-follow、exclusive same-volume rename把顶层source移入operation-owned quarantine；effect返回后核对quarantine identity并写receipt。身份不匹配 MUST停止且不得purge。随后按原始manifest逐节点purge，每个 destructive effect有intent/result ledger并在删除前核对identity。任意失败进入 `cleanupRequired`/`recoveryRequired`，可幂等重试但不得映射为completed。无法提供安全quarantine语义的adapter MUST禁用cross-volume directory/package move。

#### Scenario: Source delete 权限失败
- **WHEN** 已提交 move 的 source quarantine rename或后续purge返回EACCES
- **THEN** destination完整，source仍在原路径或已登记quarantine，effect ledger记录精确阶段，状态为cleanupRequired

#### Scenario: Source path 被替换
- **WHEN** identity recheck后、quarantine rename竞态中source path被替换，或quarantine结果identity不符
- **THEN** Core不purge该对象，保留原路径/quarantine现状并进入recoveryRequired

#### Scenario: 目录 Purge 中途崩溃
- **WHEN** 第N个manifest node删除后、effect receipt前进程被SIGKILL
- **THEN** committed destination保持完整；重启只根据node effect ledger与identity继续或进入recoveryRequired，不删除unexpected child

### Requirement: Replace 在新内容就绪前保持旧目标
Replace SHALL是destination commit strategy而不是source disposition。Standalone `kind.replace`定义为source-retaining replacement；`copy + conflictPolicy.replace`永不cleanup source；`move + conflictPolicy.replace`只有durable replacement receipt后才进入source quarantine/cleanup。Replace MUST在destination卷完成新内容staging、metadata和验证后才进入commit，并先把旧目标保存在operation-owned同卷recovery area。若adapter使用backup rename + final rename而非已验证swap，则每个effect分别写intent/identity/result；旧destination在第一个commit effect开始前保持原路径和内容不变。Replace默认采用source metadata。

#### Scenario: Replace 复制失败
- **WHEN** 新内容 staging 或 verification 失败
- **THEN** 旧 destination 仍在原路径且内容不变，不产生虚假的 replace completed

#### Scenario: Replace commit 后崩溃
- **WHEN** 新 destination 已公开但进程在写 terminal event 前被 SIGKILL
- **THEN** 重启后 journal/receipt 能识别新对象和 backup，结果为可恢复状态而非重复替换

#### Scenario: Copy 与 Move 的 Replace Source 语义
- **WHEN** 两个请求分别以copy+replace和move+replace提交相同形状的source/destination
- **THEN** copy完成后source保留；move仅在replacement receipt durable后进入source quarantine，二者不得共享含糊的delete行为

### Requirement: Durable failpoint 的恢复结果有限且可解释
每个 destructive effect SHALL至少有三个稳定ACK failpoint：durable intent后/effect前、effect返回后/receipt前、receipt durable后/下一effect前。SIGKILL后重启，`recoveryRequired`只表示无法自动选择动作，不能豁免filesystem最低不变量：final永不partial；Replace在任何时刻至少有一个identity已验证的完整old/new副本位于final/backup/registered staging；Move quarantine前source与committed destination均完整，quarantine/purge开始后committed destination始终完整。任何silent partial、验证前删源、旧目标提前消失、完整副本全失或错误completed SHALL使该写通道停止启用。

#### Scenario: 每个边界崩溃矩阵
- **WHEN** crash probe 在 plan、staging、data、metadata、verify、backup、commit、source cleanup 与 terminal persist 边界逐一被 SIGKILL
- **THEN** 每个effect的before/after/receipt窗口均满足对应filesystem predicate，并且重复resume/rollback不产生额外覆盖或删除

### Requirement: 同卷 move/rename 使用相同 receipt 和身份校验
同卷 move/rename MAY 使用文件系统原子 rename，但 SHALL 经过同一 request validation、identity recheck、journal、receipt、typed error 和 recovery contract；不得因快捷路径绕过 operation service。

#### Scenario: 同卷 rename 目标竞态
- **WHEN** preflight 后 destination 被另一个进程创建
- **THEN** operation 不覆盖该对象，并返回 destinationChanged/conflict

### Requirement: M3 不提前切换正式 UI
M3 SHALL 实现并验证 journal、move、replace 和 crash recovery，但正式 UI 的 move/replace 写入能力 MUST 保持禁用，直到 M4 的单引擎路由、活动 UI 和旁路扫描全部通过。

#### Scenario: M3 Core 测试通过但 M4 未完成
- **WHEN** 正式构建启动
- **THEN** 用户仍不能通过 UI 进入尚未切换完成的 move/replace 路径
