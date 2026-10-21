#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
./zmd setup || printf '\n安装未完成，请查看上方错误。\n'
printf '\n按回车关闭此窗口。'
IFS= read -r _
