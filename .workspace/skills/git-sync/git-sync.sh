#!/usr/bin/env bash
#
# git-sync skill 的薄脚手架：把「同一个 git 操作在前后端两个仓库各做一遍」这件
# 每次都一样、又容易只做一半的事，收成一条命令。判断类的事（写提交信息）留在
# WORKFLOW.md 交给 AI。
#
# ---------------------------------------------------------------------------
# 它是 describeadmin `workspace` 仓库的一部分，随 init-workspace.sh 落进业务方
# 工作空间（<workspace>/.workspace/skills/git-sync/git-sync.sh）。和 dev-env /
# describe 一样，从 <workspace>/.workspace/workspace.env 读 BACKEND_DIR /
# FRONTEND_DIR / PROJECT_NAME，不写死任何项目名。
#
# 心智模型：工作空间根目录不是 git 仓库，<name>-server / <name>-web 是两个各自
#   独立的仓库。本脚本对这两个仓库的【主工作目录】做联动的分支操作，让它们的
#   当前分支保持一致。它【不碰 git worktree】——隔离沙箱是 describe skill 的事。
#
# 两条铁律：
#   1. 先预检、后改动：会改状态的子命令，先确认两个仓库都能成功，再动任何一个，
#      避免「后端切到了 dev、前端切失败」的半成品。
#   2. push / pull 例外：面对两个独立远程，一成一败不回滚，逐仓报告交用户处置。
#
# 用法见 usage()（`git-sync.sh` 不带参数即打印）。
# ---------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
WORKSPACE_ENV="$WORKSPACE_DIR/.workspace/workspace.env"

die()  { echo "✗ $*" >&2; exit 1; }
info() { echo "▸ $*" >&2; }
warn() { echo "⚠ $*" >&2; }

usage() {
  cat >&2 <<'EOF'
git-sync — 前后端两个仓库的 git 分支联动

  git-sync.sh status
      两仓当前分支 / 领先落后 / 脏文件 / 最后提交；分支不一致则告警
  git-sync.sh list
      两仓本地分支合成一张表，标出当前分支与「只在一个仓库存在」的分支
  git-sync.sh new <branch> [--from <ref>] [--dry-run]
      两仓一起新建 <branch> 并切过去（--from 指定基点，需在两仓都能解析）
  git-sync.sh co <branch> [--dry-run]              别名：switch / checkout
      两仓一起切到已存在的 <branch>；工作区脏则拦下
  git-sync.sh rm <branch> [--force] [--dry-run]    别名：delete
      两仓一起删 <branch>；--force 删未合并 / 越过脏拦截 / 允许 main|master
  git-sync.sh commit --show
      逐仓打印 status + diff HEAD，供 AI 阅读后写提交信息
  git-sync.sh commit [--backend-msg S | --backend-file P]
                     [--frontend-msg S | --frontend-file P]
                     [--message S | --message-file P] [--no-add] [--dry-run]
      两仓各 add -A + commit；信息由调用方给，干净的仓自动跳过
  git-sync.sh push [--dry-run]
      两仓当前分支各 push -u origin <branch>（对外操作）
  git-sync.sh pull [--no-rebase] [--dry-run]
      两仓各 pull --rebase；工作区脏 / 无 upstream 则拦下

会改状态的子命令都支持 --dry-run（只打印将执行的 git 命令）。
隔离 worktree 并行开发是 describe skill 的事，本脚本只在主工作目录操作。
EOF
}

[[ -f "$WORKSPACE_ENV" ]] || die "找不到 $WORKSPACE_ENV（应由 init-workspace.sh 生成；手工拼的工作空间自己补 BACKEND_DIR/FRONTEND_DIR/PROJECT_NAME 三行）"
# shellcheck disable=SC1090
source "$WORKSPACE_ENV"
: "${BACKEND_DIR:?workspace.env 缺 BACKEND_DIR}"
: "${FRONTEND_DIR:?workspace.env 缺 FRONTEND_DIR}"
: "${PROJECT_NAME:?workspace.env 缺 PROJECT_NAME}"

