#!/bin/zsh
set -eu

label="${1:-snapshot}"
if [[ ! "$label" =~ '^[A-Za-z0-9._-]+$' ]]; then
  echo "标签只能包含字母、数字、点、下划线和连字符" >&2
  exit 2
fi

mkdir -p artifacts
output="artifacts/network-${label}.txt"
if [[ -e "$output" ]]; then
  echo "快照已存在，不会覆盖：$output" >&2
  exit 1
fi

{
  date -u
  echo "## default route"
  route -n get default 2>&1 || echo "default route unavailable (permission or route error)"
  echo "## dns"
  scutil --dns 2>&1 || echo "dns snapshot unavailable (permission error)"
  echo "## utun interfaces"
  ifconfig 2>&1 | awk '/^utun[0-9]+:/{print $1}' || echo "interface snapshot unavailable"
  echo "## local proxy listeners"
  lsof -nP -iTCP:21080 -iTCP:21081 -sTCP:LISTEN 2>&1 || echo "no matching listeners or listener snapshot unavailable"
} > "$output"

chmod 600 "$output"
echo "已保存只读网络快照：$output"
