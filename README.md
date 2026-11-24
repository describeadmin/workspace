# describeadmin/workspace

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="./assets/logo-text.svg">
  <img alt="Describe Admin" src="./assets/logo-text-light.svg">
</picture>

这是面向 Describe Admin 用户的工作空间初始化工具。一条命令即可生成后端工程、前端工程和 AI 工作目录
（Claude Code 的 `CLAUDE.md` + `.claude/skills/`，以及 Agents 的 `AGENTS.md` + `.agent/skills/`）。

## 快速开始

```bash
curl -fsSL https://raw.githubusercontent.com/describeadmin/workspace/main/init-workspace.sh \
  | bash -s -- <workspace-name>
```

使用说明见文档站的 [用 AI 工作空间开发](https://describeadmin.github.io/docs/guide/ai-workspace)，
参数见 [脚手架参数](https://describeadmin.github.io/docs/reference/scaffolding#ai-工作空间-init-workspace-sh)。
在生成的工作空间根目录启动客户端。Claude Code 从 `CLAUDE.md` 开始，
Agents 从 `AGENTS.md` 开始。客户端没有自动发现 `.agent/skills/` 时，
按 `AGENTS.md` 的索引读取对应的 `SKILL.md`。

## 仓库结构 == 生成物结构

`init-workspace.sh` 默认安装两套 AI 入口和公共文件，并生成 `.workspace/workspace.env`。
从本地检出运行时，客户端入口模板只包含技能声明和命令入口。
`describe` 创建双 worktree 时会复制公共文件，以及主工作区已有的客户端入口。
`README.md`、`init-workspace.sh`、`LICENSE` / `NOTICE` 与 git 配置文件留在本仓库：

```
workspace/                  （本仓库）          <workspace-name>/         （生成物）
├── README.md                （不复制，纯仓库自述）
├── init-workspace.sh          （不复制，就是它自己在跑）
├── CLAUDE.md                ───────────────▶  CLAUDE.md
├── AGENTS.md                ───────────────▶  AGENTS.md
├── .workspace/              ───────────────▶  .workspace/（追加 workspace.env）
│   ├── CONVENTIONS.md
│   └── skills/                                 公共流程与脚本
├── .agent/                  ───────────────▶  .agent/
│   └── skills/                                 └── skills/（五个 Agents 入口）
└── .claude/                 ───────────────▶  .claude/
    └── skills/
        ├── dev-env/
        ├── acceptance-test/
        ├── describe/
        ├── codegen/
        └── git-sync/
```

两套入口各自使用客户端配置，技能都调用 `.workspace/` 里的流程和脚本。
例如 `.agent/skills/dev-env/dev.sh dev status` 和 `.claude/skills/dev-env/dev.sh dev status`
查看的是同一个开发环境。只使用一种客户端时，保留它的入口和 `.workspace/` 即可。
工作区的项目配置在 `.workspace/workspace.env`，每个 worktree 的运行状态在各自的 `.workspace/dev-env/`。

## 升级已有工作空间

1. 使用旧版脚本停止开发服务，处理完现有的 `describe` worktree。
2. 把新版仓库的 `.workspace/CONVENTIONS.md` 和 `.workspace/skills/` 复制到工作空间的 `.workspace/`。
3. 把旧版 `.claude/workspace.env` 的内容迁到 `.workspace/workspace.env`，保留原有项目目录和覆盖值。
   如果目标文件已存在，核对并合入所需值。迁完可把旧配置文件和旧运行日志归档到工作区外。
4. 更新所用客户端的入口文件和随仓库提供的技能文件。已有自定义规则时，合入新版入口里对
   `.workspace/` 的引用，并保留自定义规则及客户端配置。

## 新增一个 skill

1. 把共用流程和配套脚本放在 `.workspace/skills/<name>/`。
2. 在两个客户端目录各添加一个 `SKILL.md`，在 frontmatter 中使用相同的 `name`
   和中文 `description`，写清楚技能做什么、什么时候用，并指向共用流程。
3. 有配套脚本时，两个客户端的命令入口都转发到公共脚本。更新 `CLAUDE.md` 和 `AGENTS.md` 的技能索引。

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
  客户端可用的浏览器自动化工具、DB 断言直接 `mysql`、报告直接写 Markdown，没有配套脚本。
  这条是踩过坑才定下来的，不要复古。与前身的区别：不再维护 YAML 场景格式，验收标准是
  自然语言清单（`describe` 从 `PLAN.md` 传入）；报告落在工作空间根 `reports/<name>/`，
  **不进前后端仓库**
- `describe` 是编排 skill：`describe.sh` 只做「双 worktree 增删 + 拷贝 AI 入口 + 合并回 base」
  这类机械活，判断类的事全在共用的 `describe/WORKFLOW.md`。它把「工作空间根不是仓库、里面是两个独立
  子仓」这件事按「`init-workspace.sh` 的 worktree 版」处理——见 `describe.sh` 头部注释
- `git-sync` 与 `describe` 互补、不重叠：`git-sync.sh` 只在两个子仓的**主工作目录**做联动分支操作，
  不碰 worktree。铁律是「先预检、后改动」（`push` / `pull` 面对两个独立远程，例外为逐仓报告）；
  提交信息由 AI 读 diff 写，脚本只机械执行——见 `git-sync.sh` 头部注释
- `codegen` skill **没有配套脚本**：生成器是外部 jar，"下载 + 校验 + 缓存到
  `~/.describeadmin/codegen/<版本>/` + `java -jar`" 这套步骤直接写在共用的 `codegen/WORKFLOW.md` 里
  交给 AI 执行。缓存是 per-user、按版本号分目录、跨项目/worktree 共用的，刻意不放进工作空间。
  **codegen 版本号与框架一致**——默认按业务后端 `pom.xml` 的 `<describeadmin.version>`
  取同号 jar；`workspace.env` 的 `CODEGEN_VERSION` 可临时覆盖
- `init-workspace.sh` 从 Maven Central 的 `maven-metadata.xml` 读取 archetype 发布版本。
  也可以用 `--archetype-version` 显式指定版本。
