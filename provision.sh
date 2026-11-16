#!/usr/bin/env bash
# ApelinPlus -> GitHub 一键开通（macOS / Linux / Git Bash）
#
#   ./provision.sh <token> [repo-name] [public|private]
#
#   ./provision.sh ghp_xxxx
#   ./provision.sh ghp_xxxx ApelinPlus private
#
# 仓库已经手工建好了就加 SKIP_CREATE=1：
#
#   SKIP_CREATE=1 ./provision.sh ghp_xxxx
#
# token 需要的权限见 PROVISION.md。token 不会写进 .git/config。

set -euo pipefail

TOKEN="${1:-}"
REPO="${2:-ApelinPlus}"
VISIBILITY="${3:-public}"
SKIP_CREATE="${SKIP_CREATE:-0}"

if [ -z "$TOKEN" ]; then
  echo "用法: ./provision.sh <token> [repo-name] [public|private]" >&2
  exit 1
fi

die() { printf '\n失败：%s\n%s\n\n' "$1" "${2:-}" >&2; exit 1; }

# ---- 前置 ------------------------------------------------------

command -v git >/dev/null 2>&1 || die "找不到 git。" "先装 git。"
command -v curl >/dev/null 2>&1 || die "找不到 curl。" "先装 curl。"

[ -d "$(dirname "$0")/.git" ] || die "必须在仓库根目录跑（找不到 .git）。" ""
cd "$(dirname "$0")"

api() {
  # api METHOD PATH [BODY] -> 响应体；HTTP 码写在全局 LAST_STATUS
  local method="$1" path="$2" body="${3:-}"
  local args=(-sS -X "$method" "https://api.github.com$path"
    -H "Authorization: Bearer $TOKEN"
    -H "Accept: application/vnd.github+json"
    -H "X-GitHub-Api-Version: 2022-11-28"
    -H "User-Agent: ApelinPlus-Provision"
    -w '\n%{http_code}')
  [ -n "$body" ] && args+=(-H 'Content-Type: application/json' -d "$body")
  local out
  out="$(curl "${args[@]}" 2>&1)" || true
  LAST_STATUS="$(printf '%s' "$out" | tail -n1)"
  printf '%s' "$out" | sed '$d'
}

json_field() {
  # 不依赖 jq：把一个 "key": "value" 抠出来
  printf '%s' "$1" | tr ',' '\n' | grep -o "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -n1 | sed 's/.*:[[:space:]]*"//; s/"$//'
}

# ---- 校验 token ------------------------------------------------

ME="$(api GET /user)"
if [ "$LAST_STATUS" != "200" ]; then
  [ "$LAST_STATUS" = "401" ] && die "token 无效或已过期（401）。" "fine-grained 以 github_pat_ 开头，classic 以 ghp_ 开头，别搞混。"
  die "连不上 GitHub API（HTTP $LAST_STATUS）。" "检查网络/代理。"
fi

OWNER="$(json_field "$ME" login)"
[ -n "$OWNER" ] || die "解析不出账号名，响应：$ME" ""

echo "账号: $OWNER  仓库: $REPO  可见性: $VISIBILITY"

# ---- 1. 建仓库 -------------------------------------------------

if [ "$SKIP_CREATE" != "1" ]; then
  BODY="$(printf '{"name":"%s","private":%s,"description":"Apelin multi-instance providers + balance queries","has_issues":true,"has_wiki":false,"auto_init":false}' \
    "$REPO" "$([ "$VISIBILITY" = "private" ] && echo true || echo false)")"

  CREATED="$(api POST /user/repos "$BODY")"
  case "$LAST_STATUS" in
    201)
      echo "仓库已建好: https://github.com/$OWNER/$REPO"
      ;;
    422)
      echo "仓库已存在，跳过创建，直接推。"
      ;;
    403|404)
      die "token 没有建仓库的权限（HTTP $LAST_STATUS）。" \
          "fine-grained token 建不了仓库，这是 GitHub 的限制。要么 SKIP_CREATE=1 先去网页建空仓库，要么换 classic token 勾 repo + workflow。"
      ;;
    *)
      die "建仓库失败（HTTP $LAST_STATUS）：$CREATED" "试试 SKIP_CREATE=1，去 https://github.com/new 手动建（别勾 README）。"
      ;;
  esac
fi

# ---- 2. 推代码 -------------------------------------------------

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "$BRANCH" = "HEAD" ] && BRANCH=main

if [ -n "$(git status --porcelain)" ]; then
  echo "有未提交的改动，先提交..."
  git add -A
  git -c core.autocrlf=false commit -q -m "Update before first CI run"
fi

echo "推送 $BRANCH ..."
if ! git push "https://x-access-token:$TOKEN@github.com/$OWNER/$REPO.git" "HEAD:refs/heads/$BRANCH"; then
  die "git push 被拒。" "报错里有 'without workflow scope' 就是 token 缺 workflow 权限 —— 推 .github/workflows/ 必须有。"
fi

cat <<EOF

推完了。
  Actions: https://github.com/$OWNER/$REPO/actions

等 "swift test" 那个 job 跑完（约 2 分钟）。绿的就行；红的把日志整段贴给我。

EOF
