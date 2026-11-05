# SFTP-Nginx

> 一键部署 **SFTP (Chroot) + Nginx (n.wtf) + ACME SSL + ACL** 的静态文件托管方案

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](./LICENSE)
[![Platform](https://img.shields.io/badge/platform-debian%20%7C%20ubuntu-lightgrey)]()
[![Nginx](https://img.shields.io/badge/nginx-mainline%20%2B%20ACME-brightgreen)]()

---

## ✨ 特性

- **SFTP Chroot 监狱** — 用户被锁定在自己的目录，看不到系统其他部分
- **Nginx n.wtf 源** — Mainline 最新版，自带 HTTP/3、Brotli、Zstd、ACME 等模块
- **原生 ACME 自动 SSL** — Nginx 内置 ACME 模块，无需 certbot/cron，零 reload 续期
- **ACL 精细权限** — Nginx 通过 ACL 读取文件，与用户权限完全解耦
- **交互式管理菜单** — 命令行 `sftp-manager` 管理用户增删、ACL 修复、服务重启

## 📦 安装

```bash
# 下载
curl -fsSL https://raw.githubusercontent.com/chypay/sftp-nginx/main/install.sh -o install.sh
chmod +x install.sh

# 安装（staging 先测）
sudo ./install.sh uploader example.com staging

# 测试通过后切 prod
sudo ./install.sh uploader example.com prod
```

## 🔧 管理

安装完成后，输入 `sftp-manager` 进入交互式管理菜单：

```
╔══════════════════════════════════════════════════╗
║          SFTP-NGINX 管理面板 v1.0               ║
║     SFTP Chroot · Nginx ACL · ACME SSL          ║
╚══════════════════════════════════════════════════╝

  请选择操作:

   1)  添加 SFTP 用户
   2)  删除 SFTP 用户
   3)  修改 SFTP 用户密码
   4)  修复 ACL 权限（单个/全部）
   5)  查看 ACL 权限
   6)  配置 ACME SSL
   7)  重启 Nginx
   8)  重启 SSH
   9)  服务状态
   0)  退出
```

### 菜单功能说明

| 选项 | 功能 |
|------|------|
| 1 | 交互式创建新 SFTP 用户（自动建监狱、目录、ACL、nginx 站点） |
| 2 | 删除用户（含 nginx 站点、sshd 配置、ACL） |
| 3 | 修改指定用户的 SFTP 密码 |
| 4 | 修复/重置 ACL 权限（可选单个用户或全部） |
| 5 | 查看指定用户的 ACL 详细信息 |
| 6 | 为已有域名配置 ACME 自动 SSL |
| 7 | 重载 Nginx（先校验配置） |
| 8 | 重启 SSH（先校验配置） |
| 9 | 查看服务状态（nginx/ssh 运行状态、站点列表、磁盘、证书） |

## 🏗️ 架构

```
用户通过 SFTP 上传文件
        │
        ▼
/var/sftp/<user>/var/www/<domain>/   ← SFTP 用户可写
        │
        │  ACL: nginx:rx (递归 + 默认继承)
        ▼
Nginx (nginx 用户) 读取并对外提供 HTTPS 服务
        │
        │  原生 ACME 模块自动签发/续期 Let's Encrypt 证书
        ▼
浏览器访问 https://<domain> (HTTP/3 + Brotli + Zstd)
```

## 📁 目录结构

```
/var/sftp/<user>/              ← 监狱根目录 (属 root:root, 755)
└── var/www/<domain>/          ← 站点目录 (属 user:user)
    ├── index.html             ← 用户上传的静态文件
    └── ...

/etc/nginx/
├── sites-available/<domain>   ← 站点配置
├── sites-enabled/<domain>     ← 软链接
└── conf.d/acme-<domain>.conf  ← ACME issuer 配置

/var/cache/nginx/acme-<domain>/ ← ACME 状态（账号/证书）

/etc/sftp-nginx/<user>.conf    ← 用户元数据
```

## 🔐 权限模型

| 主体 | 权限 | 说明 |
|------|------|------|
| SFTP 用户 | rwx | 上传/修改/删除文件 |
| nginx | rx | 只读访问静态文件 |
| 其他人 | --- | 无权限 |

ACL 默认规则（新建文件自动继承）：
- `default:user:nginx:rx` — Nginx 读新文件
- `default:user:<sftp_user>:rwx` — 用户拥有新文件
- `default:other::---` — 其他人无权限

## 🔄 ACME SSL

使用 n.wtf nginx 自带的 `libnginx-mod-http-acme` 模块，无需外部工具：

- **Staging 环境** — 测试用，证书不被浏览器信任，但不占生产额度
- **Production 环境** — 正式证书

切换方式：编辑 `/etc/nginx/conf.d/acme-<domain>.conf` 中的 `uri`，然后 `nginx -t && systemctl reload nginx`

## 📋 系统要求

- Debian 10+ 或 Ubuntu 18.04+
- Root 权限
- 公网 IP + 域名解析（ACME 需要 80 端口可访问）
- 至少 512MB 内存

## 🤝 贡献

欢迎 PR、Issue、Star！

## 📄 License

MIT
