---
name: describe
description: 仅在用户明确要求使用 describe 技能、明确要求在 Git worktree 中开发，或明确要求合并或清理已有的 describe worktree 时使用。如果判断本次任务更适合在 worktree 中开发，可以先询问用户是否使用该技能，得到明确确认后再开始。否则不要使用该技能。在独立的前后端 worktree 中确认计划、实现、测试和验收，交付报告后等待合并确认。
---

# describe

先读取工作空间根目录下的 [共用流程](../../../.workspace/skills/describe/WORKFLOW.md)。

从工作空间根目录调用 `.agent/skills/describe/describe.sh` 的 `new`、`list`、`land` 或 `clean` 子命令。新建后在该 worktree 根目录继续，按共用流程提交计划确认。使用 `.agent/skills/dev-env/dev.sh` 和 Agents 的 `acceptance-test` skill 完成验收。
