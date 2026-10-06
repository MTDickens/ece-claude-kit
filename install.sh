#!/usr/bin/env bash
# 一键安装 / 更新：
#   curl -fsSL https://raw.githubusercontent.com/MTDickens/ece-claude-kit/main/install.sh | bash
# 把工具放到 ~/.local/share/ece-claude-kit（home 在各节点共享，只占几十 KB），
# 然后在当前节点运行安装向导。换新节点时再跑一次同一条命令即可。
set -euo pipefail

REPO="${ECK_REPO:-https://github.com/MTDickens/ece-claude-kit}"
BRANCH="${ECK_BRANCH:-main}"
DEST="${ECK_HOME:-$HOME/.local/share/ece-claude-kit}"

mkdir -p "$(dirname "$DEST")"
if [ -d "$DEST/.git" ] && command -v git >/dev/null 2>&1; then
  echo "==> 更新 $DEST"
  git -C "$DEST" pull --ff-only -q || echo "[!] 更新失败，继续使用当前版本" >&2
elif command -v git >/dev/null 2>&1; then
  echo "==> 下载到 $DEST"
  rm -rf "$DEST"
  git clone -q --depth 1 -b "$BRANCH" "$REPO.git" "$DEST"
else
  echo "==> 下载到 $DEST（没有 git，使用压缩包）"
  rm -rf "$DEST" && mkdir -p "$DEST"
  curl -fsSL "$REPO/archive/refs/heads/$BRANCH.tar.gz" | tar -xz -C "$DEST" --strip-components 1
fi

ECK_SKIP_SELF_UPDATE=1 exec bash "$DEST/entrypoint.sh" install "$@"
