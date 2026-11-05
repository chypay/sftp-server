#!/usr/bin/env bash
# ==============================================================================
#  SFTP-Nginx 一体化安装脚本
#  Nginx (n.wtf repo) + 原生 ACME SSL + HTTP/3 + SFTP Chroot + ACL
#
#  用法:
#    sudo bash install.sh <sftp_user> <domain> [staging|prod]
#
#  示例:
#    sudo bash install.sh uploader example.com staging
#    sudo bash install.sh uploader example.com prod
#
#  安装完成后可通过 `sftp-manager` 命令进入管理菜单
# ==============================================================================
set -euo pipefail

# ── 参数 ──────────────────────────────────────────────────────────────────────
SFTP_USER="${1:-}"
SITE_DOMAIN="${2:-}"
ACME_ENV="${3:-staging}"

if [[ -z "$SFTP_USER" || -z "$SITE_DOMAIN" ]]; then
    echo "用法: $0 <sftp_user> <domain> [staging|prod]"
    echo ""
    echo "  sftp_user   SFTP 登录用户名"
    echo "  domain      站点域名（需解析到本机）"
    echo "  staging|prod  ACME 环境，默认 staging"
    echo ""
    echo "示例:"
    echo "  $0 uploader example.com staging"
    echo "  $0 uploader example.com prod"
    exit 1
fi

case "$ACME_ENV" in
    staging|prod) ;;
    *) echo "[ERROR] 第三个参数必须是 staging 或 prod"; exit 1 ;;
esac

# ── 配置 ──────────────────────────────────────────────────────────────────────
NGINX_USER="nginx"
SFTP_BASE="/var/sftp"
WWW_BASE="/var/www"
MANAGER_BIN="/usr/local/bin/sftp-manager"
ADMIN_EMAIL="${ADMIN_EMAIL:-root@${SITE_DOMAIN}}"

# ── 颜色 ──────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
step()    { echo -e "\n${CYAN}${BOLD}═══ $* ═══${NC}"; }
err_exit(){ echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── 0. 前置检查 ───────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || err_exit "必须用 root 运行"

if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    case "$ID" in
        debian|ubuntu) ;;
        *) err_exit "仅支持 Debian / Ubuntu，当前: $ID" ;;
    esac
else
    err_exit "无法检测发行版"
fi

# ── 1. 基础工具 ───────────────────────────────────────────────────────────────
step "安装基础工具"
info "安装 acl, curl, gnupg, lsb-release, ca-certificates…"
apt-get update -y
apt-get install -y acl curl gnupg lsb-release ca-certificates openssl

# ── 2. n.wtf 仓库 ─────────────────────────────────────────────────────────────
step "添加 n.wtf nginx 仓库"
curl -fsSL https://n.wtf/key.gpg | gpg --dearmor -o /usr/share/keyrings/n-nginx.gpg

CODENAME="$(lsb_release -cs)"
cat > /etc/apt/sources.list.d/n-nginx.list <<EOF
deb [signed-by=/usr/share/keyrings/n-nginx.gpg] https://n.wtf/debian ${CODENAME} main
EOF

apt-get update -y

# ── 3. 安装 nginx + acme 模块 ─────────────────────────────────────────────────
step "安装 nginx-full + ACME 模块"
apt-get install -y nginx-full libnginx-mod-http-acme

if ! id "$NGINX_USER" &>/dev/null; then
    if id "www-data" &>/dev/null; then
        NGINX_USER="www-data"
        warn "nginx 用户为 www-data，已自动适配"
    else
        err_exit "找不到 nginx 用户"
    fi
fi
info "nginx 用户: $NGINX_USER"
info "nginx 版本: $(nginx -v 2>&1)"

