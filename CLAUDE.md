# describeadmin 业务方约定

> 本文件由 `init-workspace.sh` 生成到你的工作空间根目录。它写的是**你作为
> describeadmin 框架使用方**需要知道的约定——不是框架团队自己的开发规范
> （那份更长，讲插件作者规范、发布治理、SemVer，与你无关，你不会看到它）。

---

## 0. 你的工作空间长什么样

```
<workspace>/
├── CLAUDE.md              本文件
├── .claude/
│   ├── workspace.env       记录你的后端/前端目录名（dev-env skill 用它）
│   └── skills/              三个可用的 Claude Code skill，见第 4 节
├── <name>-server/           后端，Maven 项目，由 describeadmin-archetype 生成
└── <name>-web/               前端，由 @describeadmin/create-app 生成
```

这四样东西是同一次 `init-workspace.sh` 一起生成的。工作空间根目录本身**不是 git 仓库**——
你的两个项目 `<name>-server`/`<name>-web` 各自是独立仓库（`init-workspace.sh` 已经
`git init` + 首次提交好了），正常提交推送即可；
`.claude/` 与本文件不受版本控制，换一台机器需要重新跑一次 `init-workspace.sh`
（或者你也可以自己把这两样东西加进某个仓库，按你的习惯来）。

## 1. 你在哪一层

你是**Business 层**：只通过 Maven（`<name>-server/pom.xml` 的 `import framework-bom`）
和 npm（`<name>-web/package.json` 的 `@describeadmin/*` 依赖）引用框架，
不需要、也不应该把框架源码拷贝进你的仓库——框架的 bug 修复、新功能都通过升级依赖版本号
拿到，拷贝源码会让你拿不到后续更新。

## 2. 后端：继承框架基类，写"薄"代码

新增一个业务模块，四个类都继承框架基类，通用逻辑（审计字段、分页、逻辑删除、
统一响应结构、令牌校验）已经在基类里，不用重复写：

```java
public class OrderEntity extends BaseEntity { ... }
public interface OrderMapper extends BaseMapper<OrderEntity> { }
public class OrderService extends BaseService<OrderMapper, OrderEntity> { ... }
public class OrderController extends BaseController<OrderService, OrderEntity> { ... }
```

`BaseController` 自带 list/add/edit/remove 四个通用端点，权限点按
`<RequestMapping 前缀推导>:<对象>:<动作>` 自动生成——命名规则见下一节，推导错了的
症状是"连管理员账号都 403"，且报错完全不指向这个原因。

## 3. 命名约定（跟你相关的部分）

| 场景 | 规则 | 示例 |
|---|---|---|
| 权限点 | `<模块>:<对象>:<动作>`，动作只有 `list`/`add`/`edit`/`remove` 四个 | `order:item:edit` |
| 前端 `data-testid` | `<模块>-<对象>-<动作>`，所有关键交互元素都要带，没带视为该功能"未完成" | `order-add-btn` |

`data-testid` 不是装饰性约定——`visual-test` skill（见第 4 节）靠它定位页面元素，
没打的交互元素 AI 没法自动化测试。

## 4. 四个 Claude Code Skill

`.claude/skills/` 下有四个随工作空间一起生成的 skill，AI Agent 会按需自动调用，
你也可以直接要求"用 dev-env 起一下环境"这样触发：

- **`dev-env`**：一条命令拉起/查看/停止本地开发环境（后端 + 前端 + 共享 MySQL/Redis），
  支持多个 `git worktree` 并行开发互不干扰。命令本体在
  `.claude/skills/dev-env/dev.sh`，`slug`/`dev up`/`dev wait`/`dev status`/`dev down` 几个子命令。
- **`visual-test`**：AI 自动打开浏览器走一遍页面操作 + 核对数据库，产出带截图/日志的
  报告，不是只看"页面看起来正常"就下结论。格式与示例见
  `.claude/skills/visual-test/SKILL.md`。
- **`describe`**：把一个需求跑完整条链路——你给需求描述 + 参考材料（PRD / 参考代码 /
  图片 / 文档），AI 先建一个隔离的双 `git worktree` 沙箱，出开发计划给你确认（中途可追问），
  确认后自主实现、跑完整测试、动了前端就跑可视化测试，最后停在"待合并"并产出报告。
  你验证无误说一句"合并 `<slug>`"，它再把两个仓的分支合并回去并清理 worktree。
  细节见 `.claude/skills/describe/SKILL.md`。
