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

#### Scenario: 复制期间 source 被替换
- **WHEN** source path 在 staging 后指向不同文件身份
- **THEN** Core 不提交 destination，并返回 `sourceChanged`

### Requirement: Native adapter 使用公开系统能力并保守处理未知
普通文件 adapter SHALL 使用系统 `copyfile` family 的 data/metadata、no-follow、sparse与进度/退出回调能力，并以 directory-FD anchored resolution、exclusive staging open和capability-verified exclusive rename编排竞态边界；目录遍历、hard-link map和commit SHALL由 Core显式编排。Capability MUST拆为不可降级的 safety（operation-owned staging、no-follow resolution、race-free commit、identity recheck、journal ownership）与可降级的 fidelity（metadata、hard-link/sparse preservation）。Safety unknown/unsupported时 copy与move都阻止；只有 fidelity缺口可由 copy portable decision批准。实现 MUST NOT使用 `COPYFILE_MOVE`、`COPYFILE_UNLINK`，也不得把 callback `COPYFILE_SKIP`当作成功取消。Clone shortcut在进度/取消语义单独验证前 MUST保持禁用。

#### Scenario: 未验证的目标文件系统
- **WHEN** adapter 无法可靠判断目标是否支持 race-free exclusive commit或identity recheck
- **THEN** copy与move都阻止，用户不得通过 portable metadata decision绕过 safety capability

#### Scenario: Sparse 静默展开
- **WHEN** 系统复制保留字节内容但 destination allocated blocks 表明 sparse holes 已展开
- **THEN** operation 不得将 sparse 标为 preserved，而应按 metadata/capability policy 处理降级

### Requirement: Native copy 垂直切片覆盖所有常用 copy 入口
M2精确debug gate启用后，paste-copy、list drag-copy、icon drag-copy、pane-to-pane copy、Drop Stack copy和duplicate SHALL只进入新 service；这些入口 MUST NOT调用 `FileManager.copyItem`、旧 streamed copy或silent legacy fallback。Gate固定为`#if DEBUG`且`RASCAL_ENABLE_M2_NATIVE_COPY=1`，`FT_RUN_TESTS`不自动授权；release始终禁用。M2 volatile journal不提供restart/crash声明，在真实SQLite journal和启动恢复尚未通过前 MUST NOT启用正式 release UI；release主干切换只在M4进行。M2遇到任何 destination冲突 MUST只提供 skip/keepBoth/stop；replace/merge option保持 featureDisabled直到M3 replacement crash matrix通过。

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
