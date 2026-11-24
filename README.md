# describeadmin/workspace

![Describe Admin](./assets/logo-text.svg)

业务方的工作空间初始化器：一条命令生成后端工程 + 前端工程 + AI 工作目录
（`CLAUDE.md` + `.claude/skills/`）。这是**业务方唯一需要接触的"元信息"仓库**——
框架团队自己的元仓库是 `describeadmin/docs`，两者受众不同，不要混。

## 给使用者看的入口

```bash
curl -fsSL https://raw.githubusercontent.com/describeadmin/workspace/main/init-workspace.sh \
  | bash -s -- <workspace-name>
```

使用说明见文档站的 [用 AI 工作空间开发](https://describeadmin.github.io/docs/guide/ai-workspace)，
参数见 [脚手架参数](https://describeadmin.github.io/docs/reference/scaffolding#ai-工作空间-init-workspace-sh)。
生成出来的 `<workspace-name>/CLAUDE.md` 是给 AI 读的约定说明。

## 仓库结构 == 生成物结构

`init-workspace.sh` 只把本仓库的 `CLAUDE.md` 与 `.claude/` 原样复制到生成出来的工作空间根目录；
`README.md`、`init-workspace.sh`、`LICENSE` / `NOTICE` 与 git 配置文件留在本仓库：

```
workspace/                  （本仓库）          <workspace-name>/         （生成物）
├── README.md                （不复制，纯仓库自述）
├── init-workspace.sh          （不复制，就是它自己在跑）
├── CLAUDE.md                ───────────────▶  CLAUDE.md
└── .claude/                 ───────────────▶  .claude/
    └── skills/
        ├── dev-env/
        ├── acceptance-test/
        ├── describe/
        ├── codegen/
        └── git-sync/
```

改这个仓库时按这个心智模型想："我现在改的东西，最终会原样出现在业务方的工作空间里"。

## 新增一个 skill

1. `.claude/skills/<name>/SKILL.md`，frontmatter 至少要有 `name`/`description`，
   `description` 决定 AI Agent 什么时候会主动调用它，写清楚触发场景
2. 需要配套脚本就放在同一个目录下（参考 `dev-env/dev.sh`）
3. 更新生成物侧的 `CLAUDE.md`（第 4 节）加一句指路
4. 在这份 README 补一行简介

## 与 `docs`/`framework`/`create-app`/`archetype` 的关系

- `describeadmin-archetype`（`framework` 仓的 module）：生成 `<name>-server`
- `@describeadmin/create-app`（`frontend` 仓的 package）：生成 `<name>-web`
- 本仓库：把上面两个生成动作编排到一起，再加上 AI 工作目录——**不重新实现**
  archetype/create-app 已经做的事，只是多加一层入口
- `docs`：框架团队自己的元仓库，与本仓库服务不同受众，互不依赖

## 维护须知

- `dev-env/dev.sh` 的隔离设计（项目级共享容器 vs worktree 级独立进程/schema）
  见该文件头部注释，改动前先读
- `acceptance-test`（前身 `visual-test`）沿用「不写解释器」原则——浏览器操作直接用
  chrome-devtools MCP、DB 断言直接 `mysql`、报告直接写 Markdown，没有配套脚本。
  这条是踩过坑才定下来的，不要复古。与前身的区别：不再维护 YAML 场景格式，验收标准是
  自然语言清单（`describe` 从 `PLAN.md` 传入）；报告落在工作空间根 `reports/<name>/`，
  **不进前后端仓库**
- `describe` 是编排 skill：`describe.sh` 只做「双 worktree 增删 + 拷 `.claude/` + 合并回 base」
  这类机械活，判断类的事全在 `describe/SKILL.md`。它把「工作空间根不是仓库、里面是两个独立
  子仓」这件事按「`init-workspace.sh` 的 worktree 版」处理——见 `describe.sh` 头部注释
- `git-sync` 与 `describe` 互补、不重叠：`git-sync.sh` 只在两个子仓的**主工作目录**做联动分支操作，
  不碰 worktree。铁律是「先预检、后改动」（`push` / `pull` 面对两个独立远程，例外为逐仓报告）；
  提交信息由 AI 读 diff 写，脚本只机械执行——见 `git-sync.sh` 头部注释
- `codegen` skill **没有配套脚本**：生成器是外部 jar，"下载 + 校验 + 缓存到
  `~/.describeadmin/codegen/<版本>/` + `java -jar`" 这套步骤直接写在 `codegen/SKILL.md` 里
  交给 AI 执行。缓存是 per-user、按版本号分目录、跨项目/worktree 共用的，刻意不放进工作空间。
  **codegen 版本号与框架一致**——默认按业务后端 `pom.xml` 的 `<describeadmin.version>`
  取同号 jar；`workspace.env` 的 `CODEGEN_VERSION` 可临时覆盖
- `init-workspace.sh` 的 archetype 版本查询依赖 Maven Central 的
  `maven-metadata.xml` 是最新的——这与 `CLAUDE.md`（框架团队那份）的"版本核查纪律"
  是同一原则
