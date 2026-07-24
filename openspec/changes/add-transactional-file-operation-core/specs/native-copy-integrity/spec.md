## ADDED Requirements

### Requirement: Copy 只能写 staging 后独占提交
Copy SHALL 在 destination 所在卷创建不可见或明确保留的 staging 对象，完成数据、metadata 与验证后才通过 exclusive rename/commit 暴露最终路径。普通失败或 commit 前取消 MUST NOT 创建或改变最终 destination；destination race MUST 返回冲突或 `destinationChanged`，不得覆盖。

#### Scenario: 写入中途失败
- **WHEN** fault adapter 在普通文件中部写入处失败
- **THEN** final path 不存在或保持原内容，partial 只存在于已清理或已登记的 staging

#### Scenario: 提交时名称被抢占
- **WHEN** preflight 后另一个进程创建了相同 destination
- **THEN** exclusive commit 失败并报告 destination 变化，不得覆盖新对象

### Requirement: Copy 不具备删除 source 的权限
Copy kind 的执行 capability SHALL 不提供 source delete。任何 copy 成功、失败、取消、retry 或 recovery 路径 MUST 保持 source 对象和内容不变。

#### Scenario: Copy 完成
- **WHEN** copy 通过验证并提交 destination
- **THEN** source 仍存在且身份和内容未被 Core 修改

### Requirement: 目录遍历传播全部枚举错误
Core SHALL 自行遍历 tree，且 MUST 传播根目录和任意子目录的 enumerate/stat/read 错误。空数组不得代表枚举失败；只有被完整枚举并成功处理的 tree 才可进入 metadata/verification。

#### Scenario: 子目录无读取权限
- **WHEN** 第 N 个子目录枚举返回 EACCES
- **THEN** tree copy 失败，最终 destination 不提交，且不得把缺失子树当作成功

### Requirement: 对象语义按 capability 保留
Symlink SHALL 默认复制链接本身而不跟随 target；package SHALL 作为一个顶层提交单元；hard-link topology SHALL 通过 source identity map 保留；sparse data SHALL 在 adapter 声明支持时保留。目标不支持 hard link 或其他 finder-compatible 语义时，copy MUST 请求显式 portable 降级，move MUST 在相应 capability 中阻止。

#### Scenario: 符号链接复制
- **WHEN** source 是指向文件、目录或不存在目标的 symlink
- **THEN** destination 仍是 link text 相同的 symlink，Core 不读取链接目标作为替代

#### Scenario: Package 复制失败
- **WHEN** `.app` package 内部某 item 复制失败
- **THEN** final path 不得出现可见半包

#### Scenario: Hard-link 降级
- **WHEN** source tree 含 hard-link topology 而 destination adapter 不支持保留
- **THEN** finder-compatible copy 停在 decision；未明确确认 portable 前不得继续

### Requirement: Finder metadata 采用显式 capability 与策略
`.finderCompatible` SHALL 检测并尝试保留目标支持的 POSIX mode、mtime/creation/added time、xattr、FinderInfo/tags、resource fork、ACL、BSD flags、symlink metadata及其他已声明 fidelity字段。Capability probe MUST 区分 unsupported 与 transient failure。`.portable` 只可由用户确认的 copy decision产生；move不得通过 portable降级后删除 source。

#### Scenario: 目标不支持 xattr
- **WHEN** destination volume 明确不支持 source 所需 xattr
- **THEN** copy 显示字段级降级清单并等待确认，move 直接阻止

#### Scenario: Metadata 写入暂时失败
- **WHEN** adapter 声明支持 ACL 但 apply 返回 EPERM
- **THEN** operation 失败为 typed error，而不得将其误报为 unsupported 并静默降级

### Requirement: Copy 验证策略不可被实现弱化
Copy 默认 SHALL 使用 `.structural` 验证，至少验证字节数、对象类型/身份语义和 metadata policy 声明字段；调用方可显式选择 `.sha256`。Verification failure MUST 阻止 commit。验证策略和结果 MUST 进入 snapshot、event 与 receipt。

#### Scenario: 字节数相同但 SHA-256 不同
- **WHEN** `.sha256` copy 的 staging 内容与 source 大小相同但 digest 不同
- **THEN** operation 返回 `verificationMismatch`，final path 不提交

