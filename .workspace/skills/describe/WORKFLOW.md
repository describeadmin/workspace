# describe：需求 → 独立 worktree → 计划确认 → 自主开发 → 测试 → 待合并

一条剧本，把 `dev-env`、`acceptance-test` 和 AI 客户端的计划确认与开发流程串起来。
**本 skill 不写任何测试运行时**——测试就是直接调 `mvn` / `pnpm` / `acceptance-test`。

机械活（建/摘 worktree、拷贝 AI 入口、合并回 base）交给同目录的 `describe.sh`；
判断活（拆需求、写代码、决定测什么、看报告下结论）是你的事。

## 使用条件

用户明确要求使用 `describe`、在 Git worktree 中开发，或合并或清理已有的 `describe` worktree 时，才进入本流程。其余任务默认跳过。如果判断本次任务更适合在 worktree 中开发，可以先询问用户是否使用 `describe`，得到明确确认后再开始。否则不要使用该技能。

## 三个入口

| 用户说什么 | 走哪条 |
|---|---|
| 「用 describe 做这个需求」「用 worktree 开发这个需求」 | **A. 新需求开发** |
| 明确要求合并已有的 describe worktree，如「这个 worktree 的报告没问题，合了吧」 | **B. 集成** |
| 明确要求清理已有的 describe worktree，如「删掉这个需求 worktree」 | **C. 放弃** |

前置条件是本机有 git、mvn、pnpm 和 docker，且已生成 `.workspace/workspace.env`。
需要可视化验证时使用当前可用的浏览器工具。工具不可用时，验收报告会记录未执行的项目及原因。

客户端没有技能调用功能时，可以直接阅读并执行对应的共用流程。

- [业务模块生成](../codegen/WORKFLOW.md)
- [功能验收](../acceptance-test/WORKFLOW.md)

---

## A. 新需求开发

### A1. 归纳 slug

从需求提炼一个短横线命名（`^[a-z][a-z0-9-]*$`），如 `order-export`、`user-tag`。
用户已经给了名字就用用户的。这个 slug 贯穿分支名、worktree 目录、场景文件。

### A2. 建 worktree 工作区

```bash
.workspace/skills/describe/describe.sh new <slug> [--base <branch>] [--init-repos]
```

- 不带 `--base`：两个子仓各自探测 base（`origin/HEAD` → 本地 `main` → 本地 `master` → 当前分支）。
  子仓还不是 git 仓库时脚本会拦下并给出 `git init` 指引；确认要它代做就加 `--init-repos`。
- 产出 `<workspace>/.worktrees/<slug>/`：两个子仓的 worktree（都在 `describe/<slug>` 分支）
  + 公共项目配置和已有的客户端入口 + `inputs/` + `notes/`。
- 脚本会打印这个 worktree 专属的后端/前端端口和 DB schema（与主工作区不冲突）。

**之后所有读写都在 `<workspace>/.worktrees/<slug>/` 里做。** 需求范围如果在计划阶段大变，
`describe.sh clean <slug>` 掉重来即可，worktree 很廉价。

### A3. 收集输入

把用户给的 PRD / 参考代码 / 图片 / 文档放进 `.worktrees/<slug>/inputs/`（或记下路径）。
逐一用当前客户端可用的工具阅读图片、PDF 和其他参考材料。参考代码只读、不照抄——本项目基于 describeadmin 框架，
业务代码继承框架基类保持"薄"，照搬参考实现常把该留在基类的通用逻辑重复进业务层。

### A4. 写计划

写到 `.worktrees/<slug>/notes/PLAN.md`，至少覆盖：

- **需求理解**：一句话目标
- **验收清单**：逐条「能观察到什么现象就算这次做对了」（自然语言）——A8 原样交给 `acceptance-test` 当验收标准
- **受影响面**：后端模块 / 前端页面 / 要不要写 `codegen-specs/<模块>.yaml`
- **数据库改动**：列出新增 / 改动的表、字段、索引。数据库变更写成 `db/changelog/app/<yyyyMMddHHmm>__<描述>.sql`（codegen 自动产出建表 + 菜单），重启由框架迁移层执行，不需要登记；已执行过的建表 changeset 不能改，加列 / 改列另起文件写 ALTER。SQL 语法按项目自己的数据库版本写，框架不做限制
- **权限点**：沿用项目已有的命名方式（两段式 `<module>:<动作>` 或三段式 `<模块>:<对象>:<动作>`，后者在 spec 里写 `permPrefix`），通用动作是 `list`/`add`/`edit`/`remove`；新模块的菜单 changeset 里同时登记并授权（codegen 已生成；挂哪个目录用 spec 的 `menu.parent`，与权限点无关）
- **`data-testid` 清单**：每个关键交互元素一条，格式 `<模块>-<对象>-<动作>`
- **测试方案**：后端要新增哪些 `*Test.java`；前端 typecheck/build；**要不要可视化验证**（写明结论 + 理由，判据见[验收流程](../acceptance-test/WORKFLOW.md)）、测哪条流程
- **base 分支**：`describe.sh new` 输出里两个子仓分别从哪个分支切的，抄进来

