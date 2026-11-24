# describeadmin 业务工作空间

从工作空间根目录开始。后端和前端是两个独立的 Git 仓库，目录名分别由
`.workspace/workspace.env` 中的 `BACKEND_DIR` 和 `FRONTEND_DIR` 指定。
从对应子仓读取本地项目约定，并在对应子仓中执行 Git 操作。

开始修改业务代码前，读取[共用业务约定](.workspace/CONVENTIONS.md)。
新增业务模块使用 `codegen`，业务代码继承框架基类。数据库结构、菜单和字典变更
使用新的 Liquibase changelog 文件。关键前端交互元素须带 `data-testid`。

按任务加载下列 skill 的 `SKILL.md` 并执行其流程。客户端没有自动发现
`.agent/skills/` 时，直接读取表中的文件。

| 任务 | Skill |
|---|---|
| 在独立的前后端 worktree 开发需求、验收、合并或清理 | [describe](.agent/skills/describe/SKILL.md) |
| 启动、查看或停止本地开发环境 | [dev-env](.agent/skills/dev-env/SKILL.md) |
| 跑测试、做浏览器和数据库验收、生成报告 | [acceptance-test](.agent/skills/acceptance-test/SKILL.md) |
| 从 YAML spec 生成业务模块 | [codegen](.agent/skills/codegen/SKILL.md) |
| 联动操作前后端两个仓库的分支 | [git-sync](.agent/skills/git-sync/SKILL.md) |

从工作空间根目录运行命令，例如 `.agent/skills/dev-env/dev.sh dev status`。
工具和权限使用当前客户端自己的配置。项目约定、脚本、配置和运行状态在 `.workspace/`。
`describe` 创建的 worktree 会带上公共文件和当前工作区已有的客户端入口。