# ── 4. ACME 状态目录 ──────────────────────────────────────────────────────────
step "配置 ACME 状态目录"
mkdir -p "/var/cache/nginx/acme-${SITE_DOMAIN}"
chown -R "${NGINX_USER}:${NGINX_USER}" "/var/cache/nginx/acme-${SITE_DOMAIN}"
chmod 700 "/var/cache/nginx/acme-${SITE_DOMAIN}"

# ── 5. ACME issuer 配置 ───────────────────────────────────────────────────────
step "生成 ACME issuer 配置 (${ACME_ENV})"

if [[ "$ACME_ENV" == "staging" ]]; then
    ACME_URI="https://acme-staging-v02.api.letsencrypt.org/directory"
    warn "使用 Let's Encrypt STAGING（证书不被浏览器信任，仅测试用）"
else
    ACME_URI="https://acme-v02.api.letsencrypt.org/directory"
    info "使用 Let's Encrypt PRODUCTION"
fi

cat > "/etc/nginx/conf.d/acme-${SITE_DOMAIN}.conf" <<EOF
# ACME for ${SITE_DOMAIN} (${ACME_ENV})
resolver 1.1.1.1 8.8.8.8 valid=300s;
resolver_timeout 5s;

acme_issuer letsencrypt_${SITE_DOMAIN} {
    uri ${ACME_URI};
    contact mailto:${ADMIN_EMAIL};
    state_path /var/cache/nginx/acme-${SITE_DOMAIN};
    accept_terms_of_service;
}

acme_shared_zone zone=acme_${SITE_DOMAIN}:1m;
EOF

info "ACME 配置已写入 /etc/nginx/conf.d/acme-${SITE_DOMAIN}.conf"

# ── 6. SFTP 监狱目录 ──────────────────────────────────────────────────────────
step "创建 SFTP 监狱目录结构"

SFTP_HOME="${SFTP_BASE}/${SFTP_USER}"

mkdir -p "$SFTP_HOME"
chown root:root "$SFTP_HOME"
chmod 755 "$SFTP_HOME"

mkdir -p "${SFTP_HOME}${WWW_BASE}/${SITE_DOMAIN}"
chown -R "${SFTP_USER}:${SFTP_USER}" "${SFTP_HOME}${WWW_BASE}/${SITE_DOMAIN}"

