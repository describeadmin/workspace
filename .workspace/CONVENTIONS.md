# describeadmin 业务方约定

## 你在哪一层

你是**Business 层**：只通过 Maven（`<name>-server/pom.xml` 的 `import framework-bom`）
和 npm（`<name>-web/package.json` 的 `@describeadmin/*` 依赖）引用框架，
不需要、也不应该把框架源码拷贝进你的仓库——框架的 bug 修复、新功能都通过升级依赖版本号
拿到，拷贝源码会让你拿不到后续更新。

## 后端：继承框架基类，写"薄"代码

新增一个业务模块，四个类都继承框架基类，通用逻辑（审计字段、分页、逻辑删除、
统一响应结构、令牌校验）已经在基类里，不用重复写：

```java
public class OrderEntity extends BaseEntity { ... }
public interface OrderMapper extends BaseMapper<OrderEntity> { }
public class OrderService extends BaseService<OrderMapper, OrderEntity> { ... }
public class OrderController extends BaseController<OrderService, OrderMapper, OrderEntity> { ... }
```

`BaseController` 自带列表 / 详情 / 新增 / 编辑 / 删除五个通用端点，按 `<权限点前缀>:<动作>` 自动校验权限。
前缀由 `permPrefix()` 决定，默认从 `@RequestMapping` 推导（`/api/order` → `order`）；codegen 生成的
Controller 已显式覆写。前缀与菜单 changelog 里登记的 `perm_code` 对不上的症状是"连管理员账号都 403"，
且报错完全不指向这个原因。

## 命名约定（跟你相关的部分）

| 场景 | 规则 | 示例 |
|---|---|---|
| 权限点 | 推荐 `<模块>:<对象>:<动作>`，通用动作是 `list`/`add`/`edit`/`remove`。codegen 默认两段式 `<module>:<动作>`，spec 写 `permPrefix` 即三段式。一个项目里选一种保持一致 | `sales:order:edit`（三段式）、`order:edit`（两段式） |
| 前端 `data-testid` | `<模块>-<对象>-<动作>`，所有关键交互元素都要带，没带视为该功能"未完成" | `order-add-btn` |

`data-testid` 不是装饰性约定——`acceptance-test` skill靠它定位页面元素，
没打的交互元素 AI 没法自动化测试。

## API 中的 Long 字段

`Long`/`long` 类型的字段（包括所有实体的主键 `id`）在 JSON 里序列化成**字符串**，
不是数字。原因：如果你把 `mybatis-plus.global-config.db-config.id-type` 切到雪花 ID，
19 位数字超过 JS 的 `Number.MAX_SAFE_INTEGER`（16 位），前端 `JSON.parse` 会静默舍入——
**症状是列表显示正常，点编辑/删除却报"记录不存在"或者改错行**，非常隐蔽。

分页元信息（`total`/`current`/`size`/`pages`）是唯一例外，仍然是数字——`el-pagination`
的 `:total` 要求数字。你自己新增的 `Long` 字段如果不想转字符串，加
`@JsonFormat(shape = JsonFormat.Shape.NUMBER)`。

## 填下拉框：用 `/options`，不要拿分页接口凑

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

- **`value` 是字符串**（同上文的 Long 字段规则）。绑 `node-key="value"`，自己合成的顶层节点
  要写 `'0'` 而不是 `0`，否则 ElTreeSelect 严格相等匹配不上，表现为"选了没反应"。
- 停用项带 `disabled: true`，**仍然会下发**——不下发的话，已经关联了该项的记录
  一打开编辑表单就显示为空，看起来像"这条数据没填"，保存一次就真没了。

业务模块的选项接口**照常走数据权限**：「本部门」档的角色在下拉里只看得到本部门的数据，
与列表页一致。

## 新增业务模块：用生成器，不要手写

写一份 YAML spec，跑生成器，一次拿到后端四件套（Entity/Mapper/Service/Controller）+
建表 SQL + 菜单 SQL + 前端页面 + API 封装。**用 `codegen` skill**——它管
生成器 jar 的下载缓存、spec 校验要点、changelog 的规矩与两个隐坑
（下划线模块名导致的权限点 403、别自写 `list` 重载）。spec 格式见框架文档站的生成器一节。

数据库变更（建表、加列、菜单、字典）一律是 `<name>-server/src/main/resources/db/changelog/app/`
下的 Liquibase changelog，文件名 `<yyyyMMddHHmm>__<描述>.sql`，**放进去重启即执行，不需要登记**：

- 已执行过的 DDL changeset **不能再改**（校验和不符，所有已建库的环境都会拒绝启动），
  加列 / 改列新建文件写 ALTER；每个文件首行必须是
  `--liquibase formatted sql logicalFilePath:app/<文件名>`，否则启动即报错。
- 启动时做什么由 `describeadmin.migration.mode` 决定：`application-local.yml` 是 `apply`（自动执行）；
  生产不写，默认 `validate`——有未执行的变更就拒绝启动。生产要么用
  `--describeadmin.migration.mode=print-sql` 生成 SQL 交给 DBA，要么显式 `apply` 启动一次。
