---
name: codegen
description: 当用户要新增 CRUD 模块、业务表，或已有 YAML 规格需要生成业务模块时使用。生成后端四件套、Liquibase 变更脚本、前端页面和 API 封装。
---

# codegen

先读取工作空间根目录下的 [共用流程](../../../.workspace/skills/codegen/WORKFLOW.md)。

从 `.workspace/workspace.env` 读取子仓目录和可选的版本覆盖，按共用流程确认生成器版本、编写 spec、生成代码并检查 changelog。
