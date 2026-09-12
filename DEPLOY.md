# 极睿知识库 部署手册

面向 Ubuntu / Debian（CentOS 差异单独标注）。目标机器：2 核 / 2 GiB。

---

## 0. 部署前必做：处理已泄露的密钥

**背景**：`backend/.env` 曾被提交进公开仓库 `Noahjjk/Girui`，其中 `JWT_SECRET`、
`SECRET_ENCRYPTION_KEY`、`ADMIN_INIT_PASSWORD` 三个字段是真实值。
（`DEFAULT_LLM_API_KEY` 当时为空，未泄露。）

因为项目尚未上线、数据库和 admin 账号都还不存在，**现在轮换的成本为零**。
一旦上线后再换 `SECRET_ENCRYPTION_KEY`，数据库里已加密的模型 API Key 会全部失效。

### 0.1 生成新密钥

```bash
cd /opt/jirui/app

python -c "import secrets; print('JWT_SECRET=' + secrets.token_urlsafe(48))"
python -c "from cryptography.fernet import Fernet; print('SECRET_ENCRYPTION_KEY=' + Fernet.generate_key().decode())"
python -c "import secrets; print('ADMIN_INIT_PASSWORD=' + secrets.token_urlsafe(12))"
```

把三条输出分别填进 `backend/.env`。另外记得改 `ADMIN_EMAIL`。

### 0.2 复核 .env 权限

```bash
chmod 600 backend/.env
```

### 0.3 （可选）清理 git 历史

`.env` 已通过 `git rm --cached` 取消跟踪，但**旧提交里仍然有它**。
如果需要把历史也抹掉：

```bash
# 本地开发机上执行，需要 pip install git-filter-repo
git filter-repo --path backend/.env --invert-paths
git push origin --force --all
git push origin --force --tags
```

> 注意：即便清了历史，GitHub 可能仍保留 dangling commit 一段时间，仓库也可能已被人
> fork 或 clone。**所以轮换密钥才是真正的修复，清历史只是体面问题。**

---

## 1. 服务器一次性初始化

以下命令在服务器上以 root 执行。

### 1.1 安装系统依赖

**Ubuntu / Debian：**

```bash
apt update
apt install -y git python3 python3-venv python3-pip sqlite3 nginx curl
```

**CentOS / RHEL / 麒麟：**

```bash
dnf install -y git python3 python3-pip sqlite nginx curl
```

> `sqlite3` 命令行工具是必需的 —— 备份脚本用它做 `.backup`，
> 没有它就只能直接 `cp` 数据库，而 WAL 模式下直接复制会得到损坏的库。

### 1.2 创建专用用户与目录

```bash
useradd -r -m -d /opt/jirui -s /bin/bash jirui

mkdir -p /opt/jirui/app
mkdir -p /opt/jirui/venv
mkdir -p /opt/jirui/backups
mkdir -p /opt/jirui/deploy/volumes/web/releases   # 桌面端安装包存放目录
chown -R jirui:jirui /opt/jirui
```

### 1.3 拉取代码

```bash
su - jirui
git clone https://github.com/Noahjjk/Girui.git /opt/jirui/app
cd /opt/jirui/app
```

> 若服务器访问 GitHub 慢，改用镜像或先把仓库打包传上去，再 `git init` 后推本地。

### 1.4 创建 Python 虚拟环境并装依赖

```bash
python3 -m venv /opt/jirui/venv
source /opt/jirui/venv/bin/activate
pip install --upgrade pip
pip install -r /opt/jirui/app/backend/requirements.txt
```

> 依赖里没有 torch，这是刻意的 —— 详见 README 与 `app/services/embedding.py` 的注释。

### 1.5 下载嵌入模型

```bash
cd /opt/jirui/app
python scripts/download_models.py
```

模型会落到 `/opt/jirui/app/models/bge-small-zh-v1.5/`（约 25 MB）。

验证：