# 默认首页
cat > "${SFTP_HOME}${WWW_BASE}/${SITE_DOMAIN}/index.html" <<HTMLEOF
<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <title>${SITE_DOMAIN}</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; display: flex; align-items: center; justify-content: center; min-height: 100vh; margin: 0; background: linear-gradient(135deg, #667eea, #764ba2); color: white; }
        .box { text-align: center; padding: 40px; background: rgba(255,255,255,0.1); border-radius: 16px; backdrop-filter: blur(10px); }
        h1 { font-size: 3em; margin: 0 0 10px; }
        p { opacity: 0.8; }
    </style>
</head>
<body>
    <div class="box">
        <h1>${SITE_DOMAIN}</h1>
        <p>SFTP-Nginx 部署成功 🚀</p>
        <p>通过 SFTP 上传文件到此目录即可</p>
    </div>
</body>
</html>
HTMLEOF

chown "${SFTP_USER}:${SFTP_USER}" "${SFTP_HOME}${WWW_BASE}/${SITE_DOMAIN}/index.html"

# ── 7. SFTP 用户 ─────────────────────────────────────────────────────────────
step "配置 SFTP 用户"

if id "$SFTP_USER" &>/dev/null; then
    warn "用户 $SFTP_USER 已存在，跳过创建"
else
    info "创建用户: $SFTP_USER"
    useradd -m -d "$SFTP_HOME" -s /usr/sbin/nologin "$SFTP_USER"
    echo ""
    echo -e "${YELLOW}请为用户 $SFTP_USER 设置密码:${NC}"
    passwd "$SFTP_USER"
fi

chsh -s /usr/sbin/nologin "$SFTP_USER" 2>/dev/null || true

# ── 8. sshd 监狱 ──────────────────────────────────────────────────────────────
step "配置 sshd SFTP 监狱"

SSHD_CONF="/etc/ssh/sshd_config"
SSHD_BACKUP="/etc/ssh/sshd_config.bak.$(date +%Y%m%d%H%M%S)"
cp "$SSHD_CONF" "$SSHD_BACKUP"

if grep -q "^Subsystem sftp" "$SSHD_CONF"; then
    sed -i 's|^Subsystem sftp.*|Subsystem sftp internal-sftp|' "$SSHD_CONF"
else
    echo 'Subsystem sftp internal-sftp' >> "$SSHD_CONF"
fi

if ! grep -q "Match User ${SFTP_USER}" "$SSHD_CONF"; then
    cat >> "$SSHD_CONF" <<EOF

# --- SFTP chroot for ${SFTP_USER} ---
Match User ${SFTP_USER}
    ChrootDirectory ${SFTP_HOME}
    ForceCommand internal-sftp
    PasswordAuthentication yes
    PubkeyAuthentication yes
    AllowTcpForwarding no
    X11Forwarding no
EOF
fi

sshd -t || err_exit "sshd 配置语法错误，备份: $SSHD_BACKUP"
systemctl restart sshd
info "sshd 已重启"

# ── 9. ACL 权限 ──────────────────────────────────────────────────────────────
step "配置 ACL 权限"

CHROOT_WWW="${SFTP_HOME}${WWW_BASE}/${SITE_DOMAIN}"

setfacl -R -m u:${NGINX_USER}:rx "$CHROOT_WWW"
setfacl -R -d -m u:${NGINX_USER}:rx "$CHROOT_WWW"
setfacl -R -d -m u:${SFTP_USER}:rwx "$CHROOT_WWW"
setfacl -R -m o::--- "$CHROOT_WWW"
setfacl -R -d -m o::--- "$CHROOT_WWW"

info "ACL 已应用"

# ── 10. Nginx 站点 ────────────────────────────────────────────────────────────
step "生成 nginx 站点配置"

cat > "/etc/nginx/sites-available/${SITE_DOMAIN}" <<EOF
# ${SITE_DOMAIN} — generated by sftp-nginx
# ACME env: ${ACME_ENV}

server {
    listen 80;
    listen [::]:80;
    server_name ${SITE_DOMAIN} www.${SITE_DOMAIN};

    location / {
        return 404;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    listen 443 quic reuseport;
    http3 on;

    server_name ${SITE_DOMAIN} www.${SITE_DOMAIN};

    root ${WWW_BASE}/${SITE_DOMAIN};
    index index.html index.htm;

    acme_certificate letsencrypt_${SITE_DOMAIN};

    ssl_certificate     \$acme_certificate;
    ssl_certificate_key \$acme_certificate_key;
    ssl_certificate_cache max=2;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;

    brotli on;
    brotli_comp_level 6;
    brotli_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript image/svg+xml;

    zstd on;
    zstd_comp_level 6;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location ~ /\. {
        deny all;
    }

    access_log /var/log/nginx/${SITE_DOMAIN}.access.log;
    error_log  /var/log/nginx/${SITE_DOMAIN}.error.log;
}
EOF

ln -sf "/etc/nginx/sites-available/${SITE_DOMAIN}" "/etc/nginx/sites-enabled/${SITE_DOMAIN}"

# ── 11. 校验 & 重载 ───────────────────────────────────────────────────────────
step "校验 nginx 配置"
nginx -t || err_exit "nginx 配置语法错误"
systemctl reload nginx
info "nginx 已重载"

# ── 12. 安装管理菜单 ──────────────────────────────────────────────────────────
step "安装管理命令 sftp-manager"

cat > "$MANAGER_BIN" <<'MANAGER_EOF'
#!/usr/bin/env bash
# ==============================================================================
#  sftp-manager — SFTP-Nginx 管理菜单
# ==============================================================================

NGINX_USER="nginx"
SFTP_BASE="/var/sftp"
WWW_BASE="/var/www"
CONFIG_DIR="/etc/sftp-nginx"

# 颜色
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

# 检测 nginx 用户
if ! id "$NGINX_USER" &>/dev/null; then
    NGINX_USER="www-data"
fi

info()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[✗]${NC} $*" >&2; }
cecho() { echo -e "$*"; }

# 分隔线
sep() { echo -e "${DIM}────────────────────────────────────────${NC}"; }

# 顶部横幅
banner() {
    clear
    echo -e "${CYAN}${BOLD}"
    echo "  ╔══════════════════════════════════════════════════╗"
    echo "  ║          SFTP-NGINX 管理面板 v1.0               ║"
    echo "  ║     SFTP Chroot · Nginx ACL · ACME SSL          ║"
    echo "  ╚══════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo -e "  ${DIM}nginx: $(nginx -v 2>&1 | cut -d'/' -f2)  |  user: ${NGINX_USER}  |  $(date '+%Y-%m-%d %H:%M')${NC}"
    echo ""
}

# 暂停
pause() {
    echo ""
    read -rp "  按回车键继续..." _
}

# 列出所有 SFTP 用户
list_users() {
    echo ""
    echo -e "  ${BOLD}SFTP 用户列表:${NC}"
    sep
    local found=0
    for d in "$SFTP_BASE"/*/; do
        [ -d "$d" ] || continue
        local user
        user="$(basename "$d")"
        if id "$user" &>/dev/null; then
            local domain=""
            if [ -f "${CONFIG_DIR}/${user}.conf" ]; then
                domain="$(grep '^DOMAIN=' "${CONFIG_DIR}/${user}.conf" | cut -d= -f2)"
            fi
            local shell
            shell="$(getent passwd "$user" | cut -d: -f7)"
            echo -e "  ${GREEN}●${NC} ${BOLD}${user}${NC}  ${DIM}|${NC}  域名: ${domain:-未配置}  ${DIM}|${NC}  shell: $(basename $shell)"
            found=1
        fi
    done
    if [ "$found" -eq 0 ]; then
        warn "  没有找到 SFTP 用户，请先添加"
    fi
    sep
}

# 保存用户配置
save_config() {
    local user="$1" domain="$2"
    mkdir -p "$CONFIG_DIR"
    cat > "${CONFIG_DIR}/${user}.conf" <<EOF
# SFTP-Nginx user config — managed by sftp-manager
USER=${user}
DOMAIN=${domain}
CREATED=$(date '+%Y-%m-%d %H:%M:%S')
EOF
}

# 应用 ACL 到指定目录
apply_acl() {
    local dir="$1" user="$2"
    if [ ! -d "$dir" ]; then
        err "目录不存在: $dir"
        return 1
    fi
    setfacl -R -m u:${NGINX_USER}:rx "$dir" 2>/dev/null
    setfacl -R -d -m u:${NGINX_USER}:rx "$dir" 2>/dev/null
    setfacl -R -d -m u:${user}:rwx "$dir" 2>/dev/null
    setfacl -R -m o::--- "$dir" 2>/dev/null
    setfacl -R -d -m o::--- "$dir" 2>/dev/null
    info "ACL 已应用到 $dir"
}

# ── 菜单项 ────────────────────────────────────────────────────────────────────

menu_add_user() {
    banner
    echo -e "  ${BOLD}添加 SFTP 用户${NC}"
    sep
    read -rp "  用户名: " user
    [ -z "$user" ] && { warn "用户名不能为空"; pause; return; }
    if id "$user" &>/dev/null; then
        err "用户 $user 已存在"
        pause
        return
    fi

    read -rp "  域名 (如 example.com): " domain
    [ -z "$domain" ] && { warn "域名不能为空"; pause; return; }

    # 创建监狱
    local sftp_home="${SFTP_BASE}/${user}"
    mkdir -p "$sftp_home"
    chown root:root "$sftp_home"
    chmod 755 "$sftp_home"

    # 创建用户
    useradd -m -d "$sftp_home" -s /usr/sbin/nologin "$user"
    echo ""
    echo -e "  ${YELLOW}请为用户 $user 设置密码:${NC}"
    passwd "$user"

    # 站点目录
    mkdir -p "${sftp_home}${WWW_BASE}/${domain}"
    chown -R "${user}:${user}" "${sftp_home}${WWW_BASE}/${domain}"

    # 默认首页
    cat > "${sftp_home}${WWW_BASE}/${domain}/index.html" <<HTMLEOF
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>${domain}</title>
<style>body{font-family:sans-serif;display:flex;align-items:center;justify-content:center;min-height:100vh;margin:0;background:linear-gradient(135deg,#667eea,#764ba2);color:white}.box{text-align:center;padding:40px;background:rgba(255,255,255,.1);border-radius:16px}h1{font-size:3em;margin:0 0 10px}</style>
</head><body><div class="box"><h1>${domain}</h1><p>🚀 部署成功</p></div></body></html>
HTMLEOF
    chown "${user}:${user}" "${sftp_home}${WWW_BASE}/${domain}/index.html"

    # sshd 配置
    local sshd_conf="/etc/ssh/sshd_config"
    cat >> "$sshd_conf" <<EOF

# --- SFTP chroot for ${user} ---
Match User ${user}
    ChrootDirectory ${sftp_home}
    ForceCommand internal-sftp
    PasswordAuthentication yes
    PubkeyAuthentication yes
    AllowTcpForwarding no
    X11Forwarding no
EOF

    # ACL
    apply_acl "${sftp_home}${WWW_BASE}/${domain}" "$user"

    # 保存配置
    save_config "$user" "$domain"

    # Nginx 站点（HTTP only，后续可加 ACME）
    cat > "/etc/nginx/sites-available/${domain}" <<EOF
# ${domain} — generated by sftp-manager
server {
    listen 80;
    listen [::]:80;
    server_name ${domain} www.${domain};

    root ${WWW_BASE}/${domain};
    index index.html index.htm;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location ~ /\. {
        deny all;
    }

    access_log /var/log/nginx/${domain}.access.log;
    error_log  /var/log/nginx/${domain}.error.log;
}
EOF
    ln -sf "/etc/nginx/sites-available/${domain}" "/etc/nginx/sites-enabled/${domain}"

    sshd -t && systemctl restart sshd
    nginx -t && systemctl reload nginx

    echo ""
    info "用户 $user 创建完成！"
    echo -e "  ${DIM}监狱目录: $sftp_home${NC}"
    echo -e "  ${DIM}站点目录: ${sftp_home}${WWW_BASE}/${domain}${NC}"
    echo -e "  ${DIM}域名:     $domain${NC}"
    echo ""
    warn "如需 HTTPS，请在菜单中为该域名配置 ACME"
    pause
}

menu_del_user() {
    banner
    echo -e "  ${BOLD}删除 SFTP 用户${NC}"
    sep
    list_users
    echo ""
    read -rp "  要删除的用户名 (留空取消): " user
    [ -z "$user" ] && { info "已取消"; pause; return; }

    if ! id "$user" &>/dev/null; then
        err "用户 $user 不存在"
        pause
        return
    fi

    # 读取域名
    local domain=""
    if [ -f "${CONFIG_DIR}/${user}.conf" ]; then
        domain="$(grep '^DOMAIN=' "${CONFIG_DIR}/${user}.conf" | cut -d= -f2)"
    fi

    # 禁用 nginx 站点
    if [ -n "$domain" ]; then
        rm -f "/etc/nginx/sites-enabled/${domain}"
        rm -f "/etc/nginx/sites-available/${domain}"
        rm -f "/etc/nginx/conf.d/acme-${domain}.conf"
        rm -rf "/var/cache/nginx/acme-${domain}"
        nginx -t && systemctl reload nginx
        info "已删除 nginx 站点: $domain"
    fi

    # 从 sshd 移除配置
    local sshd_conf="/etc/ssh/sshd_config"
    # 用 python 或 sed 删除 Match 块
    if command -v python3 &>/dev/null; then
        python3 -c "
import re
with open('$sshd_conf','r') as f:
    c = f.read()
c = re.sub(r'\n# --- SFTP chroot for ${user} ---.*?(?=\n# ---|\Z)', '', c, flags=re.DOTALL)
with open('$sshd_conf','w') as f:
    f.write(c)
"
    fi

    # 删除用户和家目录
    read -rp "  确认删除用户 $user 及其所有文件? [y/N]: " confirm
    if [[ "$confirm" =~ ^[yY]$ ]]; then
        userdel -r "$user" 2>/dev/null || userdel "$user"
        rm -rf "${SFTP_BASE}/${user}"
        rm -f "${CONFIG_DIR}/${user}.conf"
        sshd -t && systemctl restart sshd
        info "用户 $user 已删除"
    else
        info "已取消"
    fi
    pause
}

menu_fix_acl() {
    banner
    echo -e "  ${BOLD}修复 ACL 权限${NC}"
    sep
    list_users
    echo ""
    read -rp "  用户名 (留空修复全部): " user

    if [ -z "$user" ]; then
        for d in "$SFTP_BASE"/*/; do
            [ -d "$d" ] || continue
            local u
            u="$(basename "$d")"
            if id "$u" &>/dev/null; then
                echo ""
                echo -e "  ${CYAN}→ 处理: $u${NC}"
                # 遍历该用户所有站点目录
                for site in "$d$WWW_BASE"/*/; do
                    [ -d "$site" ] || continue
                    apply_acl "$site" "$u"
                done
            fi
        done
        info "所有用户 ACL 修复完成"
    else
        if ! id "$user" &>/dev/null; then
            err "用户 $user 不存在"
            pause
            return
        fi
        local sftp_home="${SFTP_BASE}/${user}"
        for site in "$sftp_home$WWW_BASE"/*/; do
            [ -d "$site" ] || continue
            apply_acl "$site" "$user"
        done
        info "$user ACL 修复完成"
    fi
    pause
}

menu_show_acl() {
    banner
    echo -e "  ${BOLD}查看 ACL 权限${NC}"
    sep
    list_users
    echo ""
    read -rp "  用户名: " user
    [ -z "$user" ] && { pause; return; }

    local sftp_home="${SFTP_BASE}/${user}"
    for site in "$sftp_home$WWW_BASE"/*/; do
        [ -d "$site" ] || continue
        echo ""
        echo -e "  ${CYAN}${site}${NC}"
        getfacl "$site" 2>/dev/null | sed 's/^/    /'
    done
    pause
}

menu_restart_nginx() {
    banner
    echo -e "  ${BOLD}重启 Nginx${NC}"
    sep
    if nginx -t 2>&1; then
        systemctl reload nginx
        info "nginx 已重载"
    else
        err "nginx 配置有错误，请先修复"
    fi
    pause
}

menu_restart_ssh() {
    banner
    echo -e "  ${BOLD}重启 SSH${NC}"
    sep
    if sshd -t 2>&1; then
        systemctl restart sshd
        info "sshd 已重启"
    else
        err "sshd 配置有错误，请先修复"
    fi
    pause
}

menu_status() {
    banner
    echo -e "  ${BOLD}服务状态${NC}"
    sep
    echo ""
    echo -e "  ${BOLD}Nginx:${NC}"
    systemctl status nginx --no-pager | head -5 | sed 's/^/    /'
    echo ""
    echo -e "  ${BOLD}SSH:${NC}"
    systemctl status sshd --no-pager | head -5 | sed 's/^/    /'
    echo ""
    echo -e "  ${BOLD}站点:${NC}"
    ls -1 /etc/nginx/sites-enabled/ 2>/dev/null | grep -v '^default$' | sed 's/^/    /'
    echo ""
    echo -e "  ${BOLD}磁盘:${NC}"
    df -h "$SFTP_BASE" | tail -1 | sed 's/^/    /'
    echo ""
    echo -e "  ${BOLD}ACME 证书:${NC}"
    ls -1 /var/cache/nginx/acme-*/*.crt 2>/dev/null | sed 's/^/    /' || echo "    无"
    pause
}

menu_add_acme() {
    banner
    echo -e "  ${BOLD}为域名配置 ACME SSL${NC}"
    sep
    echo ""
    read -rp "  域名: " domain
    [ -z "$domain" ] && { pause; return; }

    if [ ! -f "/etc/nginx/sites-available/${domain}" ]; then
        err "站点 $domain 不存在，请先添加用户"
        pause
        return
    fi

    read -rp "  管理员邮箱 (默认 root@${domain}): " email
    email="${email:-root@${domain}}"

    read -rp "  环境 [staging/production] (默认 staging): " env
    env="${env:-staging}"

    case "$env" in
        staging)  acme_uri="https://acme-staging-v02.api.letsencrypt.org/directory" ;;
        production|prod) acme_uri="https://acme-v02.api.letsencrypt.org/directory" ;;
        *) err "无效环境"; pause; return ;;
    esac

    # 建 ACME 配置
    mkdir -p "/var/cache/nginx/acme-${domain}"
    chown -R "${NGINX_USER}:${NGINX_USER}" "/var/cache/nginx/acme-${domain}"
    chmod 700 "/var/cache/nginx/acme-${domain}"

    cat > "/etc/nginx/conf.d/acme-${domain}.conf" <<EOF
