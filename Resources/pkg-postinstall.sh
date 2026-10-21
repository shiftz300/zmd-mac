#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/pkg-user.sh"
zmd_pkg_user "$@"
IFS= read -r ZMD_INSTALL_REGION < "$(dirname "$0")/region"
case "$ZMD_INSTALL_REGION" in cn|global) ;; *) exit 1 ;; esac
zmd_as_user '/Library/Application Support/zmd-mac/zmd' install --region "$ZMD_INSTALL_REGION" --desktop
