---
name: describe
description: Run a describeadmin feature end to end in an isolated dual git-worktree sandbox — take a requirement plus reference materials (PRD / reference code / images / docs), scaffold the worktree, produce a plan for the user to confirm, then autonomously implement, run the full backend + frontend tests, and (if the frontend changed) run a visual test, stopping at a "ready to merge" report. Also handles the follow-up: merging a reviewed feature branch back into both repos and cleaning up the worktree, or discarding an abandoned one. Use when the user describes a feature or change to build, or says to merge / land / clean up a describe worktree.
---

# describe：需求 → 独立 worktree → 计划确认 → 自主开发 → 测试 → 待合并

一条剧本，把 `dev-env`、`visual-test` 和 Claude Code 原生的计划/自主循环串起来。
**本 skill 不写任何测试运行时**——测试就是直接调 `mvn` / `pnpm` / `visual-test`。

机械活（建/摘 worktree、拷 `.claude/`、合并回 base）交给同目录的 `describe.sh`；
判断活（拆需求、写代码、决定测什么、看报告下结论）是你的事。

## 三个入口

| 用户说什么 | 走哪条 |
|---|---|
| 描述一个要做的需求/改动，可能附 PRD、参考代码、图、文档 | **A. 新需求开发** |
| 「帮我合并 `<slug>`」「报告没问题，合了吧」 | **B. 集成** |
| 「`<slug>` 不要了」「删掉这个 worktree」 | **C. 放弃** |

前置：本机有 git / mvn / pnpm / docker；`.claude/workspace.env` 存在（`init-workspace.sh`
会写好）。可视化测试还需要 chrome-devtools MCP 可用——不可用时如实在报告里标注
「可视化测试未执行」，不要静默跳过。

---

## A. 新需求开发

### A1. 归纳 slug

从需求提炼一个短横线命名（`^[a-z][a-z0-9-]*$`），如 `order-export`、`user-tag`。
用户已经给了名字就用用户的。这个 slug 贯穿分支名、worktree 目录、场景文件。

### A2. 建 worktree 工作区

```bash
.claude/skills/describe/describe.sh new <slug> [--base <branch>] [--init-repos]
```

- 不带 `--base`：两个子仓各自探测 base（`origin/HEAD` → 本地 `main` → 本地 `master` → 当前分支）。
  子仓还不是 git 仓库时脚本会拦下并给出 `git init` 指引；确认要它代做就加 `--init-repos`。
- 产出 `<workspace>/.worktrees/<slug>/`：两个子仓的 worktree（都在 `describe/<slug>` 分支）
  + 一份 `.claude/` + `CLAUDE.md` + `inputs/` + `notes/`。
- 脚本会打印这个 worktree 专属的后端/前端端口和 DB schema（与主工作区不冲突）。

**之后所有读写都在 `<workspace>/.worktrees/<slug>/` 里做。** 需求范围如果在计划阶段大变，
`describe.sh clean <slug>` 掉重来即可，worktree 很廉价。

### A3. 收集输入

把用户给的 PRD / 参考代码 / 图片 / 文档放进 `.worktrees/<slug>/inputs/`（或记下路径）。
逐一读：图片和 PDF 直接 `Read`。参考代码只读、不照抄——本项目是平台/SDK，薄代码继承基类。

### A4. 写计划

写到 `.worktrees/<slug>/notes/PLAN.md`，至少覆盖：

- **需求理解**：一句话目标 + 验收标准（能观察到什么就算做完）
- **受影响面**：后端模块 / 前端页面 / 要不要写 `codegen-specs/<模块>.yaml`
- **数据库改动**：列出新增 / 改动的表、字段、索引。生成器产出的 `schema-*.sql` / `menu-*.sql` 要登记进后端的 `spring.sql.init`，否则重启后表不建——接口报错但错误信息不指向这里。SQL 语法按项目自己的数据库版本写，框架不做限制
- **权限点**：`<模块>:<对象>:<动作>`，动作只有 `list`/`add`/`edit`/`remove`；新模块要同时登记 `menu-*.sql` 并授权
- **`data-testid` 清单**：每个关键交互元素一条，格式 `<模块>-<对象>-<动作>`
- **测试方案**：后端要新增哪些 `*Test.java`；前端 typecheck/build；要不要可视化测试、测哪条流程
- **base 分支**：`describe.sh new` 输出里两个子仓分别从哪个分支切的，抄进来

### A5. 确认闸（唯一的人工闸）

把 PLAN.md 的要点呈现给用户等他确认——用 plan mode（`EnterPlanMode` / `ExitPlanMode`），
或直接 `AskUserQuestion`。中途有歧义随时 `AskUserQuestion` 追问。**用户确认前不写实现代码。**

