#!/usr/bin/env bash
#
# 一条命令拉起/销毁【当前 worktree 专属】的本地开发环境。
#
# ---------------------------------------------------------------------------
# 这是 describeadmin `workspace` 仓库的一部分，随 `init-workspace.sh` 一起落进
# 业务方的工作空间（`<workspace>/.claude/skills/dev-env/dev.sh`）。它读取
# `init-workspace.sh` 写好的 `<workspace>/.claude/workspace.env`
# （`BACKEND_DIR`/`FRONTEND_DIR`/`PROJECT_NAME`）来知道后端/前端目录叫什么——
# 不写死任何具体项目名，因为每个业务方的目录名都不一样。
#
# 两层隔离，对应两种不同的共享粒度：
#   项目级（同一个业务项目的全部 worktree 共享）——MySQL/Redis 常驻实例本身，
#     容器名与宿主机端口按 PROJECT_NAME 派生，同一台机器上跑多个不同业务项目
#     不会互相撞名/撞端口。
#   worktree 级（每个 worktree 各自独立）——DB schema、Redis db index、
#     后端/前端应用进程与端口。slug 直接对【工作区根目录的绝对路径】取 hash，
#     与用 git worktree 拉出的哪个分支无关。
#
# 用法：
#   ./dev.sh slug            打印当前工作区的 slug 与全部派生参数
#   ./dev.sh dev up          拉起共享 MySQL/Redis（幂等）+ 建本 worktree 专属 schema
#                            + 后台起后端与前端
#   ./dev.sh dev status      查看本 worktree 开发环境的进程/端口
#   ./dev.sh dev wait [back|front|all] [--timeout <秒，默认 180>]
#                            阻塞到对应端口可连接（后端还会盯日志的启动完成/失败行）；
#                            给自动化流程（describe / visual-test）用，不用人肉看日志
#   ./dev.sh dev logs back|front   跟踪对应进程日志
#   ./dev.sh dev down        停止【本 worktree 的】应用进程；不动共享的 MySQL/Redis
#                            容器——同项目的其他 worktree 可能还在用
#
# 可覆盖的环境变量（写进 workspace.env 或直接 export，均有默认值）：
#   DEV_MYSQL_IMAGE   默认 mysql:5.7 —— 与框架的兼容基线一致（框架的 DDL/基类 SQL
#     要能跑在业主可能用的 5.7 上，本地默认也跑 5.7 以便尽早暴露不兼容）。
#     你自己的库是 8.x 就设成 mysql:8.0 让本地对齐线上；这只影响本地开发容器
#   DEV_MYSQL_ROOT_PASSWORD   默认 root
#   DEV_APP_DB_USER / DEV_APP_DB_PASSWORD   默认 app / app
#   DEV_MYSQL_PORT / DEV_REDIS_PORT   默认按 PROJECT_NAME 派生（见下），
#     同一台机器上跑多个业务项目时一般不需要手动改，除非算出来的默认值恰好撞车
#
# ⚠️ 已知限制：
#   - 共享 MySQL 的 `app` 用户默认（官方镜像行为）只被授权访问 `MYSQL_DATABASE`
#     这一个库，脚本首次建共享容器/建新 worktree schema 时都显式 `GRANT`，
#     否则会在启动时报 `Access denied` 而不是更直观的"库不存在"
#   - 不要对同一个 worktree 并发跑两次 `dev up`——`ensure_dev_mysql`/`ensure_dev_redis`
#     的"先查是否存在再创建"没有加锁，两个进程同时跑会在"查的时候还没有、
#     创建的时候已经被对方创建了"这个窗口期撞上 `docker run` 的 name 冲突报错
#     （本轮真实撞见过一次）。单次调用本身是幂等的，问题只在并发调用
#   - DEV_MYSQL_IMAGE 只在【首次创建共享容器】时生效。容器已存在时 `dev up` 直接复用，
#     改了值不会自动换镜像——要换先 `docker rm -f $MYSQL_CONTAINER`（会清掉该项目
#     所有 worktree 的开发数据，schema 下次 `dev up` 会自动重建）。MySQL 容器是
#     项目级共享的，同项目的多个 worktree 用同一个版本，不能各自挑
# ---------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
WORKSPACE_ENV="$WORKSPACE_DIR/.claude/workspace.env"

