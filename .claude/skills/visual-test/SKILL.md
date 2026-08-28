---
name: visual-test
description: Execute a describeadmin structured visual-test scenario (YAML under testing/scenarios/) against the running dev environment, using chrome-devtools MCP for UI steps and Bash+mysql for DB assertions. Use when asked to run, verify, or check a UI scenario / E2E flow / visual regression (dept management, login, or any custom business module), or to add a new such scenario.
---

# AI 自动化可视化测试

## 设计原则：不写解释器，直接用已有工具

结构化 Spec（下方格式）描述"做什么"，但**执行它不需要一个专门的运行时程序**：

| Spec 里的动作 | 用什么执行 | 为什么不写脚本 |
|---|---|---|
| `navigate` / `click` / `fill` | `mcp__chrome-devtools__*` 工具 | 这些工具本来就存在，且出错时你能自己读 `take_snapshot`/console/network 现场诊断——这正是"AI 自动化"相对传统 E2E 框架的价值所在，写死一个 Puppeteer 驱动会把这个价值让渡掉 |
| 截图证据 | `mcp__chrome-devtools__take_screenshot`（`filePath` 参数直接指定落盘路径） | 同上 |
| `type: db` 断言 | `Bash` 起一条 `mysql ... -e "<query>"`，比对输出文本 | 这只是一次查询 + 字符串比较，你自己做比写一个脚本再调用它更直接、更少故障点 |
| 报告 | `Write` 直接写 Markdown | 同上 |

**结论：不维护任何自定义代码**，只维护 Spec 格式的约定 + 这份执行说明。如果发现自己想去
写一个"辅助脚本"，先想清楚是不是真的需要——大概率不需要。

## 执行前置条件

用 `dev-env` skill 确认目标环境已经在跑（`dev.sh dev status`，没起的话先 `dev.sh dev up`），
拿到：
- 前端地址：`http://localhost:<FRONTEND_PORT>`（`dev.sh slug` 能看到）
- DB 连接参数：`dev.sh slug` 打印的 MySQL 容器端口 + `.claude/workspace.env` 里没有的话，
  默认用户名/密码是 `app`/`app`（`init-workspace.sh` 生成的 archetype 默认值，
  业务方改过的话以实际为准）、schema 是 `dev.sh slug` 打印的 `DB schema` 那一行

记下当前 worktree 的 slug（`dev.sh slug` 第一行下面那个），证据目录按 slug 隔离，
避免多个 worktree 同时跑测试时互相覆盖证据文件。

## Spec 格式

场景文件放在 `testing/scenarios/<name>.yaml`（业务方自己的场景建议放进前端仓库的
`testing/scenarios/`，跟着那个仓库一起进版本控制；本 skill 只提供机制和一个示例）。

```yaml
scenario: <一句话场景名，用于报告标题>
description: <可选，场景验证的是什么、为什么值得测>

preconditions:
  - login_as: <用户名，如 admin>   # 目前只支持这一种

steps:                              # 按顺序执行
  - action: navigate
    target: <路径，相对前端根，如 /system/dept>
  - action: click
    selector: <CSS 选择器，一律用 [data-testid="..."]，不用其他任何选择器>
  - action: fill
    selector: <同上>
    value: <要填入的文本>

assertions:                         # 全部执行，不因前面失败就跳过——要看清全貌
  - type: ui
    selector: <[data-testid="..."]>
    expect: contains_text("<子串>")
  - type: db
    query: <单条 SELECT，只返回一行一列>
    expect: equals(<期望值，数字不加引号，字符串加引号>)

cleanup:                            # 可选。有副作用（新增/修改数据）的场景必须写，
  - query: <DELETE/UPDATE，把 steps 造成的数据改回原状>   # 保证场景可重复执行

evidence:
  - screenshot: after_each_step     # 目前只支持这一种策略，先都截
  - console_log: on_error
  - network_log: on_error
```

`selector` 只允许 `[data-testid="..."]`——没有 `data-testid` 的交互元素视为该页面
"未完成"，不要退而求其次用别的选择器，那等于在帮它遮掩这个缺口。

`expect` 只有两种：`equals(x)`（db 断言，字符串按字面比较，数字按数值比较）、
`contains_text(s)`（ui 断言，元素文本包含子串 `s`）。

## 执行步骤（照这个顺序做）

1. **建证据目录**：`testing/results/<slug>/<scenario文件名>-<YYYYMMDD-HHMMSS>/`
   （直接用 `Bash` `mkdir -p`），不进 git（前端仓库的 `.gitignore` 建议加一条
   `testing/results/`）。

2. **读 Spec**：用 `Read` 直接读 YAML 文件——你能原生理解 YAML，不需要先转 JSON。

