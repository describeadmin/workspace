#!/usr/bin/env bash
#
# 一条命令初始化一个 describeadmin 业务方工作空间：后端工程 + 前端工程 +
# AI 工作目录（.claude/skills、CLAUDE.md）。
#
# 用法（首选，不需要先本地 clone 任何仓库）：
#   curl -fsSL https://raw.githubusercontent.com/describeadmin/workspace/main/init-workspace.sh \
#     | bash -s -- <workspace-name>
#
# 已经本地 clone 了这个仓库的话，也可以直接跑（脚本会自己判断，见「拉取 AI 工作目录」一节）：
#   ./init-workspace.sh <workspace-name>
#
# 可选参数：
#   --group-id <groupId>            默认 com.example，强烈建议改成你自己的域名反写
#   --archetype-version <version>   默认自动查询 Maven Central 上的最新版本
#   --proxy-target <url>            前端开发代理目标，默认 http://localhost:8090
#
# 产出（工作区目录本身不是 git 仓库，是容纳两个独立仓库的容器目录）：
#   <workspace-name>/
#   ├── CLAUDE.md                业务方视角的约定说明
#   ├── .claude/
#   │   ├── workspace.env         dev-env skill 读取的目录名/项目名配置
#   │   └── skills/                dev-env、visual-test、describe、codegen 四个 Claude Code skill
#   ├── <workspace-name>-server/   后端，describeadmin-archetype 生成 + git init
#   └── <workspace-name>-web/       前端，@describeadmin/create-app 生成 + git init
#
set -euo pipefail

WORKSPACE_REPO_URL="https://github.com/describeadmin/workspace.git"
GROUP_ID="com.example"
ARCHETYPE_VERSION=""
PROXY_TARGET="http://localhost:8090"
NAME=""

usage() { sed -n '2,25p' "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --group-id) GROUP_ID="$2"; shift 2 ;;
    --archetype-version) ARCHETYPE_VERSION="$2"; shift 2 ;;
    --proxy-target) PROXY_TARGET="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    -*) echo "未知参数：$1" >&2; usage; exit 1 ;;
    *) NAME="$1"; shift ;;
  esac
done

if [[ -z "$NAME" ]]; then
  echo "用法：init-workspace.sh <workspace-name> [--group-id ...] [--archetype-version ...]" >&2
  exit 1
fi
if [[ ! "$NAME" =~ ^[a-z][a-z0-9-]*$ ]]; then
  echo "✗ 项目名只允许小写字母、数字、短横线，且以字母开头（当前：$NAME）" >&2
  exit 1
fi

BACKEND_DIR="${NAME}-server"
FRONTEND_DIR="${NAME}-web"
PACKAGE="${GROUP_ID}.$(echo "$NAME" | tr -d '-')"

for cmd in mvn npm git curl; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "✗ 找不到命令：$cmd，请先安装" >&2; exit 1; }
done

if [[ -e "$NAME" ]]; then
  echo "✗ 目标目录 $NAME 已存在，换一个名字或先清空它" >&2
  exit 1
fi

mkdir -p "$NAME"
cd "$NAME"

# --- 1. 解析 archetype 版本（版本核查纪律：以 repo1 的 maven-metadata.xml 为准，不猜） ---
if [[ -z "$ARCHETYPE_VERSION" ]]; then
  echo "▸ 查询 describeadmin-archetype 最新版本..."
  META_URL="https://repo1.maven.org/maven2/io/github/describeadmin/describeadmin-archetype/maven-metadata.xml"
  ARCHETYPE_VERSION="$(curl -fsSL "$META_URL" 2>/dev/null | grep -o '<release>[^<]*' | head -1 | sed 's/<release>//')"
  if [[ -z "$ARCHETYPE_VERSION" ]]; then
    echo "✗ 自动查询失败，请用 --archetype-version <版本号> 显式指定" >&2
    echo "  （可以手工看一眼 $META_URL）" >&2
    exit 1
  fi
  echo "  用版本 $ARCHETYPE_VERSION"
fi

# --- 2. 后端：describeadmin-archetype ---
echo "▸ 生成后端工程 $BACKEND_DIR ..."
mvn -B archetype:generate \
  -DarchetypeGroupId=io.github.describeadmin \
  -DarchetypeArtifactId=describeadmin-archetype \
  -DarchetypeVersion="$ARCHETYPE_VERSION" \
  -DgroupId="$GROUP_ID" \
  -DartifactId="$BACKEND_DIR" \
  -Dpackage="$PACKAGE" >/dev/null

