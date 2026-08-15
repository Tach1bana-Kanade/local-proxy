#!/bin/zsh
set -u

echo "LocalProxy 阶段 0 诊断"
echo "架构：$(uname -m)"
echo "系统：$(sw_vers -productVersion)"

if command -v swift >/dev/null 2>&1; then
  swift --version
else
  echo "Swift：未安装"
fi

if command -v mihomo >/dev/null 2>&1; then
  echo "Mihomo：$(command -v mihomo)"
  mihomo -v
else
  echo "Mihomo：未安装"
fi

for port in 21080 21081; do
  if lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | tail -n +2 | grep -q .; then
    echo "127.0.0.1:$port：正在监听"
  fi
  probe_result="$(nc -vz -G 1 127.0.0.1 "$port" 2>&1)"
  probe_status=$?
  if [[ $probe_status -eq 0 ]]; then
    echo "127.0.0.1:$port：可连接"
  elif [[ "$probe_result" == *"Operation not permitted"* ]]; then
    echo "127.0.0.1:$port：当前环境不允许发起连接探测"
  else
    echo "127.0.0.1:$port：不可连接"
  fi
done

if [[ -x /Applications/Quickcat.app/Contents/MacOS/Quickcat ]]; then
  echo "Quickcat：已安装"
else
  echo "Quickcat：未在默认路径找到"
fi
