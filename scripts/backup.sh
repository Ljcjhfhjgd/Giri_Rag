#!/usr/bin/env bash
# 极睿知识库 数据备份脚本
#
# 为什么不能直接 cp：
#   SQLite 默认开启 WAL，主库文件在有写入时是"脏"的，直接复制会得到损坏的库。
#   必须走 sqlite3 的 .backup 命令（走 SQLite 自己的备份 API）。
#
# 两个库必须一起备份：
#   data/jirui.db        业务库（用户 / 知识库 / 权限规则 / 会话）
#   data/index/chunks.db 检索索引库（片段正文 / 向量 / 全文索引）
#   只恢复其中一个会让权限规则与实际内容脱节。
#
# 用法：
#   ./backup.sh
#   APP_DIR=/opt/jirui/app BACKUP_DIR=/data/backups KEEP_DAYS=14 ./backup.sh
set -euo pipefail

APP_DIR="${APP_DIR:-/opt/jirui/app}"
BACKUP_DIR="${BACKUP_DIR:-/opt/jirui/backups}"
KEEP_DAYS="${KEEP_DAYS:-30}"
STAMP="$(date +%Y%m%d-%H%M%S)"

if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "错误：未找到 sqlite3 命令。请先安装：apt install sqlite3 / yum install sqlite" >&2
  exit 1
fi

mkdir -p "$BACKUP_DIR"

backup_one() {
  local src="$1"
  local name
  name="$(basename "$src")"
  if [ ! -f "$src" ]; then
    echo "跳过（文件不存在）：$src"
    return 0
  fi
  sqlite3 "$src" ".backup '$BACKUP_DIR/${name}.${STAMP}'"
  echo "已备份：$BACKUP_DIR/${name}.${STAMP}"
}

backup_one "$APP_DIR/data/jirui.db"
backup_one "$APP_DIR/data/index/chunks.db"

# 上传的原始文档也归档（体积大，不需要可加 DISABLE_UPLOAD_BACKUP=1 跳过）
if [ "${DISABLE_UPLOAD_BACKUP:-0}" != "1" ] && [ -d "$APP_DIR/data/uploads" ]; then
  tar -czf "$BACKUP_DIR/uploads.${STAMP}.tar.gz" -C "$APP_DIR/data" uploads
  echo "已归档：$BACKUP_DIR/uploads.${STAMP}.tar.gz"
fi

# 清理过期备份
find "$BACKUP_DIR" -type f -name '*.db.*' -mtime "+$KEEP_DAYS" -delete 2>/dev/null || true
find "$BACKUP_DIR" -type f -name 'uploads.*.tar.gz' -mtime "+$KEEP_DAYS" -delete 2>/dev/null || true

echo "备份完成。目录：$BACKUP_DIR（保留最近 $KEEP_DAYS 天）"