if [[ ! -f "$WORKSPACE_ENV" ]]; then
  echo "✗ 找不到 $WORKSPACE_ENV" >&2
  echo "  这个文件应该由 init-workspace.sh 生成；如果你是手工拼出的工作空间，" >&2
  echo "  照下面格式自己写一份（三行都必填）：" >&2
  echo "    BACKEND_DIR=<后端目录名>" >&2
  echo "    FRONTEND_DIR=<前端目录名>" >&2
  echo "    PROJECT_NAME=<项目名，用于派生共享容器名/端口>" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$WORKSPACE_ENV"
: "${BACKEND_DIR:?workspace.env 缺 BACKEND_DIR}"
: "${FRONTEND_DIR:?workspace.env 缺 FRONTEND_DIR}"
: "${PROJECT_NAME:?workspace.env 缺 PROJECT_NAME}"

DEV_MYSQL_IMAGE="${DEV_MYSQL_IMAGE:-mysql:5.7}"
DEV_MYSQL_ROOT_PASSWORD="${DEV_MYSQL_ROOT_PASSWORD:-root}"
DEV_APP_DB_USER="${DEV_APP_DB_USER:-app}"
DEV_APP_DB_PASSWORD="${DEV_APP_DB_PASSWORD:-app}"

hash_of() {
  if command -v sha1sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha1sum | cut -c1-8
  else
    printf '%s' "$1" | shasum | cut -c1-8
  fi
}