resolver 1.1.1.1 8.8.8.8 valid=300s;
resolver_timeout 5s;

acme_issuer letsencrypt_${domain} {
    uri ${acme_uri};
    contact mailto:${email};
    state_path /var/cache/nginx/acme-${domain};
    accept_terms_of_service;
}

acme_shared_zone zone=acme_${domain}:1m;
EOF

    # 改写 nginx 站点配置加入 SSL
    cat > "/etc/nginx/sites-available/${domain}" <<EOF
# ${domain} — ACME SSL enabled
server {
    listen 80;
    listen [::]:80;
    server_name ${domain} www.${domain};
    location / { return 404; }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    listen 443 quic reuseport;
    http3 on;

    server_name ${domain} www.${domain};

    root ${WWW_BASE}/${domain};
    index index.html index.htm;

    acme_certificate letsencrypt_${domain};

    ssl_certificate     \$acme_certificate;
    ssl_certificate_key \$acme_certificate_key;
    ssl_certificate_cache max=2;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;

    brotli on;
    brotli_comp_level 6;
    brotli_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript image/svg+xml;

    zstd on;
    zstd_comp_level 6;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location ~ /\. {
        deny all;
    }

    access_log /var/log/nginx/${domain}.access.log;
    error_log  /var/log/nginx/${domain}.error.log;
}
EOF

    if nginx -t 2>&1; then
        systemctl reload nginx
        info "ACME 已配置，访问 https://${domain} 将自动签发证书"
        if [[ "$env" == "staging" ]]; then
            warn "当前为 STAGING 模式，浏览器不信任。测试后请切 production"
        fi
    else
        err "nginx 配置错误"
    fi
    pause
}

