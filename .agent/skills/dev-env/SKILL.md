---
name: dev-env
description: 当用户要求启动、查看或停止本地开发环境，或在多个工作区并行开发时使用。管理前后端服务及共享的 MySQL 和 Redis，并按 Git worktree 隔离端口和数据库。
---

# dev-env

先读取工作空间根目录下的 [共用流程](../../../.workspace/skills/dev-env/WORKFLOW.md)。

从当前工作空间根目录运行 `.agent/skills/dev-env/dev.sh slug`，或用 `dev up`、`dev wait`、`dev status`、`dev logs`、`dev down` 管理服务。两套入口使用同一份配置与运行状态。
