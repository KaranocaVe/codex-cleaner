# 清理与恢复边界 / Cleanup and Recovery Boundaries

## 清理会做什么

清理审阅窗口展示最终目标范围。选择“包含后代”时，后代会话也会列入清单。执行前，应用会重新检查目标数据库记录、rollout 路径及文件引用关系。

应用把所选会话引用的 `sessions/` 或 `archived_sessions/` 下 `.jsonl` / `.jsonl.zst` 文件移动到同一 Codex 目录下的 `Trash/CodexCleaner/<batch>/`，并写入 `manifest.json`，记录文件来源和目标。然后在 SQLite 事务中清理五个相关库中的会话、父子关系、历史、日志、目标、队列和读取游标。与本次目标无关的既有孤立条目不在清理范围内。

## 可恢复性

- **不创建数据库备份。** 事务提交后的数据库索引删除无法通过本应用撤销。
- 暂存目录保留 rollout 文件，但文件本身不能重建已删除的数据库条目，也不构成完整会话恢复方案。
- 文件只在同一磁盘内移动到 Trash，不会因此释放文件占用的磁盘空间。数据库也不会自动 `VACUUM`。
- 在数据库事务失败时，应用会尝试回滚并将已搬移文件放回原位置；恢复也失败时会保留 manifest 供诊断。跨多个 WAL 数据库的提交无法保证断电时全局原子。
- 正在运行的 Codex 会话可能继续写库。可识别当前 `CODEX_THREAD_ID` 时，应用会拒绝清理该会话；Finder 启动时通常没有该环境变量，因此不能保证识别全部运行中的会话。清理前应停止相关会话。

## 内容预览

预览在打开时才读取 rollout，并在关闭时取消读取。默认最多扫描解压后的 32 MiB、展示 200 条用户或助手正文，每行最多处理 8 MiB。工具调用、工具输出、reasoning 和元数据不显示；达到限制时搜索只覆盖已经加载的正文。压缩 `.jsonl.zst` 需要系统 PATH 中可用的 `zstd` 命令；没有安装时，压缩文件仍可被清理，但无法预览。

## 操作建议

清理前先停止相关会话，检查审阅清单是否包括预期的父会话和后代，并确认你接受数据库不备份、提交后无法撤销以及移动文件仍占空间这些限制。不要把真实数据库、rollout、清理 manifest 或未脱敏日志发布到 issue、PR 或截图中。

---

## English summary

Cleanup moves selected `.jsonl` / `.jsonl.zst` rollout files into `Trash/CodexCleaner/<batch>/` on the same disk and records the mapping in `manifest.json`. It then removes related records from five SQLite databases. No database backup is created, and committed index deletions cannot be undone in the app. Retained rollout files are not a full database restore. Moving files to Trash does not free disk space; databases are not automatically vacuumed. A failed operation attempts database rollback and file restoration, but multiple WAL database commits are not globally atomic across a power failure. Stop relevant sessions and review the final scope before confirming.

Conversation preview reads on demand and is bounded to 32 MiB of decompressed input, 200 displayed messages, and 8 MiB per line. Search only covers loaded content. Compressed rollout preview requires an installed `zstd` command.