```bash
ls -la models/bge-small-zh-v1.5/
ls -la models/bge-small-zh-v1.5/onnx/
```

必须能看到 `tokenizer.json`，以及 `onnx/model_quantized.onnx` 和
`onnx/model_quantized.onnx_data` 两个文件。**缺任何一个，文档解析都会失败。**

> ⚠️ 不要用 `backend/scripts/prepare_model.py`，它的默认目标目录是 `backend/models/`，
> 而 `run_local.py` 读取的是项目根目录下的 `models/`，两边对不上。

### 1.6 配置环境变量

```bash
cp backend/.env.example backend/.env
chmod 600 backend/.env
vi backend/.env
```

至少要改这四项（生成方法见第 0 节）：

- `JWT_SECRET`
- `SECRET_ENCRYPTION_KEY`
- `ADMIN_INIT_PASSWORD`
- `ADMIN_EMAIL`

### 1.7 注册 systemd 服务

```bash
exit   # 回到 root 或 sudo
cp /opt/jirui/app/deploy/jirui.service /etc/systemd/system/jirui.service
systemctl daemon-reload
systemctl enable jirui
systemctl start jirui
```

确认状态：

```bash
systemctl status jirui --no-pager
curl -s http://127.0.0.1:8000/api/v1/health
```

应返回 `{"status":"ok",...}`。

### 1.8 配置 Nginx 反向代理

```bash
cat > /etc/nginx/sites-available/jirui <<'EOF'
server {
    listen 80;
    server_name kb.example.com;          # 换成你的域名或留 _

    client_max_body_size 200m;           # 与 MAX_UPLOAD_SIZE_MB 对齐

    # 桌面端安装包下载
    location /releases/ {
        alias /opt/jirui/deploy/volumes/web/releases/;
        autoindex on;
    }

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # 问答是 SSE 流式返回，必须关掉缓冲，否则回答会一次性吐出来
        proxy_buffering off;
        proxy_cache off;
        proxy_read_timeout 300s;
    }
}
EOF

ln -sf /etc/nginx/sites-available/jirui /etc/nginx/sites-enabled/jirui
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx
```

**CentOS 用的是 `/etc/nginx/conf.d/jirui.conf`，内容相同。**

### 1.9 申请 HTTPS 证书（有域名时）

```bash
apt install -y certbot python3-certbot-nginx
certbot --nginx -d kb.example.com
```

> 证书配好后，记得把 `backend/.env` 里的 `ALLOWED_ORIGINS` 补上域名。
> 但注意 `run_local.py` 会覆盖这个变量（见下方"已知限制"）。

### 1.10 配置备份定时任务

```bash
chmod +x /opt/jirui/app/scripts/*.sh

cat > /etc/cron.d/jirui-backup <<'EOF'
# 每天凌晨 3 点备份数据库与上传文件
0 3 * * * jirui APP_DIR=/opt/jirui/app BACKUP_DIR=/opt/jirui/backups /opt/jirui/app/scripts/backup.sh >> /var/log/jirui-backup.log 2>&1
EOF
```

---

## 2. 日常更新

在**你的开发机**上：

```bash
cd F:\Desktop\Giri_Rag
git add -A
git commit -m "本次改动说明"
git tag v1.0.1
git push origin master --tags
```

在**服务器**上：

```bash
sudo -u jirui bash -lc 'cd /opt/jirui/app && ./deploy.sh v1.0.1'
```

`deploy.sh` 会依次执行：备份 → 拉取并校验 tag → 切换代码 → 装依赖 → 跑迁移 →
重启 systemd → 轮询健康检查 30 秒。失败时会打印排查命令与回滚命令。

用户端表现：**什么都不用做，刷新页面即新版。**

查看可用 tag：

```bash
./deploy.sh --list
```

---

## 3. 桌面端发版

仅当你改了 Electron 外壳，或要强制用户升级时才需要。日常改前后端**不要走这一步**。

### 3.1 打包（开发机，Windows）