# 项目级 slug：只随 PROJECT_NAME 变化，同一项目的所有 worktree 算出同一个值——
# 共享 MySQL/Redis 容器与端口靠它保持稳定，不因为你在哪个 worktree 里跑而改变。
PROJECT_SLUG="$(hash_of "$PROJECT_NAME")"
PROJECT_PORT_OFFSET=$(( (16#${PROJECT_SLUG:0:4} % 50) * 10 ))

# worktree 级 slug：对工作区根目录的绝对路径取 hash——同一个工作区根目录
# 天然对应同一个逻辑 worktree，与里面的仓库当前切到哪个分支无关。
SLUG="$(hash_of "$WORKSPACE_DIR")"
OFFSET=$(( (16#${SLUG:0:4} % 100) * 5 ))
DEV_REDIS_DB=$(( 16#${SLUG:4:2} % 16 ))

DEV_MYSQL_PORT="${DEV_MYSQL_PORT:-$((3307 + PROJECT_PORT_OFFSET))}"
DEV_REDIS_PORT="${DEV_REDIS_PORT:-$((6379 + PROJECT_PORT_OFFSET))}"
BACKEND_PORT=$((8090 + OFFSET))
FRONTEND_PORT=$((5777 + OFFSET))
DEV_SCHEMA="${PROJECT_NAME//-/_}_${SLUG}"
MYSQL_CONTAINER="describeadmin-dev-mysql-${PROJECT_NAME}"
REDIS_CONTAINER="describeadmin-dev-redis-${PROJECT_NAME}"

STATE_DIR="$WORKSPACE_DIR/.claude/skills/dev-env/.worktree/$SLUG"
mkdir -p "$STATE_DIR"

print_params() {
  cat <<EOF
工作区      : $WORKSPACE_DIR
项目名      : $PROJECT_NAME
后端目录    : $BACKEND_DIR
前端目录    : $FRONTEND_DIR
worktree slug: $SLUG
--- 共享（同项目全部 worktree 共用）---
MySQL 容器  : $MYSQL_CONTAINER  端口 $DEV_MYSQL_PORT
MySQL 镜像  : $DEV_MYSQL_IMAGE  (DEV_MYSQL_IMAGE 可覆盖)
Redis 容器  : $REDIS_CONTAINER  端口 $DEV_REDIS_PORT
--- 本 worktree 专属 ---
后端端口    : $BACKEND_PORT   (SERVER_PORT)
前端端口    : $FRONTEND_PORT  (vite --port)
DB schema   : $DEV_SCHEMA
Redis db    : $DEV_REDIS_DB   (0~15)
状态目录    : $STATE_DIR
EOF
}

is_windows() {
  case "${OS:-}${OSTYPE:-}" in
    *Windows_NT*|*msys*|*cygwin*|*MINGW*) return 0 ;;
    *) return 1 ;;
  esac
}

kill_pid_file() {
  local file="$1" pid
  [[ -f "$file" ]] || return 0
  pid="$(cat "$file")"
  [[ -n "$pid" ]] || { rm -f "$file"; return 0; }
  if is_windows; then
    taskkill //F //T //PID "$pid" >/dev/null 2>&1 || true
  else
    kill -TERM "$pid" >/dev/null 2>&1 || true
    sleep 1
    kill -KILL "$pid" >/dev/null 2>&1 || true
  fi
  rm -f "$file"
}

# 实测确认（2026-08-26，真实跑 mvn spring-boot:run 触发过一次）：`taskkill //T` 杀的是
# 记录下来的那个 pid 自身的进程树，但 mvn 在 Windows 上启动真正的 java 子进程后，
# 那个 java 进程往往已经脱离了这棵树——`dev down` 报告"已停止"，java 却还占着端口，
# 不是文档写写的"极端情况"，是本轮验证时的必现结果。按端口杀更可靠：我们本来就知道
# 这个端口应该被谁占着，不用管进程树关系。
kill_by_port() {
  local port="$1"
  if is_windows; then
    powershell -NoProfile -Command \
      "Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue |
       Select-Object -ExpandProperty OwningProcess -Unique |
       ForEach-Object { Stop-Process -Id \$_ -Force -ErrorAction SilentlyContinue }" \
      >/dev/null 2>&1 || true
  else
    local pid
    pid="$(lsof -ti tcp:"$port" 2>/dev/null || true)"
    [[ -n "$pid" ]] && kill -KILL $pid >/dev/null 2>&1 || true
  fi
}

pid_alive() {
  local file="$1" pid
  [[ -f "$file" ]] || return 1
  pid="$(cat "$file")"
  [[ -n "$pid" ]] || return 1
  if is_windows; then
    tasklist //FI "PID eq $pid" 2>/dev/null | grep -q "$pid"
  else
    kill -0 "$pid" >/dev/null 2>&1
  fi
}

mysql_exec() {
  docker exec -i "$MYSQL_CONTAINER" \
    mysql -uroot -p"$DEV_MYSQL_ROOT_PASSWORD" --default-character-set=utf8mb4 -e "$1"
}

ensure_dev_mysql() {
  if docker inspect -f '{{.State.Running}}' "$MYSQL_CONTAINER" >/dev/null 2>&1; then
    [[ "$(docker inspect -f '{{.State.Running}}' "$MYSQL_CONTAINER")" == "true" ]] \
      || docker start "$MYSQL_CONTAINER" >/dev/null
  else
    echo "▸ 首次运行，创建共享 MySQL 容器 $MYSQL_CONTAINER（端口 $DEV_MYSQL_PORT）"
    echo "  镜像 $DEV_MYSQL_IMAGE（改 DEV_MYSQL_IMAGE 可对齐你的线上版本）"
    docker run -d --name "$MYSQL_CONTAINER" -p "${DEV_MYSQL_PORT}:3306" \
      -e MYSQL_ROOT_PASSWORD="$DEV_MYSQL_ROOT_PASSWORD" \
      -e MYSQL_DATABASE=describeadmin \
      -e MYSQL_USER="$DEV_APP_DB_USER" -e MYSQL_PASSWORD="$DEV_APP_DB_PASSWORD" \
      "$DEV_MYSQL_IMAGE" --character-set-server=utf8mb4 --collation-server=utf8mb4_general_ci >/dev/null
  fi

  echo "▸ 等待 $MYSQL_CONTAINER 就绪..."
  local tries=0
  until docker exec "$MYSQL_CONTAINER" mysqladmin ping -h127.0.0.1 -uroot -p"$DEV_MYSQL_ROOT_PASSWORD" --silent >/dev/null 2>&1; do
    tries=$((tries + 1))
    [[ $tries -gt 30 ]] && { echo "✗ $MYSQL_CONTAINER 30 秒内未就绪" >&2; exit 1; }
    sleep 1
  done

  echo "▸ 建本 worktree 专属 schema：$DEV_SCHEMA"
  # app 用户默认（官方镜像行为）只被授权访问 MYSQL_DATABASE（describeadmin）这一个库，
  # 新建的 worktree 专属 schema 必须显式 GRANT，否则启动时报 Access denied，
  # 报错完全不会提示"schema 没被授权"这个真实原因。
  mysql_exec "CREATE DATABASE IF NOT EXISTS \`$DEV_SCHEMA\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
              GRANT ALL PRIVILEGES ON \`$DEV_SCHEMA\`.* TO '$DEV_APP_DB_USER'@'%';
              FLUSH PRIVILEGES;"
}

ensure_dev_redis() {
  if docker inspect -f '{{.State.Running}}' "$REDIS_CONTAINER" >/dev/null 2>&1; then
    [[ "$(docker inspect -f '{{.State.Running}}' "$REDIS_CONTAINER")" == "true" ]] \
      || docker start "$REDIS_CONTAINER" >/dev/null
  else
    echo "▸ 首次运行，创建共享 Redis 容器 $REDIS_CONTAINER（端口 $DEV_REDIS_PORT）"
    docker run -d --name "$REDIS_CONTAINER" -p "${DEV_REDIS_PORT}:6379" redis:7-alpine >/dev/null
  fi
}

dev_up() {
  ensure_dev_mysql
  # Redis 只有装了缓存类插件才用得到，起失败不阻塞主流程。
  ensure_dev_redis || echo "⚠ $REDIS_CONTAINER 未能启动，跳过（不影响未用到 Redis 的项目）"

  local ds_url="jdbc:mysql://localhost:${DEV_MYSQL_PORT}/${DEV_SCHEMA}?useSSL=false&allowPublicKeyRetrieval=true&serverTimezone=Asia/Shanghai&characterEncoding=utf8"

  echo "▸ 后台启动后端 $BACKEND_DIR（端口 $BACKEND_PORT，日志见 $STATE_DIR/backend.log）"
  (
    cd "$WORKSPACE_DIR/$BACKEND_DIR"
    SERVER_PORT="$BACKEND_PORT" \
    SPRING_DATASOURCE_URL="$ds_url" \
    SPRING_DATASOURCE_USERNAME="$DEV_APP_DB_USER" \
    SPRING_DATASOURCE_PASSWORD="$DEV_APP_DB_PASSWORD" \
    SPRING_DATA_REDIS_DATABASE="$DEV_REDIS_DB" \
    SPRING_DATA_REDIS_PORT="$DEV_REDIS_PORT" \
    nohup mvn spring-boot:run -Dspring-boot.run.profiles=local \
      > "$STATE_DIR/backend.log" 2>&1 &
    echo $! > "$STATE_DIR/backend.pid"
  )

  echo "▸ 后台启动前端 $FRONTEND_DIR（端口 $FRONTEND_PORT，日志见 $STATE_DIR/frontend.log）"
  (
    cd "$WORKSPACE_DIR/$FRONTEND_DIR"
    VITE_PROXY_TARGET="http://localhost:${BACKEND_PORT}" \
    nohup pnpm run dev -- --port "$FRONTEND_PORT" --strictPort \
      > "$STATE_DIR/frontend.log" 2>&1 &
    echo $! > "$STATE_DIR/frontend.pid"
  )

  echo
  echo "✔ 已拉起本 worktree（$SLUG）专属开发环境"
  print_params
  echo
  echo "首次启动后端需要跑一遍建表+种子（几秒到几十秒），"
  echo "用 './dev.sh dev logs back' 看进度；前端就绪后访问 http://localhost:$FRONTEND_PORT"
}

dev_down() {
  echo "▸ 停止本 worktree 的应用进程（不动共享的 $MYSQL_CONTAINER/$REDIS_CONTAINER 容器）"
  kill_pid_file "$STATE_DIR/backend.pid"
  kill_pid_file "$STATE_DIR/frontend.pid"
  # 上面按 pid 杀不保证杀干净（见 kill_by_port 处的注释），按端口再补一刀兜底。
  kill_by_port "$BACKEND_PORT"
  kill_by_port "$FRONTEND_PORT"
  echo "✔ 完成。本 worktree 专属 schema（$DEV_SCHEMA）未删除——如需彻底清理："
  echo "  docker exec $MYSQL_CONTAINER mysql -uroot -p$DEV_MYSQL_ROOT_PASSWORD -e \"DROP DATABASE \\\`$DEV_SCHEMA\\\`;\""
}

dev_status() {
  print_params
  echo
  if pid_alive "$STATE_DIR/backend.pid"; then
    echo "后端: 运行中 (pid $(cat "$STATE_DIR/backend.pid"))"
  else
    echo "后端: 未运行"
  fi
  if pid_alive "$STATE_DIR/frontend.pid"; then
    echo "前端: 运行中 (pid $(cat "$STATE_DIR/frontend.pid"))"
  else
    echo "前端: 未运行"
  fi
}

dev_logs() {
  local which="${1:-}"
  case "$which" in
    back|backend) tail -f "$STATE_DIR/backend.log" ;;
    front|frontend) tail -f "$STATE_DIR/frontend.log" ;;
    *) echo "用法: dev.sh dev logs back|front" >&2; exit 1 ;;
  esac
}

# 端口能不能连上。Windows 走 .NET TcpClient（比 Test-NetConnection 快、不做 DNS），
# 其余平台走 bash 的 /dev/tcp。
port_listening() {
  local port="$1"
  if is_windows; then
    powershell -NoProfile -Command \
      "try { \$c = New-Object Net.Sockets.TcpClient; \$c.Connect('127.0.0.1', $port); \$c.Close(); exit 0 } catch { exit 1 }" \
      >/dev/null 2>&1
  else
    (exec 3<>"/dev/tcp/127.0.0.1/$port") >/dev/null 2>&1 && { exec 3>&- 3<&-; return 0; } || return 1
  fi
}

# 阻塞到应用就绪。给自动化流程用——不用人肉 `dev logs` 盯着。
# 后端：端口可连接，或日志出现 Spring Boot 的启动完成行即算就绪；
#       日志出现明确失败行则不再干等，立刻退出并把尾部日志打出来。
# 前端：端口可连接即算就绪（dev_up 用了 --strictPort，端口不会漂）。
dev_wait() {
  local what="all" timeout=180
  while [[ $# -gt 0 ]]; do
    case "$1" in
      back|backend) what="back"; shift ;;
      front|frontend) what="front"; shift ;;
      all) what="all"; shift ;;
      --timeout) timeout="${2:-180}"; shift 2 ;;
      *) echo "用法: dev.sh dev wait [back|front|all] [--timeout <秒>]" >&2; exit 1 ;;
    esac
  done

  local want_back=0 want_front=0
  [[ "$what" == "all" || "$what" == "back" ]] && want_back=1
  [[ "$what" == "all" || "$what" == "front" ]] && want_front=1

  local deadline=$(( $(date +%s) + timeout ))
  local back_ok=0 front_ok=0
  while :; do
    if [[ $want_back == 1 && $back_ok == 0 ]]; then
      if [[ -f "$STATE_DIR/backend.log" ]] \
         && grep -qE "APPLICATION FAILED TO START|Error starting ApplicationContext|BUILD FAILURE" "$STATE_DIR/backend.log"; then
        echo "✗ 后端启动失败，backend.log 尾部 30 行：" >&2
        tail -n 30 "$STATE_DIR/backend.log" >&2
        exit 1
      fi
      if port_listening "$BACKEND_PORT" \
         || { [[ -f "$STATE_DIR/backend.log" ]] \
              && grep -qE "Started .* in [0-9].* seconds|Tomcat started on port" "$STATE_DIR/backend.log"; }; then
        back_ok=1; echo "✔ 后端就绪（端口 $BACKEND_PORT）"
      fi
    fi
    if [[ $want_front == 1 && $front_ok == 0 ]] && port_listening "$FRONTEND_PORT"; then
      front_ok=1; echo "✔ 前端就绪（端口 $FRONTEND_PORT）"
    fi
    if [[ ( $want_back == 0 || $back_ok == 1 ) && ( $want_front == 0 || $front_ok == 1 ) ]]; then
      return 0
    fi
    if [[ $(date +%s) -ge $deadline ]]; then
      echo "✗ 等待超时（${timeout}s）：后端就绪=$back_ok 前端就绪=$front_ok" >&2
      [[ $want_back == 1 && $back_ok == 0 && -f "$STATE_DIR/backend.log" ]] \
        && { echo "--- backend.log 尾部 ---" >&2; tail -n 30 "$STATE_DIR/backend.log" >&2; }
      [[ $want_front == 1 && $front_ok == 0 && -f "$STATE_DIR/frontend.log" ]] \
        && { echo "--- frontend.log 尾部 ---" >&2; tail -n 30 "$STATE_DIR/frontend.log" >&2; }
      exit 1
    fi
    sleep 2
  done
}

usage() { sed -n '2,38p' "$0"; }

main() {
  local group="${1:-}"; shift || true
  case "$group" in
    slug) print_params ;;
    dev)
      case "${1:-}" in
        up) dev_up ;;
        down) dev_down ;;
        status) dev_status ;;
        wait) shift; dev_wait "$@" ;;
        logs) shift; dev_logs "${1:-}" ;;
        *) usage; exit 1 ;;
      esac
      ;;
    --help|-h|"") usage ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
