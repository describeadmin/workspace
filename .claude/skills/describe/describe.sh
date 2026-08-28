#!/usr/bin/env bash
#
# describe skill 的薄脚手架：只做「每次都一样、且容易写错」的 git worktree 管道，
# 判断类的事（出计划、写代码、决定测什么）全部留在 SKILL.md 交给 AI。
#
# ---------------------------------------------------------------------------
# 它是 describeadmin `workspace` 仓库的一部分，随 `init-workspace.sh` 落进业务方工作空间
# （`<workspace>/.claude/skills/describe/describe.sh`）。和 `dev-env` 一样，它从
# `<workspace>/.claude/workspace.env` 读 BACKEND_DIR / FRONTEND_DIR / PROJECT_NAME，
# 不写死任何项目名。
#
# 心智模型：`describe.sh new` == 「`init-workspace.sh` 的 worktree 版」。
#   工作空间根目录本身不是 git 仓库，里面 <name>-server / <name>-web 是两个独立仓库。
#   `new` 对这两个仓各拉一个 git worktree 到 `<workspace>/.worktrees/<slug>/` 下，
#   再把 `.claude/` + `CLAUDE.md` 拷过去，于是 `.worktrees/<slug>/` 就是一个
#   完整的、可独立跑 dev-env / visual-test 的「工作空间形状」目录。
#   dev-env 的 slug 取工作区绝对路径 hash —— 新路径天然得到独立端口/DB schema，
#   共享的 MySQL/Redis 容器则因 PROJECT_NAME 不变而复用。零改动即隔离。
#
# 用法：
#   ./describe.sh new <slug> [--base <branch>] [--init-repos]
#         建双 worktree 工作区。slug 只允许小写字母/数字/短横线，字母开头。
#         --base       两个子仓都从这个分支切出（默认：各仓自动探测
#                      origin/HEAD -> 本地 main -> 本地 master -> 当前分支）
#         --init-repos 子仓还不是 git 仓库时，代为 git init + 首次提交
#   ./describe.sh list
#         列出当前所有 describe worktree
#   ./describe.sh land <slug>
#         把 describe/<slug> 合并回两个子仓各自的 base 分支（本地 --no-ff，不 push），
#         成功后自动清理 worktree。冲突则停下、如实报告，可解决后重跑。
#   ./describe.sh clean <slug> [--force]
#         停服务 -> 摘 worktree -> 删分支 -> 删目录。无 --force 时，worktree 里
#         有未提交的【已跟踪】改动会拒绝执行。
#
# ⚠️ 只在【主工作区】跑 `new`，不要在 `.worktrees/*` 里再套一层（脚本会自检拦下）。
# ---------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
WORKSPACE_ENV="$WORKSPACE_DIR/.claude/workspace.env"

die() { echo "✗ $*" >&2; exit 1; }

[[ -f "$WORKSPACE_ENV" ]] || die "找不到 $WORKSPACE_ENV（应由 init-workspace.sh 生成；手工拼的工作空间自己补三行 BACKEND_DIR/FRONTEND_DIR/PROJECT_NAME）"
# shellcheck disable=SC1090
source "$WORKSPACE_ENV"
: "${BACKEND_DIR:?workspace.env 缺 BACKEND_DIR}"
: "${FRONTEND_DIR:?workspace.env 缺 FRONTEND_DIR}"
: "${PROJECT_NAME:?workspace.env 缺 PROJECT_NAME}"

WORKTREES_DIR="$WORKSPACE_DIR/.worktrees"

is_windows() {
  case "${OS:-}${OSTYPE:-}" in
    *Windows_NT*|*msys*|*cygwin*|*MINGW*) return 0 ;;
    *) return 1 ;;
  esac
}

# --- 一个提交所需的 git 身份：用户配了就用用户的，没配才兜一个本地值 ---
git_commit() {
  local path="$1" msg="$2"
  if [[ -n "$(git -C "$path" config user.email 2>/dev/null || true)" ]]; then
    git -C "$path" commit -q -m "$msg"
  else
    git -C "$path" -c user.name="describe" -c user.email="describe@localhost" commit -q -m "$msg"
  fi
}