### A5. 确认闸（唯一的人工闸）

把 PLAN.md 的要点呈现给用户，使用当前客户端的计划模式、提问工具或对话等待确认。
中途有歧义就向用户追问。**用户确认前不写实现代码。**

### A6. 自主实现

确认后按计划做，全程在 worktree 里：

- 优先走 codegen：调 `codegen` skill（写 `codegen-specs/<模块>.yaml` → 备好 jar → 生成）→
  重启后端验证表和菜单出现（changelog 由框架迁移层自动执行，不需要登记）
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

### A8. 验收测试 + 报告

功能实现完、A7 的后端/前端测试跑完后，起环境并调 `acceptance-test` skill 收尾。

```bash
cd <workspace>/.worktrees/<slug>
.workspace/skills/dev-env/dev.sh dev up
.workspace/skills/dev-env/dev.sh dev wait --timeout 600   # 首次要下依赖+建表，给足时间
```

调 `acceptance-test`，传入：

- **改动摘要** + **改了哪些文件**（A6 做的事，含每处为什么）
- **验收清单**：A4 PLAN.md 里那份，原样传
- **输出目录**：`<workspace>/.worktrees/<slug>/reports/<slug>/`
- **A7 的测试输出**：后端 `mvn test` 关键行、前端 typecheck/build 结果，一并给它，省得重跑

`acceptance-test` 按[验收流程](../acceptance-test/WORKFLOW.md)判断要不要做可视化验证，并产出
`reports/<slug>/REPORT.html` + `images/`。跑完 `.workspace/skills/dev-env/dev.sh dev down`——
自己起的服务自己关。

任一断言失败 = 阻塞结论，`acceptance-test` 会如实写进报告，不要「页面看起来正常」就放行。

### A9. 提交

在 `describe/<slug>` 分支上，两个子仓各自 `git add -A && git commit`（提交信息说清做了什么）。
**不 push、不 merge。** 两个子仓各自的 commit hash 补进 A8 产出的 `reports/<slug>/REPORT.html`。

报告已经是 A8 的产物——涵盖改动清单、后端测试输出、前端 typecheck/build、可视化验证结论 + 截图，
不再单独写 `notes/REPORT.md`。只在报告结尾补一句给用户的下一步：验证无误回「合并 `<slug>`」；
或「`<slug>` 不要了」放弃。

### A10. 交回用户

链接 `.worktrees/<slug>/reports/<slug>/REPORT.html`，供用户在浏览器打开，worktree 原地留着等他验证。

---

## B. 集成（用户验证报告无误后）

```bash
.workspace/skills/describe/describe.sh land <slug>
```

脚本做的事：两个子仓主工作目录必须干净 → 各自 `git checkout <base>` +
`git merge --no-ff describe/<slug>` → 全成功则把 worktree 里的 `reports/<slug>/` 复制到
主工作空间根的 `reports/<slug>/`（报告留存）→ 自动清理 worktree + 删分支 →
若子仓有 remote，打印（不执行）`git push` 命令。

- **冲突**：脚本停在冲突的那个仓并报告，另一个仓不动。把冲突如实告诉用户，
  等他解决（`git add -A && git commit`）后重跑 `describe.sh land <slug>`（已合并的仓会被跳过）。
- 合并后**不自动 push**。把脚本打印的 push 命令转达给用户，由他决定。

---

## C. 放弃

```bash
.workspace/skills/describe/describe.sh clean <slug> [--force]
```

停服务 → 摘两个 worktree → 删 `describe/<slug>` 分支 → 删 `.worktrees/<slug>/`（`reports/<slug>/`
随之一起没，放弃的需求不留报告）。worktree 里有未提交的**已跟踪**改动时，不加 `--force`
会拒绝执行（防止误删没提交的工作）。

---

## 约定

- 分支名固定 `describe/<slug>`，两个子仓同名
- 不在 `.worktrees/*` 里再跑 `describe.sh new`（脚本自检拦下）
- 验收报告由 `acceptance-test` 产在 worktree 的 `reports/<slug>/`；`land` 时复制到主工作空间根，`clean`（放弃）时随 worktree 一起删
- worktree 的 dev-env 隔离靠「工作区绝对路径 hash」，是 `dev-env` 既有机制，`describe` 不碰它
- `describe.sh` 只做 git 管道 + 文件拷贝；想加「辅助脚本」先想清楚是不是真需要（大概率不需要）