### A6. 自主实现

确认后按计划做，全程在 worktree 里：

- 优先走 codegen：写 `codegen-specs/<模块>.yaml` → 跑生成 → 把新增的 `schema-*.sql` /
  `menu-*.sql` 登记进后端的 `spring.sql.init` → 重启后端验证表和菜单出现
- 手写代码继承 `BaseEntity` / `BaseMapper` / `BaseService` / `BaseController`，审计字段不重复定义
- Controller 返回 `Result<T>`，异常交全局处理器
- 前端交互元素带 `data-testid`；要用 Tailwind 工具类覆盖 Element Plus 组件自带的 `width`/`color` 等属性时必须加 `!` 前缀（`!w-48` 而不是 `w-48`）——Element Plus 的 CSS 未分层，裸工具类无论特异度都压不过它

### A7. 跑测试

```bash
# 后端：archetype 的 surefire 已包含 *Test.java / *Tests.java / *IT.java，一条命令跑全部
cd <workspace>/.worktrees/<slug>/<BACKEND_DIR> && mvn -q test

# 前端：仅当前端有改动（git -C <FRONTEND_DIR> status --porcelain 非空）
cd <workspace>/.worktrees/<slug>/<FRONTEND_DIR> && pnpm install && pnpm typecheck && pnpm build
```

断言要比对**具体值**，不要只比对行数——字符集配错时 `COUNT(*)` 完全正常但中文全写成乱码，只比行数发现不了。

### A8. 可视化测试（仅当动了前端）

```bash
cd <workspace>/.worktrees/<slug>
.claude/skills/dev-env/dev.sh dev up
.claude/skills/dev-env/dev.sh dev wait --timeout 600   # 首次要下依赖+建表，给足时间
```

- 新模块：先按 `visual-test` skill 的 Spec 格式写
  `<FRONTEND_DIR>/testing/scenarios/<slug>.yaml`（选择器一律 `[data-testid="..."]`）
- 调 `visual-test` skill 跑这个场景（以及其它受影响的既有场景），产出带截图 + DB 断言的报告
- 跑完 `.claude/skills/dev-env/dev.sh dev down` —— 自己起的服务自己关

任一断言失败 = 阻塞结论，如实写进 REPORT.md，不要「页面看起来正常」就放行。

### A9. 提交 + 报告

在 `describe/<slug>` 分支上，两个子仓各自 `git add -A && git commit`（提交信息说清做了什么）。
**不 push、不 merge。**

写 `.worktrees/<slug>/notes/REPORT.md`：

- 改动清单（哪些文件、为什么）
- 后端测试输出（原样贴关键行：`Tests run: X, Failures: 0`）
- 前端 typecheck / build 结果
- 可视化测试结论 + 截图路径（或「未执行」+ 原因）
- 两个子仓各自的 commit hash
- **给用户的下一步**：验证无误回一句「合并 `<slug>`」；或「`<slug>` 不要了」放弃

### A10. 交回用户

告诉用户报告在 `.worktrees/<slug>/notes/REPORT.md`，worktree 原地留着等他验证。

---

## B. 集成（用户验证报告无误后）

```bash
.claude/skills/describe/describe.sh land <slug>
```

脚本做的事：两个子仓主工作目录必须干净 → 各自 `git checkout <base>` +
`git merge --no-ff describe/<slug>` → 全成功则自动清理 worktree + 删分支 →
若子仓有 remote，打印（不执行）`git push` 命令。

- **冲突**：脚本停在冲突的那个仓并报告，另一个仓不动。把冲突如实告诉用户，
  等他解决（`git add -A && git commit`）后重跑 `describe.sh land <slug>`（已合并的仓会被跳过）。
- 合并后**不自动 push**。把脚本打印的 push 命令转达给用户，由他决定。

---

## C. 放弃

```bash
.claude/skills/describe/describe.sh clean <slug> [--force]
```

停服务 → 摘两个 worktree → 删 `describe/<slug>` 分支 → 删 `.worktrees/<slug>/`。
worktree 里有未提交的**已跟踪**改动时，不加 `--force` 会拒绝执行（防止误删没提交的工作）。

---

## 约定

- 分支名固定 `describe/<slug>`，两个子仓同名
- 不在 `.worktrees/*` 里再跑 `describe.sh new`（脚本自检拦下）
- worktree 的 dev-env 隔离靠「工作区绝对路径 hash」，是 `dev-env` 既有机制，`describe` 不碰它
- `describe.sh` 只做 git 管道 + 文件拷贝；想加「辅助脚本」先想清楚是不是真需要（大概率不需要）