BACKEND_PATH="$WORKSPACE_DIR/$BACKEND_DIR"
FRONTEND_PATH="$WORKSPACE_DIR/$FRONTEND_DIR"
# 遍历顺序固定：后端在前，前端在后（报告可读性一致）
REPOS=("$BACKEND_DIR" "$FRONTEND_DIR")

DRY_RUN=0

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

ensure_git_repo() {
  local dir="$1" p="$WORKSPACE_DIR/$1"
  [[ -d "$p" ]] || die "找不到子项目目录：$p（workspace.env 里的 $dir 对不上？）"
  git -C "$p" rev-parse --git-dir >/dev/null 2>&1 || die "$dir 不是 git 仓库。"
  git -C "$p" rev-parse HEAD    >/dev/null 2>&1 || die "$dir 还没有任何提交。"
}

cur_branch() { git -C "$1" symbolic-ref --short -q HEAD 2>/dev/null || true; }

local_branch_exists()  { git -C "$1" rev-parse --verify --quiet "refs/heads/$2" >/dev/null 2>&1; }
origin_branch_exists() { git -C "$1" rev-parse --verify --quiet "refs/remotes/origin/$2" >/dev/null 2>&1; }
has_remote()           { [[ -n "$(git -C "$1" remote 2>/dev/null)" ]]; }
has_upstream()         { git -C "$1" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' >/dev/null 2>&1; }

is_dirty() { [[ -n "$(git -C "$1" status --porcelain 2>/dev/null)" ]]; }

# 分支是否正被【另一个】worktree 占用（主 worktree 是列表里第一个）
branch_in_other_worktree() {
  git -C "$1" worktree list --porcelain 2>/dev/null | awk -v b="refs/heads/$2" '
    $1=="worktree"  {n++}
    $1=="branch" && $2==b && n>1 {found=1}
    END {exit found ? 0 : 1}'
}

validate_branch_name() {
  local b="$1"
  case "$b" in
    -*|*..*|*" "*|*"~"*|*"^"*|*":"*|*"?"*|*"*"*|*"["*|*'\'*)
      die "非法分支名：$b" ;;
  esac
  git -C "$BACKEND_PATH" check-ref-format --branch "$b" >/dev/null 2>&1 || die "非法分支名：$b"
}

# git_commit <path> <-m|-F> <msg-or-file>：用户配了 git 身份就用，没配兜一个本地值
git_commit() {
  local path="$1" flag="$2" val="$3"
  if [[ -z "$(git -C "$path" config user.email 2>/dev/null || true)" ]]; then
    git -C "$path" -c user.name="git-sync" -c user.email="git-sync@localhost" commit -q "$flag" "$val"
  else
    git -C "$path" commit -q "$flag" "$val"
  fi
}

# 两仓分支不一致时给一句告警（不阻断）
warn_drift() {
  local b f
  b="$(cur_branch "$BACKEND_PATH")"
  f="$(cur_branch "$FRONTEND_PATH")"
  if [[ -n "$b" && -n "$f" && "$b" != "$f" ]]; then
    warn "两仓当前分支不一致：$BACKEND_DIR@[$b] / $FRONTEND_DIR@[$f]"
  fi
}

# 打印一条将执行 / 已跳过的 git 行（dry-run 用）
dryrun_echo() { echo "  [dry-run] $*"; }

# ---------------------------------------------------------------------------
# status
# ---------------------------------------------------------------------------

cmd_status() {
  [[ $# -eq 0 ]] || die "status 不接受参数"
  local ref="" first=1 drift=0
  for dir in "${REPOS[@]}"; do
    local p="$WORKSPACE_DIR/$dir"
    ensure_git_repo "$dir"
    local cur up ahead behind porc
    cur="$(cur_branch "$p")"
    [[ -n "$cur" ]] || cur="(detached)"
    echo "── $dir ──"
    echo "  分支：$cur"
    up="$(git -C "$p" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"
    if [[ -n "$up" ]]; then
      behind=0; ahead=0
      read -r behind ahead < <(git -C "$p" rev-list --left-right --count "$up"...HEAD 2>/dev/null || echo "0 0")
      echo "  upstream：$up（领先 ${ahead:-0} / 落后 ${behind:-0}）"
    else
      echo "  upstream：未设置"
    fi
    porc="$(git -C "$p" status --porcelain)"
    if [[ -n "$porc" ]]; then
      # 直接数 porcelain：第 1 列非空=已暂存，第 2 列非空=未暂存，?? =未跟踪
      local st=0 un=0 ut=0 line
      while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        if [[ "$line" == '??'* ]]; then
          ut=$((ut + 1))
        else
          if [[ "${line:0:1}" != ' ' ]]; then st=$((st + 1)); fi
          if [[ "${line:1:1}" != ' ' ]]; then un=$((un + 1)); fi
        fi
      done <<< "$porc"
      echo "  改动：已暂存 $st / 未暂存 $un / 未跟踪 $ut"
      echo "$porc" | sed 's/^/    /'
    else
      echo "  改动：干净"
    fi
    echo "  最后提交：$(git -C "$p" log -1 --oneline 2>/dev/null || echo '（无提交）')"
    echo
    if [[ "$first" == "1" ]]; then
      ref="$cur"; first=0
    elif [[ "$cur" != "$ref" ]]; then
      drift=1
    fi
  done
  if [[ "$drift" == "1" ]]; then
    warn "两个仓库当前分支不一致（drift）。git-sync.sh co <branch> 对齐，或确认这是有意为之。"
  fi
}

# ---------------------------------------------------------------------------
# list
# ---------------------------------------------------------------------------

cmd_list() {
  [[ $# -eq 0 ]] || die "list 不接受参数"
  ensure_git_repo "$BACKEND_DIR"
  ensure_git_repo "$FRONTEND_DIR"
  local bcur fcur all br only=""
  bcur="$(cur_branch "$BACKEND_PATH")"
  fcur="$(cur_branch "$FRONTEND_PATH")"
  all="$({ git -C "$BACKEND_PATH"  for-each-ref --format='%(refname:short)' refs/heads
           git -C "$FRONTEND_PATH" for-each-ref --format='%(refname:short)' refs/heads
         } | sort -u)"
  echo "  backend  = $BACKEND_DIR"
  echo "  frontend = $FRONTEND_DIR"
  echo
  printf '  %-34s  %-9s  %-9s\n' "branch" "backend" "frontend"
  while IFS= read -r br; do
    [[ -n "$br" ]] || continue
    local bh="no" fh="no" bcell fcell
    if local_branch_exists "$BACKEND_PATH"  "$br"; then bh="yes"; fi
    if local_branch_exists "$FRONTEND_PATH" "$br"; then fh="yes"; fi
    bcell="$bh"; if [[ "$br" == "$bcur" ]]; then bcell="* HEAD"; fi
    fcell="$fh"; if [[ "$br" == "$fcur" ]]; then fcell="* HEAD"; fi
    printf '  %-34s  %-9s  %-9s\n' "$br" "$bcell" "$fcell"
    if [[ "$bh" != "$fh" ]]; then only+="$br "; fi
  done <<< "$all"
  echo
  if [[ -n "$bcur" && -n "$fcur" && "$bcur" != "$fcur" ]]; then
    warn "drift：$BACKEND_DIR 在 [$bcur]，$FRONTEND_DIR 在 [$fcur]。git-sync.sh co <branch> 对齐。"
  fi
  if [[ -n "$only" ]]; then
    warn "只在一个仓库存在的分支：$only"
  fi
}

# ---------------------------------------------------------------------------
# new <branch> [--from <ref>]
# ---------------------------------------------------------------------------

cmd_new() {
  local branch="" from=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from)    from="${2:-}"; [[ -n "$from" ]] || die "--from 后要跟 ref"; shift 2 ;;
      --dry-run) DRY_RUN=1; shift ;;
      -*)        die "未知参数：$1" ;;
      *)         [[ -z "$branch" ]] && branch="$1" || die "多余参数：$1"; shift ;;
    esac
  done
  [[ -n "$branch" ]] || die "用法：git-sync.sh new <branch> [--from <ref>] [--dry-run]"
  validate_branch_name "$branch"

  for dir in "${REPOS[@]}"; do
    local p="$WORKSPACE_DIR/$dir"
    ensure_git_repo "$dir"
    if local_branch_exists "$p" "$branch"; then
      die "$dir 已存在分支 $branch。切过去用 git-sync.sh co $branch；要重建先 git-sync.sh rm $branch。"
    fi
    if [[ -n "$from" ]] && ! git -C "$p" rev-parse --verify --quiet "$from" >/dev/null 2>&1; then
      die "$dir 里找不到基点 ref：$from"
    fi
  done

  for dir in "${REPOS[@]}"; do
    local n
    n="$(git -C "$WORKSPACE_DIR/$dir" status --porcelain | grep -c . || true)"
    if [[ "$n" -gt 0 ]]; then
      warn "$dir 有 $n 个未提交改动，会一起带到新分支 $branch"
    fi
  done

  for dir in "${REPOS[@]}"; do
    local p="$WORKSPACE_DIR/$dir"
    info "$dir：git switch -c $branch ${from:-（从当前 HEAD）}"
    if [[ "$DRY_RUN" == "1" ]]; then
      dryrun_echo "git -C \"$p\" switch -c $branch${from:+ $from}"
    elif [[ -n "$from" ]]; then
      git -C "$p" switch -c "$branch" "$from"
    else
      git -C "$p" switch -c "$branch"
    fi
  done
  if [[ "$DRY_RUN" != "1" ]]; then
    echo "✔ 两个仓库都已在新分支 $branch"
  fi
}

