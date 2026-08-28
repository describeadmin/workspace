---
name: codegen
description: Scaffold a describeadmin business module from a YAML spec using the codegen CLI jar — produces the backend four-piece set (Entity/Mapper/Service/Controller), schema + menu SQL, the frontend list page + API wrapper, and a structured acceptance-test spec, all as "thin" code over the framework base classes. Fetches and caches the codegen jar from GitHub Releases on first use. Use whenever a new CRUD module / business table is being added, whether or not the describe skill is driving it.
---

# codegen：YAML spec → 一个业务模块的薄代码

新增业务模块**不要手写四个类**。写一份受校验的 YAML spec，跑生成器，一次拿到：

| 侧 | 产物 |
|---|---|
| 后端 | `entity/<X>Entity.java`、`mapper/<X>Mapper.java`、`service/<X>Service.java`、`controller/<X>Controller.java`（都继承框架基类，通用逻辑不重复写）|
| SQL | `src/main/resources/db/schema-<表>.sql`、`menu-<表>.sql`（菜单 + 按钮权限点）|
| 前端 | `src/api/<模块>.ts`、`src/views/<模块>/index.vue` |
| 验收 | `test-specs/<模块>.yaml`（结构化端到端用例）|

生成器是一个命令行 jar，**不进 `pom.xml`、不发 Maven Central**——它只产源码文本，
产物落盘即与它无关，业务方运行时完全不需要它。

前置：本机有 `curl`、`java`（任意 JRE ≥ 17）。`.claude/workspace.env` 里有
`BACKEND_DIR` / `FRONTEND_DIR`（`init-workspace.sh` 会写好）。

---

## 1. 备好 jar（首次用 / 换机器时）

1. **定版本 —— codegen 版本号跟框架走**。按顺序取：
   - `.claude/workspace.env` 里的 `CODEGEN_VERSION`（显式覆盖时才有）；否则
   - `<BACKEND_DIR>/pom.xml` 里的 `<describeadmin.version>`（`framework-bom` 的版本，形如 `0.2.0`）——
     **这是默认**，codegen 与框架同号发布，生成的薄代码对应同号框架的基类契约；否则
   - 都取不到，退到 `curl -fsSL https://api.github.com/repos/describeadmin/codegen/releases/latest`
     的 `tag_name`。
2. **定位 Release**：`curl -fsSL https://api.github.com/repos/describeadmin/codegen/releases`，
   找 `tag_name` 与上一步版本同号的那个（`0.2.0` 与 `v0.2.0` 都算）。严格同号找不到就取同
   `大.小` 的最新（框架发了补丁号而 codegen 没跟的情况）。从它的 `assets[]` 取 `codegen.jar`
   和 `codegen.jar.sha256` 的 `browser_download_url`（别自己拼 URL）。
3. **看缓存**：`~/.describeadmin/codegen/<版本>/codegen.jar`。
   已存在，且 `sha256sum codegen.jar` 的哈希与同目录 `codegen.jar.sha256` 文件里的一致
   → 直接用，跳到第 5 步。
4. **下载**：把两个文件下到 `~/.describeadmin/codegen/<版本>/`，比对哈希一致才算数。
   下载不通又没有本地缓存 → 停下告诉用户，让他手动下到这个路径。
5. 确认 `java` 在 PATH。

> 缓存是 per-user 的：所有项目、所有 describe worktree 按版本号分目录共用，`describe.sh clean`
> 不会动它。同一框架版本每台机器通常只下一次；多个项目用不同框架版本时各自的 jar 并存。

## 2. 写 spec

放在 `<BACKEND_DIR>/codegen-specs/<模块>.yaml`。完整格式见框架文档站的生成器一节；
结构可照 `sample-app/codegen-specs/project.yaml`（那个模块没有一行手写代码，全部由 spec 生成）。

字段 `type` **只有这些**，SQL 红线固化在类型系统里、生成器产不出违规 SQL：

`string`、`text`、`int`、`long`、`decimal`、`flag`（0/1 语义）、`date`、`datetime`

写 `timestamp` / `boolean` / `json` / `float` / `double` 会被拦下并附带替代方案。

校验**一次性报出全部问题**，每条指明位置与修法。常见拦截：

- 字段名与 `BaseEntity` 内置字段（`id` / `createTime` / `deleted` / `version` …）重名
- 表名用了 `sys_` 前缀（那是 `framework-system-starter` 的系统管理表）
- `entity` 带了 `Entity` 后缀（生成器会自动加）
- 索引列 `VARCHAR` 超过 191（utf8mb4 下会突破 MySQL 5.7 的 767 字节键长上限）
- 非字符串类型用了 `query: like`

## 3. 跑

```bash
java -jar ~/.describeadmin/codegen/<版本>/codegen.jar \
  <BACKEND_DIR>/codegen-specs/<模块>.yaml \
  --out <BACKEND_DIR> --frontend-out <FRONTEND_DIR>
```

- **默认不覆盖已存在的文件**（Service / Controller 常有手工添加的业务逻辑）。
  确需覆盖才加 `--force`，且先看清楚要冲掉什么。
- `--dry-run` 只打印将生成的文件、不落盘，先确认影响面。

## 4. 生成之后（三个隐坑，都不指向自己）

1. **登记 SQL**。`schema-<表>.sql` 和 `menu-<表>.sql` 必须加进 `<BACKEND_DIR>` 的
   `spring.sql.init`（`application-local.yml` 的 `schema-locations` / `data-locations`），
   并保留 `encoding: UTF-8`。不登记的症状：重启后表不建、接口报错、侧边栏没有入口，
   而报错信息里没有任何东西指向这一步。
2. **权限点前缀**。模块名含下划线时（`my_module` → `@RequestMapping` 推导得 `/api/my-module`
   → 推出 `my-module`，而 `menu-*.sql` 里的权限点是 `my_module`）会错配，
   表现为**连管理员账号都被 403**。生成的 Controller 已直接写 `permPrefix()` 覆写来兜住；
   自己手改过 `@RequestMapping` 的话要核对推导结果和权限点一致。
3. **不要另写 `list` 重载**。想给列表加筛选就改 spec 里字段的 `query`（`eq` / `like` / `range`），
   Controller 会覆写框架的 `buildListWrapper` 生成真正生效的条件。自己再写一个带
   `@GetMapping` 的 `list(...)` 会和基类的 `list` 撞同一个 GET 路径，Spring 启动直接
   报 Ambiguous mapping。

## 5. 生成的代码编译不过时

codegen 与框架**同版本号发布**，正常情况下同号 jar 产出的薄代码就对应同号框架的基类契约。
编译不过，八成是取错了版本——回第 1 步确认用的是 `<BACKEND_DIR>/pom.xml` 里
`<describeadmin.version>` 的同号 jar，不是 `releases/latest` 兜底抓来的。确实需要临时用
别的版本时，在 `.claude/workspace.env` 里钉 `CODEGEN_VERSION` 再重跑第 1~4 步。

## 6. 被 describe skill 调用时

`describe` 的自主实现阶段（A6）会走到这里：spec 写在 worktree 内的
`<BACKEND_DIR>/codegen-specs/`，`--out` / `--frontend-out` 指向 worktree 内的两个子目录，
其余一致。生成 + 登记 SQL 后重启后端，确认表和菜单出现，再往下做。