### Requirement: 关键阶段重验证文件身份
Core SHALL 在 preflight、commit 前以及适用时的 source cleanup 前重新核对 source/destination volume identity、opaque file identity、对象类型、size、mtime 与 ctime。任何影响语义的变化 MUST 停止并返回 `sourceChanged` 或 `destinationChanged`。

Preflight完成全部source/tree、destination parent、safety与fidelity检查后，adapter MUST签发按operation/item绑定的进程内receipt；executor在创建staging前 MUST消费并逐字段重验该receipt。Preflight与executor plan之间替换source或destination parent不得沿用旧能力结论。Receipt中的destination parent stable identity MUST作为plan、staging、verification与commit的同一授权基线，verification不得重新采纳当前路径对象。Staging root的创建必须先打开并`fstat` parent FD，证明其仍匹配receipt；创建对象的ownership identity必须来自创建所用FD或同一anchored parent FD的`fstatat`，不得在创建后重新按URL采纳另一个对象。

Commit MUST先打开并`fstat`授权parent FD，再通过该同一FD核对staging root identity，最后使用同一FD执行exclusive rename；不得在path authorization与打开rename parent FD之间留下可提交同名替换对象的窗口。最后一个可注入fault/cancel checkpoint MUST位于最终`fstatat`之前，最终identity read与`renameatx_np`之间不得再有await、callback或path重新解析。Staging ownership MUST同时记录创建时的destination parent stable identity；只有directory-FD anchored检查证明原parent identity/volume未变且原parent下stage entry确实不存在时，才可清除ownership登记。自动cleanup必须通过匹配已登记parent/node identity的anchored FD逐节点删除，并在每个`unlinkat`前使用同一parent FD作最后一次`fstatat`；每个node的最后fault checkpoint必须发生在该`fstatat`之前，二者之间不得再有callback或path解析；不得在完成校验后转用`FileManager`路径递归删除。Parent被rename/recreate、旧parent URL不存在或stage随parent移动时 MUST保留登记并返回`recoveryRequired`，不得把旧URL的`ENOENT`解释为cleanup完成。

#### Scenario: 复制期间 source 被替换
- **WHEN** source path 在 staging 后指向不同文件身份
- **THEN** Core 不提交 destination，并返回 `sourceChanged`

#### Scenario: Preflight 后 destination parent 被替换
- **WHEN** preflight receipt签发后、executor plan前destination parent被rename并由新目录占据旧路径
- **THEN** executor拒绝旧receipt，不创建或提交final，并返回typed destination变化

#### Scenario: Plan 后 destination parent 被替换
- **WHEN** executor plan已消费receipt、但staging root尚未创建时destination parent被rename并由新目录占据旧路径
- **THEN** staging创建所用parent FD不匹配receipt，operation返回`destinationChanged`且不得在新旧parent提交final

#### Scenario: Commit authorization 后 parent 被替换
- **WHEN** commit准备期间destination parent路径被替换，且替换parent包含同名staging entry
- **THEN** authorization只接受同一已打开parent FD中的已验证staging identity；不得提交替换parent中的同名对象

#### Scenario: 最终 rename checkpoint 的 staging 被替换
- **WHEN** commit完成manifest authorization后、最终exclusive rename前的最后可注入checkpoint替换同一parent下的staging entry
- **THEN** 紧邻rename的anchored identity read拒绝替换对象，final path保持不存在且替换对象不得被当作operation-owned自动删除

#### Scenario: Staging 随 parent 被移动
- **WHEN** operation-owned staging已创建后destination parent连同staging被rename，旧URL随后不存在
- **THEN** cleanup不得清除ownership登记；snapshot保持明确pending recovery且不得删除新parent中的无关对象

#### Scenario: Cleanup 最后检查后 staging 被替换
- **WHEN** cleanup即将删除某个已登记staging node时该目录项被替换
- **THEN** anchored identity recheck失败并进入`recoveryRequired`；实现不得递归删除替换对象