- **`codegen`**：写一份 YAML spec，生成一个业务模块的薄代码（后端四件套 + 建表/菜单 SQL +
  前端页面 + API 封装）。它管生成器 jar 从 GitHub Release 的下载与缓存
  （`~/.describeadmin/codegen/<版本>/`，版本跟你后端 `pom.xml` 的 `<describeadmin.version>`
  一致）、spec 校验要点、以及生成后必须做的 SQL 登记。
  见 `.claude/skills/codegen/SKILL.md`。新增模块走它，不要手写——见第 6 节。

## 5. 你作为 API 消费者需要知道的一个坑

`Long`/`long` 类型的字段（包括所有实体的主键 `id`）在 JSON 里序列化成**字符串**，
不是数字。原因：如果你把 `mybatis-plus.global-config.db-config.id-type` 切到雪花 ID，
19 位数字超过 JS 的 `Number.MAX_SAFE_INTEGER`（16 位），前端 `JSON.parse` 会静默舍入——
**症状是列表显示正常，点编辑/删除却报"记录不存在"或者改错行**，非常隐蔽。

分页元信息（`total`/`current`/`size`/`pages`）是唯一例外，仍然是数字——`el-pagination`
的 `:total` 要求数字。你自己新增的 `Long` 字段如果不想转字符串，加
`@JsonFormat(shape = JsonFormat.Shape.NUMBER)`。

## 5.1 填下拉框：用 `/options`，不要拿分页接口凑

表单里要「选一个部门」「选一个角色」「选一个项目」时，**不要调对方的分页列表接口**，
更不要写 `?current=1&size=200` 这种"假装不分页"：

- 数据超过那个 size 就**静默丢**，症状是下拉里找不到某一项，看不出是接口截断了；
- **调大参数也修不好**——后端 `PageQuery` 的 size 上限就是 500；
- 而且你会因此需要对方模块的 `xxx:list` 权限，一授，侧边栏就多出你不想要的管理入口。

正确做法是调对应的选项接口，它们不分页、超限会明确报错而不是悄悄截断：

| 要什么 | 调什么 | 需要什么权限 |
|---|---|---|
| 部门树 | `getDeptOptionsApi()` | 登录即可 |
| 角色清单 | `getRoleOptionsApi(keyword?)` | 登录即可 |
| 菜单树 | `getMenuOptionsApi()` | 登录即可 |
| 字典项 | `getDictDataByTypeApi(dictType)` | 登录即可 |
| **你自己的业务模块** | 生成器产出的 `getXxxOptionsApi(keyword?)` | 该模块的 `xxx:list` |

返回的是统一的 `OptionItem`（`value` / `label`，树形多一个 `children`）：

- **`value` 是字符串**（同第 5 节的理由）。绑 `node-key="value"`，自己合成的顶层节点
  要写 `'0'` 而不是 `0`，否则 ElTreeSelect 严格相等匹配不上，表现为"选了没反应"。
- 停用项带 `disabled: true`，**仍然会下发**——不下发的话，已经关联了该项的记录
  一打开编辑表单就显示为空，看起来像"这条数据没填"，保存一次就真没了。

业务模块的选项接口**照常走数据权限**：「本部门」档的角色在下拉里只看得到本部门的数据，
与列表页一致。

## 6. 新增业务模块：用生成器，不要手写

写一份 YAML spec，跑生成器，一次拿到后端四件套（Entity/Mapper/Service/Controller）+
建表 SQL + 菜单 SQL + 前端页面 + API 封装。**用 `codegen` skill**（第 4 节）——它管
生成器 jar 的下载缓存、spec 校验要点、以及生成后必须做的 SQL 登记与两个隐坑
（下划线模块名导致的权限点 403、别自写 `list` 重载）。spec 格式见框架文档站的生成器一节。
生成的 SQL 不登记进 `<name>-server` 的 `spring.sql.init`，重启后表不会建、菜单不出现，
且报错不指向这里。

## 7. 不在本文件里的内容

以下是框架团队自己的事，你不需要知道，也不会在这个工作空间里看到对应文件：

- 框架自己怎么构建、发布到 Maven Central/npm 的流程
- 新增登录方式/消息通道这类 SPI 插件的作者规范
- 框架内部的 SemVer 兼容性承诺范围、CHANGELOG 规范
- 框架自己验证 MySQL 5.7/8.4 兼容性用的测试基础设施