# --- 3. 前端：@describeadmin/create-app ---
echo "▸ 生成前端工程 $FRONTEND_DIR ..."
npm create @describeadmin/app@latest -- "$FRONTEND_DIR" >/dev/null

# --- 4. git 初始化两个子项目 ---
# archetype / create-app 都不建仓，但 CLAUDE.md 讲的是「你的两个项目各自是独立仓库」，
# 且 describe / dev-env 的 git worktree 能力都以此为前提。这里补上：各自 init + 首次提交。
for proj in "$BACKEND_DIR" "$FRONTEND_DIR"; do
  if [[ -d "$proj/.git" ]]; then
    echo "▸ $proj 已是 git 仓库，跳过"
    continue
  fi
  echo "▸ git 初始化 $proj ..."
  git -C "$proj" init -b main >/dev/null
  git -C "$proj" add -A
  if [[ -n "$(git -C "$proj" config user.email || true)" ]]; then
    git -C "$proj" commit -q -m "chore: initial commit from init-workspace.sh"
  else
    git -C "$proj" -c user.name="describeadmin" -c user.email="init@describeadmin.local" \
      commit -q -m "chore: initial commit from init-workspace.sh"
  fi
done

# --- 5. 拉取 AI 工作目录（.claude/ + CLAUDE.md） ---
# 本地已 clone 本仓库、直接运行脚本的场景：脚本旁边就有这两样东西，直接复制。
# curl | bash 管道执行的场景：$0 不是磁盘上的真实文件，没有本地文件可用，
# 走 git clone 到临时目录再复制。
SCRIPT_SRC=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
  CANDIDATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -d "$CANDIDATE_DIR/.claude" && -f "$CANDIDATE_DIR/CLAUDE.md" ]]; then
    SCRIPT_SRC="$CANDIDATE_DIR"
  fi
fi

if [[ -n "$SCRIPT_SRC" ]]; then
  echo "▸ 从本地 workspace 仓库复制 .claude/ + CLAUDE.md ..."
  cp -r "$SCRIPT_SRC/.claude" .
  cp "$SCRIPT_SRC/CLAUDE.md" .
else
  echo "▸ 拉取 describeadmin/workspace 仓库内容（.claude/ + CLAUDE.md）..."
  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TMP_DIR"' EXIT
  git clone --depth 1 --quiet "$WORKSPACE_REPO_URL" "$TMP_DIR"
  cp -r "$TMP_DIR/.claude" .
  cp "$TMP_DIR/CLAUDE.md" .
fi

# --- 6. 写 workspace.env，dev-env skill 靠它知道目录名/项目名 ---
cat > .claude/workspace.env <<EOF
BACKEND_DIR=$BACKEND_DIR
FRONTEND_DIR=$FRONTEND_DIR
PROJECT_NAME=$NAME

# 本地开发用的 MySQL 镜像。默认 mysql:5.7（对齐框架的兼容基线）。
# 你的线上库是 8.x 就取消下一行注释，让本地环境对齐线上：
# DEV_MYSQL_IMAGE=mysql:8.0

# codegen 生成器的版本。留空＝跟随后端 pom.xml 的 <describeadmin.version>（codegen 与
# 框架同号发布）。只在想临时用别的 codegen 版本时才取消下一行注释、填具体版本：
# CODEGEN_VERSION=
EOF

# 前端代理目标如果不是默认值，顺手写进 .env，省得手动改
if [[ "$PROXY_TARGET" != "http://localhost:8090" && -f "$FRONTEND_DIR/.env" ]]; then
  echo "VITE_PROXY_TARGET=$PROXY_TARGET" >> "$FRONTEND_DIR/.env"
fi

echo
echo "✔ 工作空间 $NAME 已就绪"
echo
echo "接下来："
echo "  1. 起数据库：cd $NAME && .claude/skills/dev-env/dev.sh dev up"
echo "     （首次运行会自动建共享 MySQL/Redis 容器 + 后台起后端/前端）"
echo "  2. 或者手工分别起：cd $BACKEND_DIR && mvn spring-boot:run -Dspring-boot.run.profiles=local"
echo "               cd $FRONTEND_DIR && pnpm install && pnpm dev"
echo "  3. 管理员账号 admin，口令随机生成——见后端启动日志或 $BACKEND_DIR/.passwd"
echo
echo "两个子项目已各自 git init + 首次提交（describe skill 的 worktree 能力以此为前提）。"
echo "把 $NAME 打开交给 AI Agent（读 CLAUDE.md 即可开工）：直接描述需求走 describe skill 全流程，"
echo "或用 codegen 生成业务模块、dev-env / visual-test 单独起环境跑测试——细节见 .claude/skills/*/SKILL.md。"
