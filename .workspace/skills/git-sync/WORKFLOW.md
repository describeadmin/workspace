# git-sync：前后端两个仓库的 git 分支联动

工作空间根目录不是 git 仓库，`<name>-server`（后端）和 `<name>-web`（前端）
是两个各自独立的仓库（实际目录名见 `.workspace/workspace.env` 的 `BACKEND_DIR` / `FRONTEND_DIR`）。一个功能常横跨前后端，这个 skill 让分支操作**一条命令作用到两个仓库**，
并盯着两仓的当前分支别跑偏（drift）。

机械活（`add` / `commit` / `branch` / `switch` / `push` / `pull` 的联动执行、预检、drift 检测）
交给同目录的 `git-sync.sh`；判断活（读 diff 写提交信息）是你的事。

**这个 skill 不碰 `git worktree`。** 要建隔离沙箱并行开发用 `describe` skill——它管
`.worktrees/<slug>/` 和 `describe/<slug>` 分支，两者互补、不重叠。

## 用法

```bash
.workspace/skills/git-sync/git-sync.sh status                 # 两仓分支/领先落后/脏文件/最后提交；不一致则告警
.workspace/skills/git-sync/git-sync.sh list                   # 两仓分支合成一张表，标出当前分支与「只在一个仓库存在」的
.workspace/skills/git-sync/git-sync.sh new <branch> [--from <ref>]   # 两仓一起新建并切过去
.workspace/skills/git-sync/git-sync.sh co <branch>            # 两仓一起切到已有分支（别名 switch / checkout）
.workspace/skills/git-sync/git-sync.sh rm <branch> [--force]  # 两仓一起删分支（别名 delete）
.workspace/skills/git-sync/git-sync.sh commit --show          # 逐仓打印 status + diff HEAD，给你读了写提交信息
.workspace/skills/git-sync/git-sync.sh commit --backend-file <p> --frontend-file <p>   # 两仓各 add -A + commit
.workspace/skills/git-sync/git-sync.sh push                   # 两仓当前分支各 push -u origin（对外操作）
.workspace/skills/git-sync/git-sync.sh pull [--no-rebase]     # 两仓各 pull --rebase
```

会改状态的子命令（`new` / `co` / `rm` / `commit` / `push` / `pull`）都支持 `--dry-run`：
只打印将执行的 `git` 命令、不落地。

前置：`.workspace/workspace.env` 存在（`init-workspace.sh` 写好，记录 `BACKEND_DIR` /
`FRONTEND_DIR` / `PROJECT_NAME`）；两个子目录都是有提交的 git 仓库。

## 什么时候用

- 用户说「新建一个分支 dev」「切到 xxx 分支」「删掉 xxx 分支」，且意思是**前后端一起** → 对应
  `new` / `co` / `rm`
- 用户说「提交一下」「帮我 commit」→ 走下面的**提交流程**（你要生成提交信息）
- 用户说「推上去」「拉一下最新」→ `push` / `pull`。`push` 是对外操作，执行前先跟用户确认
- 用户问「两个仓库现在在同一个分支吗」「有没有冲突」→ `status` 或 `list`
- 任何联动命令报「drift」/「只在一个仓库存在」→ 如实转达给用户，别自作主张对齐

## 提交流程（`commit`）

脚本不自己编提交信息，你来写：

1. **看 diff**：`git-sync.sh commit --show` —— 逐仓打印 `git status --porcelain` 和
   `git diff HEAD` 全文。
2. **各写一条，尽量详细**：分别读后端、前端的 diff，各写一条贴合**本仓改动**的提交信息
   （前后端改动通常不是一回事，别硬凑成一条）。格式：

   ```
   <类型>(<scope>): <一句话概括>

   1. <功能点/改动一>：<具体做了什么，必要时说清为什么>
   2. <功能点/改动二>：……
   3. ……
   ```

   - 首行遵循该仓已有 commit 风格（先看 `git -C <仓库> log --oneline -10`；没有既定风格时
     用 `feat(scope): 中文描述` 这种），不超过 ~50 字。
   - 空一行后用 `1. 2. 3. 4.` 逐条罗列这次改动的功能点：改了什么、影响到哪个模块/文件、
     不显然的取舍写清缘由。一个「功能点」而非「一个文件」为一条——同一功能点跨多文件就合成一条。
   - 宁可多列几条也别糊成一句；琐碎的连带改动（跟着重命名、import 调整）可并进相关条目或末条。
   - 多行信息写进 scratchpad 文件（`commit-backend.txt` / `commit-frontend.txt`），
     避免 shell 引号问题。
3. **提交**：
   ```bash
   git-sync.sh commit --backend-file <path> --frontend-file <path>
   ```
   单行也可以 `--backend-msg "..." --frontend-msg "..."`。确实是同一件改动时用
   `--message-file <path>` / `--message "..."` 两仓共用。
   干净的仓会自动跳过；两仓都干净则报错。
4. `commit` **不自动 push**。要推另跑 `git-sync.sh push`，且先跟用户确认。

## 设计要点（改这个 skill 前先读）

- **先预检、后改动**：`new` / `co` / `rm` 先验证在两个仓库都能成功，才动任何一个——
  避免「后端切到了 dev、前端切失败」的半成品。`co` 的预检包含：分支在两仓都存在、
  两仓工作区都干净、目标分支没被别的 worktree 占用。
- **`push` / `pull` 是例外**：面对两个**独立**的远程，一成一败不是回滚场景，
  逐仓报结果、交用户处置。
- **工作区脏**：`co` / `pull` 硬拦（切换、变基真会动工作树）；`rm` 也拦（保守起见），
  `--force` 越过；`new` / `commit` 不拦（新建分支会把改动带走、提交本就是要处理改动）。
- **drift 是一等概念**：两仓当前分支不一致时所有命令都告警；`status` / `list` 专门用来发现它。
  脚本只告警不自动对齐——怎么对齐（谁并谁、丢弃谁）是人的决定。
- 提交信息永远由 AI 生成，脚本只负责机械执行。身份兜底：用户配了 `git config user.email`
  就用用户的，没配才用 `git-sync@localhost`（同 `describe.sh`）。
- 不写死目录名，一律从 `workspace.env` 读 `BACKEND_DIR` / `FRONTEND_DIR`；全程 `git -C`，不 `cd`。
- `co` 到差异很大的分支后，若 `dev-env` 正在跑，后端/前端可能要
  `.workspace/skills/dev-env/dev.sh dev down && ... dev up` 重启——这个 skill 不自动做。
