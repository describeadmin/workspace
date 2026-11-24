# describeadmin 工作空间 · Claude Code

从工作空间根目录开始。先读[共用业务约定](.workspace/CONVENTIONS.md)。
后端和前端是两个独立的 Git 仓库，目录名取自
`.workspace/workspace.env` 的 `BACKEND_DIR` 和 `FRONTEND_DIR`。

按任务使用 `.claude/skills/` 中的技能，也可以直接读取对应的 `SKILL.md`。

| 任务 | 技能 |
|---|---|
| 隔离开发、验收、合并或清理需求 worktree | [describe](.claude/skills/describe/SKILL.md) |
| 启动、查看或停止本地开发环境 | [dev-env](.claude/skills/dev-env/SKILL.md) |
| 执行验收并生成报告 | [acceptance-test](.claude/skills/acceptance-test/SKILL.md) |
| 从 YAML spec 生成业务模块 | [codegen](.claude/skills/codegen/SKILL.md) |
| 联动前后端仓库的分支操作 | [git-sync](.claude/skills/git-sync/SKILL.md) |

从工作空间根目录运行技能命令，例如 `.claude/skills/dev-env/dev.sh dev status`。
Claude Code 的工具和权限使用自己的客户端配置。项目约定、脚本、配置和运行状态在 `.workspace/`。
