#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/pkg-user.sh"
zmd_pkg_user "$@"
zmd_as_user /usr/bin/arch -x86_64 /usr/bin/true || {
    echo '请先安装 Rosetta 2，再重新运行安装包。' >&2; exit 1;
}
