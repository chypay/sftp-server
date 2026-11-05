# sftp-server
One-click SFTP server installation script

特性	说明
一键安装​	sudo ./install.sh uploader example.com staging 完事
交互式管理​	sftp-manager 命令进入菜单，9 个功能项
菜单功能​	增删用户、改密码、修复 ACL、配 ACME、重启服务、看状态
零外部依赖​	不依赖 certbot，ACME 走 nginx 原生模块
幂等安全​	重复跑不破坏数据，所有操作有校验

管理菜单
╔══════════════════════════════════════════════════╗
║          SFTP-NGINX 管理面板 v1.0               ║
║     SFTP Chroot · Nginx ACL · ACME SSL          ║
╚══════════════════════════════════════════════════╝

  1)  添加 SFTP 用户       ← 交互式，自动建监狱+ACL+nginx站点
  2)  删除 SFTP 用户       ← 级联清理（sshd + nginx + ACL + 文件）
  3)  修改 SFTP 用户密码
  4)  修复 ACL 权限        ← 支持单个或全部用户
  5)  查看 ACL 权限
  6)  配置 ACME SSL        ← 给已有域名加 HTTPS
  7)  重启 Nginx
  8)  重启 SSH
  9)  服务状态             ← 服务/站点/磁盘/证书一览
  0)  退出