# --- 子仓必须是「有至少一个提交的 git 仓库」，否则 git worktree 无从谈起 ---
ensure_repo_ready() {
  local dir="$1" path="$WORKSPACE_DIR/$1"
  [[ -d "$path" ]] || die "找不到子项目目录：$path"
  if ! git -C "$path" rev-parse --git-dir >/dev/null 2>&1; then
    if [[ "$INIT_REPOS" == "1" ]]; then
      echo "▸ $dir 还不是 git 仓库，--init-repos：git init + 首次提交" >&2
      git -C "$path" init -b main >/dev/null
      git -C "$path" add -A
      git_commit "$path" "chore: initial commit"
    else
      die "$dir 还不是 git 仓库。先执行：
    cd \"$path\" && git init -b main && git add -A && git commit -m \"chore: initial commit\"
  或给 new 加 --init-repos 让本脚本代做。"
    fi
  fi
  if ! git -C "$path" rev-parse HEAD >/dev/null 2>&1; then
    if [[ "$INIT_REPOS" == "1" ]]; then
      git -C "$path" add -A
      git_commit "$path" "chore: initial commit"
    else
      die "$dir 是 git 仓库但没有任何提交。先 git add -A && git commit，或用 --init-repos。"
    fi
  fi
}

# --- 解析 base 分支（每个子仓各算一次）：--base 优先，否则自动探测 ---
resolve_base() {
  local dir="$1" path="$WORKSPACE_DIR/$1"
  if [[ -n "$BASE_OVERRIDE" ]]; then
    git -C "$path" rev-parse --verify --quiet "$BASE_OVERRIDE" >/dev/null \
      || die "$dir 里找不到分支/提交：$BASE_OVERRIDE"
    printf '%s' "$BASE_OVERRIDE"; return
  fi
  local head
  head="$(git -C "$path" symbolic-ref --short -q refs/remotes/origin/HEAD 2>/dev/null || true)"
  if [[ -n "$head" ]]; then printf '%s' "${head#origin/}"; return; fi
  local b
  for b in main master; do
    git -C "$path" rev-parse --verify --quiet "$b" >/dev/null && { printf '%s' "$b"; return; }
  done
  head="$(git -C "$path" symbolic-ref --short -q HEAD 2>/dev/null || true)"
  [[ -n "$head" ]] || die "$dir 处于 detached HEAD 且未指定 --base"
  printf '%s' "$head"
}

port_in_use() {
  local port="$1"
  if is_windows; then
    powershell -NoProfile -Command \
      "try { \$c = New-Object Net.Sockets.TcpClient; \$c.Connect('127.0.0.1', $port); \$c.Close(); exit 0 } catch { exit 1 }" \
      >/dev/null 2>&1
  else
    (exec 3<>"/dev/tcp/127.0.0.1/$port") >/dev/null 2>&1 && { exec 3>&- 3<&- ; return 0; } || return 1
  fi
}

