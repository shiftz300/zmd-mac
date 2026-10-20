#!/bin/bash
# Shared by the package scripts. Never run Wine as root or guess a home path.
set -euo pipefail
zmd_pkg_user() {
    [ "${3:-/}" = / ] || { echo '仅支持安装到当前启动磁盘。' >&2; return 1; }
    ZMD_INSTALL_USER="$(/usr/bin/stat -f %Su /dev/console)"
    case "$ZMD_INSTALL_USER" in root|loginwindow|_mbsetupuser|'')
        echo '请先登录要安装游戏的 macOS 用户，再运行安装包。' >&2; return 1 ;;
    esac
    ZMD_INSTALL_UID="$(/usr/bin/id -u "$ZMD_INSTALL_USER")"
    [ "$ZMD_INSTALL_UID" -ge 501 ] || { echo '不支持为系统账户安装。' >&2; return 1; }
}
zmd_as_user() {
    /bin/launchctl asuser "$ZMD_INSTALL_UID" /usr/bin/sudo -H -u "$ZMD_INSTALL_USER" \
        /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin \
        USER="$ZMD_INSTALL_USER" LOGNAME="$ZMD_INSTALL_USER" "$@"
}
