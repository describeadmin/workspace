---
name: git-sync
description: 当用户要求对前后端两个仓库一起查看分支状态、新建、切换或删除分支，或一起提交、推送、拉取时使用。比较两仓当前分支，并根据各仓的改动分别准备提交信息。
---

# git-sync

先读取工作空间根目录下的 [共用流程](../../../.workspace/skills/git-sync/WORKFLOW.md)。

从主工作空间根目录调用 `.agent/skills/git-sync/git-sync.sh`，按共用流程选择子命令。提交信息分别根据两仓各自的 diff 编写。