cmd_new() {
  local slug=""
  BASE_OVERRIDE=""
  INIT_REPOS=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --base) BASE_OVERRIDE="${2:-}"; [[ -n "$BASE_OVERRIDE" ]] || die "--base 后面要跟分支名"; shift 2 ;;
      --init-repos) INIT_REPOS=1; shift ;;
      -*) die "未知参数：$1" ;;
      *) [[ -z "$slug" ]] && slug="$1" || die "多余参数：$1"; shift ;;
    esac
  done
  [[ -n "$slug" ]] || die "用法：describe.sh new <slug> [--base <branch>] [--init-repos]"
  [[ "$slug" =~ ^[a-z][a-z0-9-]*$ ]] || die "slug 只允许小写字母/数字/短横线，且字母开头（当前：$slug）"

  case "$WORKSPACE_DIR" in
    */.worktrees/*) die "当前已在一个 describe worktree 内（$WORKSPACE_DIR）。回主工作区再 new。" ;;
  esac

  local wt_root="$WORKTREES_DIR/$slug"
  local branch="describe/$slug"
  [[ -e "$wt_root" ]] && die "$wt_root 已存在。先 describe.sh clean $slug，或换一个 slug。"

  local d
  for d in "$BACKEND_DIR" "$FRONTEND_DIR"; do
    ensure_repo_ready "$d"
    git -C "$WORKSPACE_DIR/$d" rev-parse --verify --quiet "$branch" >/dev/null \
      && die "$d 已存在分支 $branch。先 describe.sh clean $slug，或换 slug。"
  done

  local base_backend base_frontend
  base_backend="$(resolve_base "$BACKEND_DIR")"
  base_frontend="$(resolve_base "$FRONTEND_DIR")"

  mkdir -p "$wt_root"
  echo "▸ $BACKEND_DIR：worktree add（-b $branch，从 $base_backend 切出）"
  git -C "$WORKSPACE_DIR/$BACKEND_DIR" worktree add "$wt_root/$BACKEND_DIR" -b "$branch" "$base_backend" >&2
  echo "▸ $FRONTEND_DIR：worktree add（-b $branch，从 $base_frontend 切出）"
  git -C "$WORKSPACE_DIR/$FRONTEND_DIR" worktree add "$wt_root/$FRONTEND_DIR" -b "$branch" "$base_frontend" >&2

  echo "▸ 拷 .claude/ + CLAUDE.md，重置 dev-env 运行状态"
  cp -r "$WORKSPACE_DIR/.claude" "$wt_root/"
  rm -rf "$wt_root/.claude/skills/dev-env/.worktree"
  [[ -f "$WORKSPACE_DIR/CLAUDE.md" ]] && cp "$WORKSPACE_DIR/CLAUDE.md" "$wt_root/"

  mkdir -p "$wt_root/inputs" "$wt_root/notes" "$wt_root/.describe"
  cat > "$wt_root/.describe/meta.env" <<EOF
SLUG=$slug
BRANCH=$branch
BASE_BACKEND=$base_backend
BASE_FRONTEND=$base_frontend
BACKEND_DIR=$BACKEND_DIR
FRONTEND_DIR=$FRONTEND_DIR
CREATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

  echo
  echo "✔ describe worktree 就绪：$wt_root"
  echo "  分支：$branch（$BACKEND_DIR 从 $base_backend，$FRONTEND_DIR 从 $base_frontend）"
  echo "  参考材料丢进：$wt_root/inputs/"
  echo "  计划/报告写在：$wt_root/notes/"
  echo
  echo "--- 本 worktree 的 dev-env 隔离参数 ---"
  ( cd "$wt_root" && bash .claude/skills/dev-env/dev.sh slug ) || true

  local off port_b port_f
  off=$(( (16#$(printf '%s' "$wt_root" | { command -v sha1sum >/dev/null 2>&1 && sha1sum || shasum; } | cut -c1-4) % 100) * 5 ))
  port_b=$((8090 + off)); port_f=$((5777 + off))
  if port_in_use "$port_b" || port_in_use "$port_f"; then
    echo
    echo "⚠ 算出的后端($port_b)/前端($port_f)端口已被占用（可能与另一个 worktree 撞车，dev-env 的 hash 有 1/100 概率碰撞）。"
    echo "  起环境时用 SERVER_PORT= / 前端 --port 覆盖，或换一个 slug。"
  fi
}

cmd_list() {
  if [[ ! -d "$WORKTREES_DIR" ]] || [[ -z "$(ls -A "$WORKTREES_DIR" 2>/dev/null || true)" ]]; then
    echo "（没有 describe worktree）"
    return
  fi
  local d meta
  for d in "$WORKTREES_DIR"/*/; do
    meta="${d}.describe/meta.env"
    [[ -f "$meta" ]] || { echo "?  ${d}（无 .describe/meta.env，可能是残留）"; continue; }
    ( # shellcheck disable=SC1090
      source "$meta"
      printf '%-18s  %-22s  base %s / %s  建于 %s\n' \
        "$SLUG" "$BRANCH" "$BASE_BACKEND" "$BASE_FRONTEND" "$CREATED_AT" )
  done
  echo
  echo "--- git worktree list（$BACKEND_DIR）---"
  git -C "$WORKSPACE_DIR/$BACKEND_DIR" worktree list || true
  echo "--- git worktree list（$FRONTEND_DIR）---"
  git -C "$WORKSPACE_DIR/$FRONTEND_DIR" worktree list || true
}

merge_one() {
  local dir="$1" base="$2" branch="$3" slug="$4" p="$WORKSPACE_DIR/$1"
  echo "▸ $dir：checkout $base，merge --no-ff $branch"
  git -C "$p" checkout "$base" >&2 || die "$dir checkout $base 失败"
  if ! git -C "$p" merge --no-ff "$branch" -m "Merge $branch into $base (describe)" >&2; then
    echo >&2
    echo "✗ $dir 合并 $branch 冲突，已停止（另一个仓未处理）。" >&2
    echo "  解决后：cd \"$p\" && git add -A && git commit，再重跑 describe.sh land $slug" >&2
    echo "  放弃本次合并：cd \"$p\" && git merge --abort" >&2
    exit 1
  fi
}

