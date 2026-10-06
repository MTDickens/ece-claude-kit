#!/usr/bin/env bash
# shellcheck disable=SC2015  # ok() 不会失败，A && ok || fail 用法安全
# 本地冒烟测试：在临时 HOME 和临时 scratch 中运行完整流程。
# 用假的 curl 代替真实下载（不访问网络、不登录、不需要 ECE 节点）。
#   bash tests/test_kit.sh
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

export HOME="$T/home" USER=tester ECK_SCRATCH_ROOT="$T/scratch" SHELL=/bin/zsh
mkdir -p "$HOME" "$ECK_SCRATCH_ROOT" "$T/fakebin"
S="$ECK_SCRATCH_ROOT/tester"
pass=0
ok()   { pass=$((pass + 1)); echo "  ok  $*"; }
fail() { echo "  FAIL $*" >&2; exit 1; }

# 假 getent：让登录 shell 判定为 zsh
cat >"$T/fakebin/getent" <<'EOF'
#!/bin/sh
echo "tester:x:1000:1000::/home/tester:/bin/zsh"
EOF

# 假 curl：根据 URL 输出模拟安装脚本
cat >"$T/fakebin/curl" <<'EOF'
#!/bin/sh
for a; do url="$a"; done
case "$url" in
  *claude.ai/install.sh)
    cat <<'INSTALL'
mkdir -p "$HOME/.local/share/claude/versions" "$HOME/.local/bin"
f="$HOME/.local/share/claude/versions/9.9.9"
cat >"$f" <<'BIN'
#!/bin/sh
case "$1" in
  --version) echo "9.9.9 (Claude Code)" ;;
  auth) [ -f "$CLAUDE_CONFIG_DIR/.fake-login" ] ;;
  *) echo "fake-claude cfg=$CLAUDE_CONFIG_DIR args=$*" ;;
esac
BIN
chmod +x "$f"
ln -sfn "$f" "$HOME/.local/bin/claude"
echo "installer channel=$1"
INSTALL
    ;;
  *herdr.dev/install.sh)
    cat <<'INSTALL'
mkdir -p "$HOME/.local/bin"
printf '#!/bin/sh\ncase "$1" in --version) echo "herdr 0.0.0-test";; esac\nexit 0\n' >"$HOME/.local/bin/herdr"
chmod +x "$HOME/.local/bin/herdr"
INSTALL
    ;;
  *) echo "unexpected url: $url" >&2; exit 22 ;;
esac
EOF
chmod +x "$T/fakebin/"*
export PATH="$T/fakebin:$PATH"

# 早期一键脚本写过的旧配置块，应被替换而不是重复
printf '# >>> ece-claude >>>\nexport OLD=1\n# <<< ece-claude <<<\n' >"$HOME/.zshrc"

echo "== install"
out="$(bash "$ROOT/entrypoint.sh" install --yes </dev/null 2>&1)" || { echo "$out"; fail "install 失败"; }
echo "$out" | grep -q 'installer channel=latest' && ok "安装器使用 latest 通道" || fail "通道"
[ -L "$HOME/.local/share/claude" ] && [ "$(readlink "$HOME/.local/share/claude")" = "$S/claude-bin" ] \
  && ok "程序目录软链接到 scratch" || fail "软链接"
[ -x "$S/claude-bin/versions/9.9.9" ] && ok "程序实际位于 scratch" || fail "程序位置"
grep -q 'ece-claude-kit launcher' "$HOME/.local/bin/claude" && ok "claude 是启动脚本" || fail "启动脚本"
[ "$(stat -c %a "$S")" = 700 ] && ok "scratch 目录权限 700" || fail "权限"
[ "$(grep -c '>>> ece-claude-kit >>>' "$HOME/.zshrc")" = 1 ] && ok "zshrc 写入一个配置块" || fail "配置块"
grep -q 'OLD=1' "$HOME/.zshrc" && fail "旧配置块未删除" || ok "旧配置块已替换"
[ -L "$HOME/.local/bin/ece-kit" ] && [ -L "$HOME/.local/bin/ece-claude" ] && ok "命令已链接" || fail "命令"
[ -x "$HOME/.local/bin/herdr" ] && ok "herdr 已安装" || fail "herdr"
grep -q 'USE_HERDR=yes' "$HOME/.config/ece-claude-kit/settings.env" && ok "设置已保存" || fail "设置"

echo "== launcher"
v="$(env -u CLAUDE_CONFIG_DIR "$HOME/.local/bin/claude" --version)"
[ "$v" = "9.9.9 (Claude Code)" ] && ok "启动脚本选中本节点版本" || fail "版本 $v"
o="$(env -u CLAUDE_CONFIG_DIR "$HOME/.local/bin/claude" x)"
echo "$o" | grep -q "cfg=$S/claude-config" && ok "未加载 shell 配置时也使用 scratch 配置目录" || fail "$o"

echo "== reinstall (幂等)"
bash "$ROOT/entrypoint.sh" install --yes </dev/null >/dev/null 2>&1 || fail "重复安装失败"
[ "$(grep -c '>>> ece-claude-kit >>>' "$HOME/.zshrc")" = 1 ] && ok "重复安装不重复写配置" || fail "重复配置块"

echo "== start（未登录）"
if bash "$ROOT/entrypoint.sh" start </dev/null >"$T/o" 2>&1; then fail "未登录时不应启动"; fi
grep -q '未登录' "$T/o" && ok "未登录时拒绝启动并提示" || { cat "$T/o"; fail "提示"; }

echo "== start（已登录）"
touch "$S/claude-config/.fake-login"
o="$("$HOME/.local/bin/ece-claude" "$S/proj" </dev/null 2>&1)"
echo "$o" | grep -q "args=remote-control --name $(hostname -s)" && ok "以节点名启动 Remote Control" || { echo "$o"; fail "启动参数"; }
[ -d "$S/proj" ] && ok "自定义工作目录已创建" || fail "工作目录"

echo "== status"
bash "$ROOT/entrypoint.sh" status </dev/null >"$T/o" 2>&1 || { cat "$T/o"; fail "status 失败"; }
grep -q '9.9.9' "$T/o" && grep -q '已登录' "$T/o" && ok "状态显示版本和登录" || { cat "$T/o"; fail "状态"; }

echo "== launcher 在未安装的节点"
mv "$S" "$S.other-node"
if o="$("$HOME/.local/bin/claude" --version 2>&1)"; then fail "未安装节点不应运行"; fi
echo "$o" | grep -q 'ece-kit install' && ok "未安装节点给出安装提示" || fail "$o"
mv "$S.other-node" "$S"

echo "== uninstall"
bash "$ROOT/entrypoint.sh" uninstall --yes </dev/null >/dev/null 2>&1 || fail "uninstall 失败"
[ ! -e "$S/claude-bin" ] && [ ! -e "$S/claude-config" ] && ok "本节点安装已删除" || fail "删除"
[ -d "$S/work" ] && ok "工作目录保留" || fail "工作目录被删"

echo "全部通过：$pass 项"