```bash
cd F:\Desktop\Giri_Rag\electron
npm run dist
```

产出在 `dist/`：`极睿知识库-Setup-1.0.1.exe`、`latest.yml`、`*.exe.blockmap`

### 3.2 上传安装包

```bash
scp dist/*.exe dist/*.blockmap \
  root@服务器:/opt/jirui/deploy/volumes/web/releases/
```

> 只传 exe 和 blockmap。**`latest.yml` 不用传**，后端会按数据库动态生成。

### 3.3 在后台登记版本

浏览器打开站点 → 登录管理员 → 左侧【版本管理】→ 右上角【发布新版本】。

表单填写：

| 字段 | 填什么 |
|---|---|
| 平台 | windows |
| 版本 | `1.0.1`（必须是标准三段式） |
| 最低支持版本 | 如 `1.0.0`。提示原文："低于此版本将强制升级" |
| 更新说明 | 会显示在客户端弹窗里 |
| 安装包下载地址 | `https://你的域名/releases/极睿知识库-Setup-1.0.1.exe` |
| SHA512 | 从 `latest.yml` 复制，**不要手抄** |
| 安装包大小（字节） | 从 `latest.yml` 的 `size` 复制 |
| ☑ 强制升级 | 只在 API 破坏性变更或安全修复时勾 |

提交后点【模拟本机检查更新】验证。

### 3.4 测试用的高分版本号用完必须下架

`/updates/check` 与 `latest.yml` 都用「版本号最高者」作为最新版。
测试时若发了 `9.9.9`，**只要不下架就会永久被当成最新版**，导致所有真实客户端
都被判定需要更新。测完立刻在列表里点【下架删除版本】。

---

## 4. 回滚

```bash
cd /opt/jirui/app
./deploy.sh v1.0.0        # 换成上一个 tag
```

**前提是迁移脚本向后兼容。** 如果某次更新改了表结构（改类型、删列），
回滚代码后老代码可能读不了新库，这时必须连数据一起恢复：

```bash
systemctl stop jirui
cp /opt/jirui/backups/jirui.db.<时间戳>                data/jirui.db
cp /opt/jirui/backups/chunks.db.<时间戳>               data/index/chunks.db
systemctl start jirui
```

> 两个库必须成套恢复。`jirui.db` 存权限规则，`chunks.db` 存片段与向量，
> 只恢复一个会让权限和内容对不上。

---

## 5. 故障排查

### 服务起不来

```bash
systemctl status jirui --no-pager
journalctl -u jirui -n 100 --no-pager
```

### 上传文档后一直"解析中"

模型没就绪。检查：

```bash
ls /opt/jirui/app/models/bge-small-zh-v1.5/tokenizer.json
ls /opt/jirui/app/models/bge-small-zh-v1.5/onnx/
```

启动日志里会有一条明确的 error 指出缺什么。缺就重跑 `python scripts/download_models.py`。

### 问答报"检索服务不可用"

看日志里的具体异常。常见原因：

- 模型目录不对（`LOCAL_EMBEDDING_DIR` 配置错误）
- 索引库被写锁占用超过 30 秒（`database is locked`）

### 内存被 OOM 杀掉

```bash
journalctl -u jirui | grep -i "oom\|killed"
```

`jirui.service` 里设了 `MemoryMax=1400M`，正常情况下 cgroup 会先杀本服务并自动重启，
而不是让内核随机挑进程。如果你看到 sshd 也被杀了，说明 `MemoryMax` 没生效，检查
systemd 版本是否支持 `MemoryMax`（需 237+）。

### 想确认当前跑的是哪个版本

```bash
cd /opt/jirui/app && git describe --tags
curl -s http://127.0.0.1:8000/api/v1/health
```

---

## 6. 已知限制（部署后会遇到的）

### 6.1 `run_local.py` 会覆盖 .env 里的部分配置

`run_local.py` 在导入应用前硬编码设置了四个环境变量：

