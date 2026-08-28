---
name: dev-env
description: Start, stop, or check the local dev environment for a describeadmin business project (backend + frontend + shared MySQL/Redis), with git-worktree-safe port/schema isolation. Use when asked to start the app, run the backend/frontend locally, check what's running, or set up parallel dev environments across multiple worktrees.
---

# 本地开发环境（worktree 友好）

一条命令拉起/查看/销毁**当前 worktree 专属**的本地开发环境。同一个业务项目的多个
`git worktree` 可以同时各自跑一套后端+前端，互不干扰；MySQL/Redis 用一个常驻的
共享实例，按 worktree 分数据库/index，不用每个 worktree 都起一套重资源容器。

## 用法

```bash
.claude/skills/dev-env/dev.sh slug          # 查看当前工作区算出的隔离参数
.claude/skills/dev-env/dev.sh dev up        # 拉起（幂等，可重复执行）
.claude/skills/dev-env/dev.sh dev status    # 查看运行状态
.claude/skills/dev-env/dev.sh dev wait      # 阻塞到前后端就绪（可加 back|front|all、--timeout 秒）
.claude/skills/dev-env/dev.sh dev logs back # 或 front，跟踪日志
.claude/skills/dev-env/dev.sh dev down      # 停止本 worktree 的应用进程
```

前置条件：`.claude/workspace.env` 存在（`init-workspace.sh` 生成工作空间时会自动写好，
记录后端/前端目录名与项目名）；本机装了 Docker、Maven、pnpm。

## 什么时候用

- 用户说"把项目跑起来"/"起一下开发环境"/"看看后端起来没" → 先 `dev.sh dev status`，
  没在跑就 `dev.sh dev up`
- 用户在另一个 `git worktree` 里问同样的问题 → 同一条命令，脚本会自己算出与主
  worktree 不同的端口/数据库，不会跟已经在跑的那个撞车
- 需要看报错日志 → `dev.sh dev logs back`（后端）或 `front`（前端），不要另外去猜
  日志文件在哪
- 自动化流程里 `dev up` 之后要等环境真正就绪 → `dev.sh dev wait`（阻塞到端口可连接，
  后端还会盯日志的启动完成/失败行）；`describe` 与 `visual-test` 都靠它，不要用 `sleep` 猜时间

## 设计要点（改动这个 skill 前先读）

- MySQL/Redis 容器是**项目级**共享的（容器名/端口只随项目名变化，同一项目的所有
  worktree 连的是同一个实例），后端/前端应用进程与它们的端口是**worktree 级**隔离的
  （只随工作区绝对路径变化）。别把这两层混在一起改
- 不要假设目录名——业务方的项目名各不相同，永远从 `.claude/workspace.env` 读
  `BACKEND_DIR`/`FRONTEND_DIR`/`PROJECT_NAME`
- 本地 MySQL 默认 `mysql:5.7`（对齐框架的兼容基线）。业务方自己的库是 8.x 就在
  `workspace.env` 里加 `DEV_MYSQL_IMAGE=mysql:8.0` 让本地对齐线上——只在首次建共享
  容器时生效，细节见 `dev.sh` 头部注释
- 更多设计理由（为什么用绝对路径 hash 当 slug、为什么 MySQL 用户要显式 GRANT
  这类）见 `dev.sh` 文件头部注释，不要在这里重复