cmd_land() {
  local slug="${1:-}"
  [[ -n "$slug" ]] || die "用法：describe.sh land <slug>"
  local wt_root="$WORKTREES_DIR/$slug"
  local meta="$wt_root/.describe/meta.env"
  [[ -f "$meta" ]] || die "找不到 $meta，$slug 不是一个 describe worktree？"
  # shellcheck disable=SC1090
  source "$meta"

  local d
  for d in "$BACKEND_DIR" "$FRONTEND_DIR"; do
    [[ -z "$(git -C "$WORKSPACE_DIR/$d" status --porcelain)" ]] \
      || die "$d 主工作目录有未提交改动，先处理干净再 land。"
  done

  merge_one "$BACKEND_DIR"  "$BASE_BACKEND"  "$BRANCH" "$slug"
  merge_one "$FRONTEND_DIR" "$BASE_FRONTEND" "$BRANCH" "$slug"

  echo
  echo "✔ 两个仓都已 --no-ff 合并 $BRANCH 进各自 base（本地，未 push）"
  _clean "$slug" 1

  echo
  for d in "$BACKEND_DIR" "$FRONTEND_DIR"; do
    local p="$WORKSPACE_DIR/$d"
    if git -C "$p" remote 2>/dev/null | grep -q .; then
      echo "  待你确认后推送：cd \"$p\" && git push origin $(git -C "$p" symbolic-ref --short -q HEAD || true)"
    fi
  done
}

# _clean <slug> <force 0|1>
_clean() {
  local slug="$1" force="${2:-0}"
  local wt_root="$WORKTREES_DIR/$slug"
  local meta="$wt_root/.describe/meta.env"
  local bdir="$BACKEND_DIR" fdir="$FRONTEND_DIR" branch="describe/$slug"
  if [[ -f "$meta" ]]; then
    # shellcheck disable=SC1090
    source "$meta"; bdir="$BACKEND_DIR"; fdir="$FRONTEND_DIR"; branch="$BRANCH"
  fi

  if [[ "$force" != "1" ]]; then
    local sub wp
    for sub in "$bdir" "$fdir"; do
      wp="$wt_root/$sub"
      [[ -d "$wp" ]] || continue
      [[ -z "$(git -C "$wp" status --porcelain --untracked-files=no 2>/dev/null || true)" ]] \
        || die "$wp 有未提交的【已跟踪】改动。确认丢弃就加 --force。"
    done
  fi

  # 1. 先停本 worktree 的后端/前端进程 —— 必须在 worktree remove 之前，
  #    否则 Windows 上 java/node 还占着文件，remove 会失败。
  if [[ -f "$wt_root/.claude/skills/dev-env/dev.sh" ]]; then
    ( cd "$wt_root" && bash .claude/skills/dev-env/dev.sh dev down ) >/dev/null 2>&1 || true
  fi
  # 2. 摘 worktree（build 产物这类未跟踪文件是噪音，一律 --force 摘）
  git -C "$WORKSPACE_DIR/$bdir" worktree remove --force "$wt_root/$bdir" 2>/dev/null || true
  git -C "$WORKSPACE_DIR/$fdir" worktree remove --force "$wt_root/$fdir" 2>/dev/null || true
  # 3. 删分支（-d 只删已合并的；--force 才 -D 强删）
  local delflag="-d"; [[ "$force" == "1" ]] && delflag="-D"
  git -C "$WORKSPACE_DIR/$bdir" branch "$delflag" "$branch" 2>/dev/null \
    || echo "  （$bdir 的 $branch 未删：可能未合并，需要时手动 git branch -D $branch）" >&2
  git -C "$WORKSPACE_DIR/$fdir" branch "$delflag" "$branch" 2>/dev/null \
    || echo "  （$fdir 的 $branch 未删：可能未合并，需要时手动 git branch -D $branch）" >&2
  # 4. 删目录 + 清 worktree 元数据
  rm -rf "$wt_root"
  git -C "$WORKSPACE_DIR/$bdir" worktree prune 2>/dev/null || true
  git -C "$WORKSPACE_DIR/$fdir" worktree prune 2>/dev/null || true
  echo "✔ 已清理 describe worktree：$slug"
}

cmd_clean() {
  local slug="" force=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force) force=1; shift ;;
      -*) die "未知参数：$1" ;;
      *) [[ -z "$slug" ]] && slug="$1" || die "多余参数：$1"; shift ;;
    esac
  done
  [[ -n "$slug" ]] || die "用法：describe.sh clean <slug> [--force]"

  local exists=0
  [[ -d "$WORKTREES_DIR/$slug" ]] && exists=1
  git -C "$WORKSPACE_DIR/$BACKEND_DIR"  rev-parse --verify --quiet "describe/$slug" >/dev/null 2>&1 && exists=1
  git -C "$WORKSPACE_DIR/$FRONTEND_DIR" rev-parse --verify --quiet "describe/$slug" >/dev/null 2>&1 && exists=1
  [[ "$exists" == "1" ]] || die "找不到 .worktrees/$slug，也没有 describe/$slug 分支"

  _clean "$slug" "$force"
}

usage() { sed -n '2,49p' "$0"; }

main() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    new)   cmd_new "$@" ;;
    list)  cmd_list ;;
    land)  cmd_land "$@" ;;
    clean) cmd_clean "$@" ;;
    --help|-h|"") usage ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