```python
os.environ["DATA_DIR"]              = <项目根>/data
os.environ["LOCAL_EMBEDDING_DIR"]   = <项目根>/models/bge-small-zh-v1.5
os.environ["INDEX_DB_PATH"]         = <项目根>/data/index/chunks.db
os.environ["ALLOWED_ORIGINS"]       = "null,http://localhost:8000,..."
```

**后果**：你在 `backend/.env` 里改 `DATA_DIR`、`LOCAL_EMBEDDING_DIR`、`INDEX_DB_PATH`
或 `ALLOWED_ORIGINS` 都不会生效。

- 数据与模型路径是固定的，跟着项目根目录走 —— 对标准部署没影响。
- 但 `ALLOWED_ORIGINS` 被写死成只有 localhost。**Web 版同源访问不受影响；
  如果将来 Electron 桌面端从域名访问，需要改 `run_local.py` 这一行。**

### 6.2 不要给 uvicorn 开多 worker

`uvicorn.run(app, host=..., port=8000)` 是单进程。改成 `workers=4` 会导致：

1. 每个 worker 各加载一份 ONNX 模型（+180 MB × N）
2. 每个 worker 有自己的索引单例和自己的 `asyncio.Lock` → **进程内锁失效**，
   多进程同时读写同一个 SQLite 文件，最终抛 `database is locked`

2 GiB 内存下必然爆。**这个项目只能单进程跑。**

### 6.3 `index.html` 没有缓存头

`run_local.py` 里 `FileResponse(index_file)` 未设置 `Cache-Control`，
浏览器会启发式缓存它。而 vite 产出的 `assets/index-<hash>.js` 是内容寻址的。

**风险**：用户拿到缓存的旧 `index.html` → 它引用的旧 assets 已在部署时被覆盖删除
→ 404 白屏。

**缓解**：`deploy.sh` 不会删除旧文件，但 git checkout 会覆盖同名文件。
建议在 `run_local.py` 的 `serve_index` 与 `serve_spa` 里加上：

```python
return FileResponse(str(index_file), headers={"Cache-Control": "no-cache"})
```

并给 `/assets` 挂载加上长缓存（文件名带 hash，永久缓存是安全的）。

### 6.4 `system.py::download_release()` 返回的是 JSON 而不是重定向

该接口的 docstring 写的是"重定向"，但实现是
`return {"url": ..., "version": ..., "size": ...}`。

electron-updater 请求这个文件名时**期望二进制流**，不会解析 JSON 里的 url 字段。
接入桌面端前必须改成：

```python
from fastapi.responses import RedirectResponse
return RedirectResponse(row.download_url, status_code=302)
```

### 6.5 换嵌入模型必须全量重新解析

旧的片段向量是用旧模型算的，新提问向量是用新模型算的，两者不在同一语义空间，
余弦相似度没有意义。而且**不会报错**，只是检索结果变差。

bge-small-zh-v1.5 是 512 维，bge-m3 是 1024 维 —— 维度不同会直接抛异常（好事），
但若换成另一个同为 512 维的模型就会静默出错。建议把模型指纹写进
`data/index/chunks.db` 的 `idx_meta` 表做启动校验。

另外 `KnowledgeBase.embedding_model` 字段的默认值是 `bge-m3`，而 2 GiB 机器上
bge-m3（int8 权重就约 570 MB）基本跑不动。**不要启用它。**

---

## 7. 参考：目录结构约定

```
/opt/jirui/
├── app/                          # git 仓库，按 tag 检出
│   ├── backend/.env              # 600 权限，不入库
│   ├── models/                   # 嵌入模型，不入库
│   ├── data/                     # 数据库与上传，不入库，必须备份
│   └── scripts/deploy.sh         # 更新脚本
├── venv/                         # Python 虚拟环境
├── backups/                      # 备份产物
└── deploy/volumes/web/releases/  # 桌面端安装包，Nginx 暴露为 /releases/
```