3. **走 preconditions**：`login_as: admin` 就是导航到登录页，依次
   `fill [data-testid="login-username-input"]`、
   `fill [data-testid="login-password-input"]`、
   `click [data-testid="login-submit-btn"]`（这三个 `data-testid` 是
   `@describeadmin/create-app` 生成的登录页共用组件自带的，跨项目稳定；账号是
   `admin`，口令由 dev-seed 随机生成，取后端项目根 `.passwd` 文件的内容，
   业务方改过密码的话以实际为准。首次登录若落到「强制修改密码」页，说明该账号
   还没改过初始密码）。

4. **逐条执行 steps**：
   - `navigate` → `mcp__chrome-devtools__navigate_page`
   - `click`/`fill` → **不接受 CSS 选择器**，只接受 `take_snapshot` 返回的 `uid`。
     Spec 里的 `selector` 是给人看的机器可读锚点，标明"应该操作页面上的哪个元素"，
     不是能直接喂给工具的参数。实际执行顺序固定是：先 `take_snapshot`（弹窗/表单
     出现后要重新截一次，`uid` 每次快照都会变），对照对应 Vue 源码里 `data-testid`
     所在元素的可见文本/角色（比如 `dept-add-btn` 对应按钮文本"新增"），在快照输出里
     找到那一行，取它的 `uid` 去调 `click`/`fill`。工具报错找不到元素时，先怀疑页面
     还没渲染完（用 `wait_for`）或者快照已经过期，而不是怀疑 `data-testid` 写错——
     后者应该是读源码核实过的
   - 每步完成后 `take_screenshot`，`filePath` 参数直接传证据目录下的绝对路径
     （`step-<序号>-<简述>.png`），工具会直接落盘

5. **执行 assertions**（全部执行，即使某条已经能预判失败——报告需要完整信息）：
   - `type: ui`：`take_snapshot` 里搜 `expect` 给的子串是否作为某个节点的文本出现
   - `type: db`：`Bash` 执行
     ```
     mysql -h127.0.0.1 -P<DEV_MYSQL_PORT> -uapp -papp --default-character-set=utf8mb4 \
       -N -B -e "<query>" <schema>
     ```
     （`-N -B` 去表头、用 tab 分隔，方便直接比对单值；本地开发环境的口令走命令行参数
     可接受，这不是生产凭据）。把返回值与 `expect` 比对。

6. **出错处理**：任意一步失败，不要中途放弃——继续把剩下能执行的 assertions 跑完，
   并额外采集 `list_console_messages` 与 `list_network_requests` 存进证据目录
   （`console.json`/`network.json`），这是排查"到底是前端问题还是后端问题"的关键材料。

7. **cleanup**：Spec 里有 `cleanup` 就执行，方式同 db 断言，用 `Bash` + `mysql`。
   忘记这步会导致场景第二次跑时断言逻辑对不上（比如 `contains_text` 命中的是上一次
   跑剩下的脏数据）。

8. **写报告**：`Write` 一份 `report.md` 到证据目录，至少包含：场景名、执行时间、
   目标环境（slug）、每个 step 的结果、每条 assertion 的实际值 vs 期望值、
   证据文件清单、总体结论（全部通过 / 部分失败，列出具体哪几条）。

9. **如实汇报**：不要因为"页面看起来正常"就判定通过。UI 断言和 DB 断言必须都通过才算
   通过；只有 UI 断言通过、DB 断言没查或没通过，如实报告为"部分通过"。

## 被 `describe` skill 调用时

`describe` 的流程里，动了前端就会调本 skill：

- **新模块**：先照上面的 Spec 格式写 `<FRONTEND_DIR>/testing/scenarios/<slug>.yaml`（`<slug>` 就是
  `describe` 那次的 slug），再按「执行步骤」跑。
- **环境**：`describe` 已经用 `dev-env` 起好并 `dev.sh dev wait` 等到就绪，直接拿它给的
  前端地址 / DB 参数，不用自己再 `dev up`。
- **证据目录**已按 `dev.sh slug` 的 slug 隔离（`testing/results/<slug>/...`），多个 `describe`
  worktree 并行跑测试不会互相覆盖。
- **结论回传**：任一 UI 或 DB 断言失败，就是 `describe` 那份 `REPORT.md` 里的**阻塞结论**——
  不允许「页面看起来正常」就放行。chrome-devtools MCP 不可用时，如实报「可视化测试未执行」+ 原因，
  不要静默跳过。

## 示例场景

`scenarios/dept-create.yaml`——新增部门后在部门列表可见。选择器来自
`@describeadmin/system-ui` 的部门管理页面，**每个 describeadmin 业务项目都有这个页面**
（不是某个特定项目专属），可以直接照抄跑一遍验证整套流程是否work，也可以照它的格式
给自己的业务模块写新场景。