menu_change_password() {
    banner
    echo -e "  ${BOLD}修改 SFTP 用户密码${NC}"
    sep
    list_users
    echo ""
    read -rp "  用户名: " user
    [ -z "$user" ] && { pause; return; }

    if ! id "$user" &>/dev/null; then
        err "用户 $user 不存在"
        pause
        return
    fi

    passwd "$user"
    info "密码已更新"
    pause
}

# ── 主菜单 ────────────────────────────────────────────────────────────────────
main() {
    while true; do
        banner
        echo -e "  ${BOLD}请选择操作:${NC}"
        echo ""
        echo -e "  ${GREEN} 1)${NC}  添加 SFTP 用户"
        echo -e "  ${RED} 2)${NC}  删除 SFTP 用户"
        echo -e "  ${CYAN} 3)${NC}  修改 SFTP 用户密码"
        echo -e "  ${YELLOW} 4)${NC}  修复 ACL 权限（单个/全部）"
        echo -e "  ${YELLOW} 5)${NC}  查看 ACL 权限"
        echo -e "  ${BLUE} 6)${NC}  配置 ACME SSL"
        echo -e "  ${BLUE} 7)${NC}  重启 Nginx"
        echo -e "  ${BLUE} 8)${NC}  重启 SSH"
        echo -e "  ${BLUE} 9)${NC}  服务状态"
        echo -e "  ${DIM} 0)  退出${NC}"
        echo ""
        sep
        read -rp "  输入选项 [0-9]: " choice

        case "$choice" in
            1) menu_add_user ;;
            2) menu_del_user ;;
            3) menu_change_password ;;
            4) menu_fix_acl ;;
            5) menu_show_acl ;;
            6) menu_add_acme ;;
            7) menu_restart_nginx ;;
            8) menu_restart_ssh ;;
            9) menu_status ;;
            0) echo ""; info "再见 👋"; exit 0 ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
    done
}

