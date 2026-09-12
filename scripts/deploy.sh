#!/usr/bin/env bash
# 极睿知识库 服务端更新脚本
#
# 用法（在服务器上执行）：
#   ./deploy.sh v1.0.1        部署指定 tag
#   ./deploy.sh --list        列出可用 tag
#
# 可覆盖的环境变量：
#   APP_DIR   代码目录，默认 /opt/jirui/app
#   VENV      Python 虚拟环境目录，默认 /opt/jirui/venv
#   SERVICE   systemd 服务名，默认 jirui
#   HEALTH_URL 健康检查地址
#
# 设计原则：只用 git tag 部署，不用分支。分支会飘，tag 是死的、可回滚。
# 部署前强制备份，因为迁移脚本一旦改坏数据结构，没有备份就只能靠重装。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${APP_DIR:-/opt/jirui/app}"
VENV="${VENV:-/opt/jirui/venv}"
SERVICE="${SERVICE:-jirui}"
HEALTH_URL="${HEALTH_URL:-http://127.0.0.1:8000/api/v1/health}"

TAG="${1:-}"

if [ "$TAG" = "--list" ]; then
  cd "$APP_DIR"
  echo "可用 tag（新→旧）："
  git tag --sort=-v:refname | head -20
  exit 0
fi

if [ -z "$TAG" ]; then
  echo "用法：$0 <git tag>      例如 $0 v1.0.1" >&2
  echo "      $0 --list        查看可用 tag" >&2
  exit 1
fi

cd "$APP_DIR"

echo "==> 1/6 备份数据库与上传文件"
APP_DIR="$APP_DIR" "$SCRIPT_DIR/backup.sh"

echo "==> 2/6 拉取标签并校验"
git fetch --tags --prune
if ! git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "错误：仓库中找不到 tag「$TAG」。" >&2
  git tag --sort=-v:refname | head -10 >&2
  exit 1
fi

echo "==> 3/6 切换代码到 $TAG"
PREV="$(git describe --tags --always 2>/dev/null || echo unknown)"
git checkout "$TAG"
echo "    由 $PREV 切换到 $TAG"

echo "==> 4/6 更新依赖"
# shellcheck disable=SC1091
source "$VENV/bin/activate"
pip install -q -r backend/requirements.txt

echo "==> 5/6 执行数据迁移（务必保持幂等）"
python backend/scripts/migrate.py
python backend/scripts/migrate_folders.py

echo "==> 6/6 重启服务并等待就绪"
systemctl restart "$SERVICE"
for _ in $(seq 1 30); do
  if curl -fsS "$HEALTH_URL" >/dev/null 2>&1; then
    echo
    echo "部署成功。当前版本：$(git describe --tags)"
    echo "如需回滚：$0 $PREV"
    exit 0
  fi
  sleep 1
done

echo >&2
echo "错误：服务启动后 30 秒内健康检查未通过。" >&2
echo "排查：journalctl -u $SERVICE -n 80 --no-pager" >&2
echo "回滚：$0 $PREV" >&2
exit 1
