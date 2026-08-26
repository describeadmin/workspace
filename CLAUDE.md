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
│   └── skills/              两个可用的 Claude Code skill，见第 3 节
├── <name>-server/           后端，Maven 项目，由 describeadmin-archetype 生成
└── <name>-web/               前端，由 @describeadmin/create-app 生成
```

这四样东西是同一次 `init-workspace.sh` 一起生成的。工作空间根目录本身**不是 git 仓库**——
你的两个项目 `<name>-server`/`<name>-web` 各自是独立仓库，正常提交推送即可；
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

## 4. 两个 Claude Code Skill

`.claude/skills/` 下有两个随工作空间一起生成的 skill，AI Agent 会按需自动调用，
你也可以直接要求"用 dev-env 起一下环境"这样触发：

- **`dev-env`**：一条命令拉起/查看/停止本地开发环境（后端 + 前端 + 共享 MySQL/Redis），
  支持多个 `git worktree` 并行开发互不干扰。命令本体在
  `.claude/skills/dev-env/dev.sh`，`slug`/`dev up`/`dev status`/`dev down` 几个子命令。
- **`visual-test`**：AI 自动打开浏览器走一遍页面操作 + 核对数据库，产出带截图/日志的
  报告，不是只看"页面看起来正常"就下结论。格式与示例见
  `.claude/skills/visual-test/SKILL.md`。

## 5. 你作为 API 消费者需要知道的一个坑

`Long`/`long` 类型的字段（包括所有实体的主键 `id`）在 JSON 里序列化成**字符串**，
不是数字。原因：如果你把 `mybatis-plus.global-config.db-config.id-type` 切到雪花 ID，
19 位数字超过 JS 的 `Number.MAX_SAFE_INTEGER`（16 位），前端 `JSON.parse` 会静默舍入——
**症状是列表显示正常，点编辑/删除却报"记录不存在"或者改错行**，非常隐蔽。

分页元信息（`total`/`current`/`size`/`pages`）是唯一例外，仍然是数字——`el-pagination`
的 `:total` 要求数字。你自己新增的 `Long` 字段如果不想转字符串，加
`@JsonFormat(shape = JsonFormat.Shape.NUMBER)`。

## 6. 新增业务模块：用生成器，不要手写

写一份 YAML spec，跑生成器，一次拿到后端四件套（Entity/Mapper/Service/Controller）+
建表 SQL + 菜单 SQL + 前端页面 + API 封装。生成的 SQL 记得登记进
`<name>-server` 的 `spring.sql.init`，否则重启后表不会建。具体命令与 spec 格式，
参见框架文档站的生成器一节（不在本文件重复）。

## 7. 不在本文件里的内容

以下是框架团队自己的事，你不需要知道，也不会在这个工作空间里看到对应文件：

- 框架自己怎么构建、发布到 Maven Central/npm 的流程
- 新增登录方式/消息通道这类 SPI 插件的作者规范
- 框架内部的 SemVer 兼容性承诺范围、CHANGELOG 规范
- 框架自己验证 MySQL 5.7/8.4 兼容性用的测试基础设施