main "$@"
MANAGER_EOF

chmod +x "$MANAGER_BIN"
info "管理命令已安装: sftp-manager"

# ── 13. 防火墙 ────────────────────────────────────────────────────────────────
if command -v ufw &>/dev/null; then
    step "防火墙规则"
    ufw allow 22/tcp
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw allow 443/udp
    info "ufw 规则已添加"
fi

# ── 14. 保存配置 ──────────────────────────────────────────────────────────────
mkdir -p /etc/sftp-nginx
cat > "/etc/sftp-nginx/${SFTP_USER}.conf" <<EOF
# SFTP-Nginx user config — managed by sftp-manager
USER=${SFTP_USER}
DOMAIN=${SITE_DOMAIN}
CREATED=$(date '+%Y-%m-%d %H:%M:%S')
ACME_ENV=${ACME_ENV}
EOF

# ── 15. 完成 ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                    🎉 安装完成！                            ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${CYAN}SFTP${NC}"
echo "    用户:        ${SFTP_USER}"
echo "    监狱目录:    ${SFTP_HOME}"
echo "    上传路径:    sftp ${SFTP_USER}@your-server"
echo ""
echo -e "  ${CYAN}Nginx${NC}"
echo "    域名:        ${SITE_DOMAIN}"
echo "    ACME 环境:   ${ACME_ENV}"
echo "    HTTP/3:      ✅"
echo "    Brotli:      ✅"
echo "    Zstd:        ✅"
echo ""
echo -e "  ${CYAN}管理${NC}"
echo "    命令:        sftp-manager"
echo ""
if [[ "$ACME_ENV" == "staging" ]]; then
    echo -e "  ${YELLOW}⚠️  STAGING 模式 — 切 prod:${NC}"
    echo "    1. 编辑 /etc/nginx/conf.d/acme-${SITE_DOMAIN}.conf"
    echo "    2. 把 uri 改为 https://acme-v02.api.letsencrypt.org/directory"
    echo "    3. nginx -t && systemctl reload nginx"
    echo ""
fi
echo -e "  ${YELLOW}建议下一步:${NC}"
echo "    1. 用 sftp-manager 添加更多用户"
echo "    2. 测试 SFTP 上传"
echo "    3. 访问 https://${SITE_DOMAIN} 验证 ACME 签发"
echo ""
