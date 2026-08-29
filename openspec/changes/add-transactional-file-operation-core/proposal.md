## Why

Rascal 当前的 copy、跨卷 move、Replace 与相关 undo 路径缺少统一事务边界：失败可能留下最终路径 partial，跨卷 move 在弱验证后删除源，Replace 在新内容就绪前移走旧目标。现有测试和 UI 队列无法对这些数据完整性不变量做确定性、崩溃级验证，因此在继续扩展 Finder 替代能力前，必须先建立可独立测试、可恢复且可审计的文件操作内核。

## What Changes

- 新增无 AppKit 依赖的 `RascalFileOperations` library，以及正式 XCTest、fault integration 和 crash-probe 验证边界；App 只能通过一个 composition root 单向依赖该库。
- 定义稳定 operation/item ID、单调事件序列、typed error、decision token、snapshot，以及可幂等 pause/resume/cancel/retry/recover 的 actor 服务契约。
- 建立以目标卷 staging、显式 metadata capability、结构/SHA-256 验证、exclusive commit 和 source cleanup gate 为核心的 native copy/move/replace 语义。
- 使用系统 SQLite3 持久化 operation、item、receipt 与 append-only event；无法唯一解释的磁盘或 journal 状态进入 `recoveryRequired`，不得猜测后覆盖或删除。
- **BREAKING**：正式构建默认禁用 legacy 跨卷 move、Replace、Merge、FolderSync、Batch Rename及inventory确认的同级高风险写入；debug也只有 `RASCAL_ENABLE_LEGACY_WRITES=1` 才能进入明确登记的隔离旧路径。
- 分 M1–M4 迁移 copy/move/replace：前两个里程碑是可证伪实验；若纯 Core 边界或窄 UI 适配失败，停止实现并以 ADR 重新比较同仓库扩大重写与新仓库重写。
- 冻结 upstream 合并至 M4 通过；不在本 change 内收编 Merge、Trash/Undo、FolderSync、Batch Rename、Archive、SFTP 或其他 M5+ 写入。

## Capabilities

### New Capabilities

- `file-operation-contract`: 定义请求、状态机、事件、错误、决策、取消/暂停与幂等恢复的公共契约及 Core 依赖边界。
- `native-copy-integrity`: 定义 file/tree/package copy 的 staging、metadata、symlink/hard-link/sparse、验证、取消和 exclusive commit 保证。
- `durable-move-replace-recovery`: 定义 journal、receipt、跨卷 move 的 SHA-256/source cleanup gate、Replace backup 与 crash recovery 保证。
- `file-operation-app-routing`: 定义 legacy feature gate、单一 App bridge、稳定 operation ID UI 语义、旁路封禁和 M1–M4 发布门。

### Modified Capabilities

无。仓库初始化前没有 OpenSpec capability；本 change 建立第一组规范。

## Impact

- 预计影响 `Package.swift`、新增 Core/Tests/Integration/CrashProbe target、新 App bridge，以及 M4 的 `FileOps`、`TransferQueue`/Activity 和少量 composition-root 调用点。
- 核心运行时只使用Swift、Foundation、Darwin、系统`copyfile` family、SQLite3与CommonCrypto；macOS最低版本保持13，不引入第三方运行时依赖。M2 copy只在internal/debug gate验证，live journal与M4主干切换前不启用release UI。
- M0 只创建并验证规划 artifacts；用户批准 M0 后才允许修改生产代码。每个后续里程碑仍需主 Codex 实测、独立只读 reviewer 审查并经用户批准。
- M5–M8 必须使用后续独立 OpenSpec changes；本 umbrella change 仅覆盖 M1–M4，且未经单独授权不 sync/archive、commit、push、创建 PR、发布或部署。