### Requirement: Native adapter 使用公开系统能力并保守处理未知
普通文件 adapter SHALL 使用系统 `copyfile` family 的 data/metadata、no-follow、sparse与进度/退出回调能力，并以 directory-FD anchored resolution、exclusive staging open和capability-verified exclusive rename编排竞态边界；目录遍历、hard-link map和commit SHALL由 Core显式编排。所有staging mutation（包括directory/symlink metadata、symlink创建与creation-time写入）MUST解析到已验证的parent/object FD；不得在验证anchored FD后退回destination URL执行`copyfile`或`setattrlist`。Capability MUST拆为不可降级的 safety（operation-owned staging、no-follow resolution、race-free commit、identity recheck、journal ownership）与可降级的 fidelity（metadata、hard-link/sparse preservation）。Safety unknown/unsupported时 copy与move都阻止；只有 fidelity缺口可由 copy portable decision批准。实现 MUST NOT使用 `COPYFILE_MOVE`、`COPYFILE_UNLINK`，也不得把 callback `COPYFILE_SKIP`当作成功取消。Clone shortcut在进度/取消语义单独验证前 MUST保持禁用。

Copyfile callback收到`COPYFILE_ERR` stage时 MUST终止该syscall，不得返回continue形成错误重试；终止前 MUST保存callback线程看到的原始errno。若QUIT使外层`fcopyfile`返回`ECANCELED`，executor MUST优先使用已保存errno映射typed failure并记录native evidence。

#### Scenario: 未验证的目标文件系统
- **WHEN** adapter 无法可靠判断目标是否支持 race-free exclusive commit或identity recheck
- **THEN** copy与move都阻止，用户不得通过 portable metadata decision绕过 safety capability

#### Scenario: Sparse 静默展开
- **WHEN** 系统复制保留字节内容但 destination allocated blocks 表明 sparse holes 已展开
- **THEN** operation 不得将 sparse 标为 preserved，而应按 metadata/capability policy 处理降级

#### Scenario: APFS 数据写入真实耗尽
- **WHEN** preflight已通过后目标APFS可用块被并发耗尽，production `fcopyfile`进入error callback且原始errno为`ENOSPC`
- **THEN** callback终止而不重试，operation返回`failedRecoverable/noSpace`、记录原始`ENOSPC`并清理或登记staging，final path保持不变

### Requirement: Native copy 垂直切片覆盖所有常用 copy 入口
M2精确debug gate启用后，paste-copy、list drag-copy、icon drag-copy、pane-to-pane copy、Drop Stack copy和duplicate SHALL只进入新 service；这些入口 MUST NOT调用 `FileManager.copyItem`、旧 streamed copy或silent legacy fallback。Gate固定为`#if DEBUG`且`RASCAL_ENABLE_M2_NATIVE_COPY=1`，`FT_RUN_TESTS`不自动授权；release始终禁用。M2 volatile journal不提供restart/crash声明，在真实SQLite journal和启动恢复尚未通过前 MUST NOT启用正式 release UI；release主干切换只在M4进行。M2遇到任何 destination冲突 MUST只提供 skip/keepBoth/stop；replace/merge option保持 featureDisabled直到M3 replacement crash matrix通过。

冻结M1 compatibility smoke若仍需执行legacy copy，MAY使用不可由normal UI到达的headless fixture，但必须由`TestRunner.runAll`持有进程内compatibility lease，且创建lease时同时精确设置`RASCAL_ENABLE_LEGACY_WRITES=1`、`FT_M1_LEGACY_COPY_COMPATIBILITY=1`、`FT_HEADLESS_TESTING=1`与`FT_RUN_TESTS=1`。环境变量本身不得授权；缺少任一条件、normal UI、M2 route probe及release均 MUST fail closed；该fixture不得被计为M2入口或能力。

#### Scenario: 新 Core copy 失败
- **WHEN** 已迁移入口提交的新 Core copy 失败
- **THEN** UI 显示该 operation 的 typed error，不得改走旧 TransferQueue

#### Scenario: M2 Copy 遇到 Replace 冲突
- **WHEN** internal M2 copy发现已存在 destination
- **THEN** decision不提供 replace/merge；旧目标不变且不得调用 legacy pre-trash

### Requirement: Copy 性能证据与功能门分离
1 GiB APFS 顺序 copy 基准 SHALL 在预热后报告 median 与 p95；median 吞吐目标不得低于同机 `/bin/cp` 的 70%，每个 active operation 额外内存目标不得超过 64 MiB。性能不达标 SHALL 阻止 M2 Go，但单次时延不得混入功能 smoke 的 correctness 断言。

#### Scenario: 性能基准波动
- **WHEN** 一次样本慢于目标但预热后 median/p95 已记录
- **THEN** gate 按预先定义的聚合指标判定，而不是按单次 20ms 阈值随机失败