# ---------------------------------------------------------------------------
# co <branch>   (switch / checkout)
# ---------------------------------------------------------------------------

cmd_co() {
  local branch=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) DRY_RUN=1; shift ;;
      -*)        die "未知参数：$1" ;;
      *)         [[ -z "$branch" ]] && branch="$1" || die "多余参数：$1"; shift ;;
    esac
  done
  [[ -n "$branch" ]] || die "用法：git-sync.sh co <branch> [--dry-run]"

  local missing=() locked=()
  for dir in "${REPOS[@]}"; do
    local p="$WORKSPACE_DIR/$dir"
    ensure_git_repo "$dir"
    if ! local_branch_exists "$p" "$branch" && ! origin_branch_exists "$p" "$branch"; then
      missing+=("$dir")
    fi
    if branch_in_other_worktree "$p" "$branch"; then
      locked+=("$dir")
    fi
  done
  if [[ ${#missing[@]} -eq ${#REPOS[@]} ]]; then
    die "两个仓库都没有分支 $branch。要新建用 git-sync.sh new $branch。"
  fi
  if [[ ${#missing[@]} -gt 0 ]]; then
    die "分支 $branch 只在一个仓库存在（缺：${missing[*]}）——这是 drift。
  先对齐：git-sync.sh new $branch（两仓一起建），或手动在缺的仓库处理后再 co。"
  fi
  if [[ ${#locked[@]} -gt 0 ]]; then
    die "${locked[*]} 的分支 $branch 正被另一个 git worktree 占用，无法在主目录切过去。
  （describe 的 worktree？用 .workspace/skills/describe/describe.sh list 查看。）"
  fi

  local dirty=()
  for dir in "${REPOS[@]}"; do
    if is_dirty "$WORKSPACE_DIR/$dir"; then dirty+=("$dir"); fi
  done
  if [[ ${#dirty[@]} -gt 0 ]]; then
    echo "✗ 以下仓库工作区有未提交改动，切分支前先处理：" >&2
    for dir in "${dirty[@]}"; do
      echo "── $dir ──" >&2
      git -C "$WORKSPACE_DIR/$dir" status --porcelain | sed 's/^/    /' >&2
    done
    die "用 git-sync.sh commit 一起提交，或各自 git stash 后再 co。"
  fi

  for dir in "${REPOS[@]}"; do
    local p="$WORKSPACE_DIR/$dir"
    info "$dir：git switch $branch"
    if [[ "$DRY_RUN" == "1" ]]; then
      dryrun_echo "git -C \"$p\" switch $branch"
    elif ! git -C "$p" switch "$branch"; then
      die "$dir 切换失败（见上方 git 输出）。另一个仓库可能已切换——用 git-sync.sh status 查 drift。"
    fi
  done
  if [[ "$DRY_RUN" != "1" ]]; then
    echo "✔ 两个仓库都已切到 $branch"
  fi
}

# ---------------------------------------------------------------------------
# rm <branch>   (delete)
# ---------------------------------------------------------------------------

cmd_rm() {
  local branch="" force=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force)   force=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      -*)        die "未知参数：$1" ;;
      *)         [[ -z "$branch" ]] && branch="$1" || die "多余参数：$1"; shift ;;
    esac
  done
  [[ -n "$branch" ]] || die "用法：git-sync.sh rm <branch> [--force] [--dry-run]"
  if [[ "$branch" == "main" || "$branch" == "master" ]] && [[ "$force" != "1" ]]; then
    die "拒绝删除受保护分支 $branch。真要删加 --force。"
  fi

  local present=() on_it=()
  for dir in "${REPOS[@]}"; do
    local p="$WORKSPACE_DIR/$dir"
    ensure_git_repo "$dir"
    if local_branch_exists "$p" "$branch"; then
      present+=("$dir")
      if [[ "$(cur_branch "$p")" == "$branch" ]]; then on_it+=("$dir"); fi
    fi
  done
  [[ ${#present[@]} -gt 0 ]] || die "两个仓库都没有分支 $branch，无事可做。"
  if [[ ${#present[@]} -eq 1 ]]; then
    warn "分支 $branch 只在 ${present[0]} 存在——只删这一个。"
  fi
  if [[ ${#on_it[@]} -gt 0 ]]; then
    die "$branch 是 ${on_it[*]} 的当前分支，不能删。先 git-sync.sh co <别的分支> 走开。"
  fi

  if [[ "$force" != "1" ]]; then
    local dirty=()
    for dir in "${present[@]}"; do
      if is_dirty "$WORKSPACE_DIR/$dir"; then dirty+=("$dir"); fi
    done
    if [[ ${#dirty[@]} -gt 0 ]]; then
      die "${dirty[*]} 工作区有未提交改动。删分支不碰工作区，确认无碍可加 --force 越过。"
    fi
  fi

  local delflag="-d"
  if [[ "$force" == "1" ]]; then delflag="-D"; fi
  for dir in "${present[@]}"; do
    local p="$WORKSPACE_DIR/$dir"
    info "$dir：git branch $delflag $branch"
    if [[ "$DRY_RUN" == "1" ]]; then
      dryrun_echo "git -C \"$p\" branch $delflag $branch"
    elif ! git -C "$p" branch "$delflag" "$branch"; then
      die "$dir 删除失败（分支未完全合并？确认要丢弃就加 --force）。"
    fi
  done
  if [[ "$DRY_RUN" == "1" ]]; then
    return 0
  fi
  echo "✔ 分支 $branch 已在 ${present[*]} 删除"
  for dir in "${present[@]}"; do
    local p="$WORKSPACE_DIR/$dir"
    if origin_branch_exists "$p" "$branch"; then
      echo "  远程还留着：cd \"$p\" && git push origin --delete $branch"
    fi
  done
}

# ---------------------------------------------------------------------------
# commit
# ---------------------------------------------------------------------------

cmd_commit() {
  local show=0 no_add=0
  local bmsg="" bfile="" fmsg="" ffile="" msg="" msgfile=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --show)            show=1; shift ;;
      --no-add)          no_add=1; shift ;;
      --dry-run)         DRY_RUN=1; shift ;;
      --backend-msg)     bmsg="${2:-}";    shift 2 ;;
      --backend-file)    bfile="${2:-}";   shift 2 ;;
      --frontend-msg)    fmsg="${2:-}";    shift 2 ;;
      --frontend-file)   ffile="${2:-}";   shift 2 ;;
      --message|-m)      msg="${2:-}";     shift 2 ;;
      --message-file|-F) msgfile="${2:-}"; shift 2 ;;
      -*)                die "未知参数：$1" ;;
      *)                 die "多余参数：$1" ;;
    esac
  done
  ensure_git_repo "$BACKEND_DIR"
  ensure_git_repo "$FRONTEND_DIR"

  if [[ "$show" == "1" ]]; then
    for dir in "${REPOS[@]}"; do
      local p="$WORKSPACE_DIR/$dir" porc
      echo "════════ $dir ════════"
      echo "── 当前分支：$(cur_branch "$p" || echo '(detached)')"
      porc="$(git -C "$p" status --porcelain)"
      if [[ -z "$porc" ]]; then
        echo "（干净，无改动）"; echo; continue
      fi
      echo "── git status --porcelain"
      echo "$porc" | sed 's/^/  /'
      echo "── git diff HEAD --stat"
      git -C "$p" diff HEAD --stat | sed 's/^/  /'
      echo "── git diff HEAD"
      git -C "$p" -c core.pager=cat diff HEAD
      echo
    done
    return 0
  fi

  for f in "$bfile" "$ffile" "$msgfile"; do
    if [[ -n "$f" && ! -f "$f" ]]; then die "找不到信息文件：$f"; fi
  done
  warn_drift

  local committed=0
  for dir in "${REPOS[@]}"; do
    local p="$WORKSPACE_DIR/$dir" this_flag this_val
    if [[ "$no_add" == "1" ]]; then
      if git -C "$p" diff --cached --quiet; then
        info "$dir：暂存区为空，跳过（--no-add）"; continue
      fi
    elif ! is_dirty "$p"; then
      info "$dir：干净，跳过"; continue
    fi

    if [[ "$dir" == "$BACKEND_DIR" ]]; then
      if   [[ -n "$bfile" ]];   then this_flag="-F"; this_val="$bfile"
      elif [[ -n "$bmsg" ]];    then this_flag="-m"; this_val="$bmsg"
      elif [[ -n "$msgfile" ]]; then this_flag="-F"; this_val="$msgfile"
      elif [[ -n "$msg" ]];     then this_flag="-m"; this_val="$msg"
      else die "$dir 有改动但没给提交信息。先 git-sync.sh commit --show 看 diff，再 --backend-file <路径> 或 --backend-msg \"...\"。"
      fi
    else
      if   [[ -n "$ffile" ]];   then this_flag="-F"; this_val="$ffile"
      elif [[ -n "$fmsg" ]];    then this_flag="-m"; this_val="$fmsg"
      elif [[ -n "$msgfile" ]]; then this_flag="-F"; this_val="$msgfile"
      elif [[ -n "$msg" ]];     then this_flag="-m"; this_val="$msg"
      else die "$dir 有改动但没给提交信息。先 git-sync.sh commit --show 看 diff，再 --frontend-file <路径> 或 --frontend-msg \"...\"。"
      fi
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
      [[ "$no_add" == "1" ]] || dryrun_echo "git -C \"$p\" add -A"
      if [[ "$this_flag" == "-F" ]]; then
        dryrun_echo "git -C \"$p\" commit -F $this_val"
      else
        dryrun_echo "git -C \"$p\" commit -m \"$this_val\""
      fi
      committed=1; continue
    fi

    [[ "$no_add" == "1" ]] || git -C "$p" add -A
    git_commit "$p" "$this_flag" "$this_val"
    echo "✔ $dir：$(git -C "$p" log -1 --oneline)"
    committed=1
  done

  [[ "$committed" == "1" ]] || die "两个仓库都没有需要提交的改动。"
  if [[ "$DRY_RUN" != "1" ]]; then
    echo "✔ 提交完成。要推送：git-sync.sh push"
  fi
}

# ---------------------------------------------------------------------------
# push
# ---------------------------------------------------------------------------

cmd_push() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) DRY_RUN=1; shift ;;
      -*)        die "未知参数：$1" ;;
      *)         die "多余参数：$1" ;;
    esac
  done
  ensure_git_repo "$BACKEND_DIR"
  ensure_git_repo "$FRONTEND_DIR"
  local bcur fcur
  bcur="$(cur_branch "$BACKEND_PATH")"
  fcur="$(cur_branch "$FRONTEND_PATH")"
  [[ -n "$bcur" ]] || die "$BACKEND_DIR 处于 detached HEAD，先切到分支。"
  [[ -n "$fcur" ]] || die "$FRONTEND_DIR 处于 detached HEAD，先切到分支。"
  if [[ "$bcur" != "$fcur" ]]; then
    warn "两仓分支不一致（$bcur / $fcur），仍会各推各的。"
  fi
  for dir in "${REPOS[@]}"; do
    has_remote "$WORKSPACE_DIR/$dir" || die "$dir 没有配置任何远程。"
  done

  local fail=0
  for dir in "${REPOS[@]}"; do
    local p="$WORKSPACE_DIR/$dir" cur
    cur="$(cur_branch "$p")"
    info "$dir：git push -u origin $cur"
    if [[ "$DRY_RUN" == "1" ]]; then
      dryrun_echo "git -C \"$p\" push -u origin $cur"
    elif git -C "$p" push -u origin "$cur"; then
      echo "✔ $dir 已推送 $cur"
    else
      echo "✗ $dir 推送失败（见上方 git 输出）。" >&2
      fail=1
    fi
  done
  if [[ "$DRY_RUN" == "1" ]]; then
    return 0
  fi
  [[ "$fail" == "0" ]] || die "有仓库推送失败，另一个仓库的结果见上（两个独立远程，不回滚）。"
  echo "✔ 两个仓库都已推送"
}

# ---------------------------------------------------------------------------
# pull
# ---------------------------------------------------------------------------

cmd_pull() {
  local rebase=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-rebase) rebase=0; shift ;;
      --dry-run)   DRY_RUN=1; shift ;;
      -*)          die "未知参数：$1" ;;
      *)           die "多余参数：$1" ;;
    esac
  done
  ensure_git_repo "$BACKEND_DIR"
  ensure_git_repo "$FRONTEND_DIR"
  for dir in "${REPOS[@]}"; do
    local p="$WORKSPACE_DIR/$dir"
    if is_dirty "$p"; then
      die "$dir 工作区有未提交改动，pull 前先处理（git-sync.sh commit 或 git stash）。"
    fi
    has_upstream "$p" || die "$dir 当前分支没有 upstream。先 git-sync.sh push（带 -u），或 git branch --set-upstream-to。"
  done
  local bcur fcur
  bcur="$(cur_branch "$BACKEND_PATH")"
  fcur="$(cur_branch "$FRONTEND_PATH")"
  if [[ "$bcur" != "$fcur" ]]; then
    warn "两仓分支不一致（$bcur / $fcur），仍会各拉各的。"
  fi

  local pf="--rebase"
  if [[ "$rebase" == "0" ]]; then pf="--no-rebase"; fi
  for dir in "${REPOS[@]}"; do
    local p="$WORKSPACE_DIR/$dir"
    info "$dir：git pull $pf"
    if [[ "$DRY_RUN" == "1" ]]; then
      dryrun_echo "git -C \"$p\" pull $pf"
    elif ! git -C "$p" pull "$pf"; then
      die "$dir pull 失败/冲突。解决后 git rebase --continue（或 git rebase --abort / git merge --abort），再重跑 git-sync.sh pull。另一个仓库若已成功不受影响。"
    else
      echo "✔ $dir 已更新"
    fi
  done
  if [[ "$DRY_RUN" != "1" ]]; then
    echo "✔ 两个仓库都已拉取"
  fi
}

# ---------------------------------------------------------------------------

main() {
  local sub="${1:-}"
  shift || true
  case "$sub" in
    status)             cmd_status "$@" ;;
    list)               cmd_list   "$@" ;;
    new)                cmd_new    "$@" ;;
    co|switch|checkout) cmd_co     "$@" ;;
    rm|delete)          cmd_rm     "$@" ;;
    commit)             cmd_commit "$@" ;;
    push)               cmd_push   "$@" ;;
    pull)               cmd_pull   "$@" ;;
    ""|-h|--help|help)  usage ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
