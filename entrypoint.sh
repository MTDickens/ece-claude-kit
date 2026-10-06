#!/usr/bin/env bash
# ECE Claude Kit 入口。
# 不带参数运行进入中文菜单；子命令保留给自动化和进阶使用：
#   install [--yes]   安装或更新本节点（Claude Code + herdr + Remote Control 启动命令）
#   start [目录]      启动 Claude Code Remote Control
#   login             登录 / 重新登录 Claude
#   status            检查本节点状态
#   settings          修改设置（工作目录、herdr、更新通道）
#   uninstall [--yes] 删除本节点的安装
set -euo pipefail
umask 077

KIT_ROOT="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)"

USER="${USER:-$(id -un)}"
SCRATCH_ROOT="${ECK_SCRATCH_ROOT:-/scratch}"
S="$SCRATCH_ROOT/$USER"                       # 本节点私人 scratch（各节点独立，超过 28 天的文件会被删）
CFG_DIR="$S/claude-config"                    # Claude 配置与登录信息
BIN_DIR="$S/claude-bin"                       # Claude Code 程序版本
LOCAL_BIN="$HOME/.local/bin"
SHARE_LINK="$HOME/.local/share/claude"        # 原生安装器写入的位置，软链接到 BIN_DIR
SETTINGS_DIR="$HOME/.config/ece-claude-kit"   # home 在所有节点共享，设置只需保存一次
SETTINGS="$SETTINGS_DIR/settings.env"
NODE="$(hostname -s 2>/dev/null || hostname)"
LAUNCHER_MARK='# ece-claude-kit launcher'
# herdr 默认把 socket 放在 ~/.config/herdr，但 AFS 不支持 Unix socket（bind 报 Operation not permitted），
# server 起不来，herdr 会报 "server did not become ready within 15s"。改放到本节点的 /tmp。
HERDR_RUN_DIR="${ECK_HERDR_RUN_DIR:-/tmp/herdr-$USER}"

export CLAUDE_CONFIG_DIR="$CFG_DIR"
export PATH="$LOCAL_BIN:$PATH"
export HERDR_SOCKET_PATH="$HERDR_RUN_DIR/herdr.sock"
export HERDR_CLIENT_SOCKET_PATH="$HERDR_RUN_DIR/herdr-client.sock"
mkdir -p "$HERDR_RUN_DIR" 2>/dev/null || true

# ---------------------------------------------------------------- 界面
if [ -t 1 ]; then
  G=$'\033[1;32m' Y=$'\033[1;33m' R=$'\033[1;31m' B=$'\033[1m' D=$'\033[2m' N=$'\033[0m'
else
  G='' Y='' R='' B='' D='' N=''
fi
say()  { printf '\n%s==> %s%s\n' "$G" "$*" "$N"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '%s[!] %s%s\n' "$Y" "$*" "$N" >&2; }
die()  { printf '%s[x] %s%s\n' "$R" "$*" "$N" >&2; exit 1; }

has_tty() { { : </dev/tty; } 2>/dev/null; }

# ask "问题" "默认值"：回车采用默认值；没有终端时直接用默认值
ask() {
  local q="$1" d="${2:-}" a=""
  if has_tty; then
    printf '%s %s[%s]%s: ' "$q" "$D" "$d" "$N" >/dev/tty
    IFS= read -r a </dev/tty || a=""
  fi
  printf '%s' "${a:-$d}"
}

# ask_yn "问题" y|n：返回 0 表示是
ask_yn() {
  local a
  a="$(ask "$1 (y/n)" "$2")"
  case "$a" in
    y|Y|yes|YES|是) return 0 ;;
    n|N|no|NO|否)   return 1 ;;
    *) [ "$2" = y ] ;;
  esac
}

# ---------------------------------------------------------------- 设置
WORK_DIR="$S/work"
USE_HERDR=yes
CHANNEL=latest

load_settings() {
  if [ -f "$SETTINGS" ]; then
    # shellcheck disable=SC1090
    . "$SETTINGS"
  fi
}

save_settings() {
  mkdir -p "$SETTINGS_DIR"
  {
    echo '# ece-claude-kit 设置（所有节点共享）'
    printf 'WORK_DIR=%q\n' "$WORK_DIR"
    printf 'USE_HERDR=%q\n' "$USE_HERDR"
    printf 'CHANNEL=%q\n' "$CHANNEL"
  } >"$SETTINGS"
}

ask_settings() {
  say "设置（回车采用默认值，下次运行沿用）"
  WORK_DIR="$(ask "工作目录（建议放在 $SCRATCH_ROOT 下）" "$WORK_DIR")"
  case "$WORK_DIR" in
    "$SCRATCH_ROOT"/*) ;;
    *) warn "工作目录不在 $SCRATCH_ROOT 下。AFS 上的登录凭证 24 小时过期，到时 Claude 会写不了文件。" ;;
  esac
  if ask_yn "使用 herdr 保持会话（代替 tmux）" "$( [ "$USE_HERDR" = yes ] && echo y || echo n )"; then
    USE_HERDR=yes
  else
    USE_HERDR=no
  fi
  local c
  c="$(ask "Claude Code 更新通道：latest（最新）/ stable（约晚一周、更稳）" "$CHANNEL")"
  case "$c" in
    latest|stable) CHANNEL="$c" ;;
    *) warn "无效的通道：$c，保持 $CHANNEL" ;;
  esac
  save_settings
}

# ---------------------------------------------------------------- 检测
latest_version() {
  # 版本目录名都是纯数字版本号，这里用 ls | grep 是安全的
  # shellcheck disable=SC2010
  ls -1 "$SHARE_LINK/versions" 2>/dev/null \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n 1 | grep .
}
claude_installed() { latest_version >/dev/null 2>&1; }
logged_in()        { claude_installed && claude auth status >/dev/null 2>&1; }
herdr_ok()         { command -v herdr >/dev/null 2>&1 && herdr --version >/dev/null 2>&1; }

# 是否已在 herdr / tmux / screen 中（断开 SSH 后进程是否还能活着）
in_multiplexer() {
  [ -n "${TMUX:-}${STY:-}" ] && return 0
  local pid=$$ comm
  while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null; do
    comm="$(ps -o comm= -p "$pid" 2>/dev/null | tr -d ' ')" || return 1
    case "$comm" in herdr*) return 0 ;; esac
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')" || return 1
  done
  return 1
}

# ---------------------------------------------------------------- shell 配置
login_shell() {
  local s
  s="$(getent passwd "$USER" 2>/dev/null | cut -d: -f7 || true)"
  basename "${s:-${SHELL:-bash}}"
}

# 删除本工具（以及早期一键脚本）写入的配置块，便于重写
strip_block() {
  local f="$1"
  [ -f "$f" ] || return 0
  awk '/^# >>> ece-claude(-kit)? >>>$/ {skip=1; next}
       /^# <<< ece-claude(-kit)? <<<$/ {skip=0; next}
       !skip' "$f" >"$f.eck-tmp"
  cat "$f.eck-tmp" >"$f"
  rm -f "$f.eck-tmp"
}

setup_shell_rc() {
  local sh rc block herdr_sh
  sh="$(login_shell)"
  herdr_sh="# herdr 的 socket 不能放在 AFS 上，放到本节点 /tmp
(umask 077; mkdir -p \"$HERDR_RUN_DIR\") 2>/dev/null
export HERDR_SOCKET_PATH=\"$HERDR_SOCKET_PATH\"
export HERDR_CLIENT_SOCKET_PATH=\"$HERDR_CLIENT_SOCKET_PATH\""
  case "$sh" in
    zsh)
      rc="$HOME/.zshrc"
      block="setopt interactivecomments
export CLAUDE_CONFIG_DIR=$CFG_DIR
export PATH=\$HOME/.local/bin:\$PATH
$herdr_sh" ;;
    tcsh|csh)
      rc="$HOME/.cshrc"
      block="setenv CLAUDE_CONFIG_DIR $CFG_DIR
set path = (\$HOME/.local/bin \$path)
# herdr 的 socket 不能放在 AFS 上，放到本节点 /tmp
(umask 077; mkdir -p $HERDR_RUN_DIR) >& /dev/null
setenv HERDR_SOCKET_PATH $HERDR_SOCKET_PATH
setenv HERDR_CLIENT_SOCKET_PATH $HERDR_CLIENT_SOCKET_PATH" ;;
    *)
      rc="$HOME/.bashrc"
      block="export CLAUDE_CONFIG_DIR=$CFG_DIR
export PATH=\$HOME/.local/bin:\$PATH
$herdr_sh" ;;
  esac
  touch "$rc"
  strip_block "$rc"
  printf '\n# >>> ece-claude-kit >>>\n%s\n# <<< ece-claude-kit <<<\n' "$block" >>"$rc"
  info "已写入 $rc（登录 shell：$sh）"
}

# ---------------------------------------------------------------- 安装
link_share_dir() {
  mkdir -p "$BIN_DIR" "$HOME/.local/share"
  if [ -e "$SHARE_LINK" ] && [ ! -L "$SHARE_LINK" ]; then
    local bak
    bak="$SHARE_LINK.bak.$(date +%s)"
    mv "$SHARE_LINK" "$bak"
    warn "已有的 $SHARE_LINK 移到了 $bak"
  fi
  ln -sfn "$BIN_DIR" "$SHARE_LINK"
}

install_claude() {
  info "通道：$CHANNEL"
  curl -fsSL https://claude.ai/install.sh | bash -s "$CHANNEL"
  # home 在各节点共享，程序装在各节点自己的 /scratch：
  # 把 ~/.local/bin/claude 换成启动脚本，每次启动时选用本节点上的最新版本。
  rm -f "$LOCAL_BIN/claude"
  cp "$KIT_ROOT/bin/claude-launcher" "$LOCAL_BIN/claude"
  chmod 700 "$LOCAL_BIN/claude"
  hash -r
  claude_installed || die "Claude Code 安装后没有找到程序，请检查上面的安装输出"
  info "$(claude --version 2>/dev/null || echo "版本 $(latest_version)")"
}

install_herdr() {
  if ! command -v herdr >/dev/null 2>&1; then
    curl -fsSL https://herdr.dev/install.sh | sh
    hash -r
  fi
  if herdr_ok; then
    info "$(herdr --version 2>/dev/null | head -n 1)"
    herdr integration install claude >/dev/null 2>&1 \
      || warn "herdr 的 Claude 集成没装上，只影响 herdr 重启后自动恢复会话"
  elif command -v herdr >/dev/null 2>&1; then
    warn "herdr 无法运行（可能是 glibc 版本太旧）。运行 herdr --version 查看报错。"
  else
    warn "没有找到 herdr 命令，请检查上面安装脚本的输出。"
  fi
}

link_commands() {
  ln -sfn "$KIT_ROOT/entrypoint.sh" "$LOCAL_BIN/ece-kit"
  ln -sfn "$KIT_ROOT/bin/ece-claude" "$LOCAL_BIN/ece-claude"
}

self_update() {
  # install.sh 刚更新过就跳过；没有上游分支（手动拷贝的目录）也跳过
  if [ -n "${ECK_SKIP_SELF_UPDATE:-}" ]; then
    info "已是最新"
    return 0
  fi
  if [ -d "$KIT_ROOT/.git" ] && command -v git >/dev/null 2>&1 \
    && git -C "$KIT_ROOT" rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
    if git -C "$KIT_ROOT" pull --ff-only -q 2>/dev/null; then
      info "工具本身已是最新"
    else
      warn "工具本身更新失败（网络或本地有修改），继续使用当前版本"
    fi
  fi
}

do_install() {
  local yes="${1:-}"
  load_settings
  [ "$yes" = --yes ] || ask_settings
  save_settings

  say "1/6 更新工具本身"
  self_update

  say "2/6 准备 $S（本节点：$NODE）"
  mkdir -p "$S" "$CFG_DIR" "$WORK_DIR" "$LOCAL_BIN"
  chmod 700 "$S"
  link_share_dir
  info "Claude Code 程序与登录信息放在 $S，不占用 home 的 2GB 配额"

  say "3/6 写入 shell 配置"
  setup_shell_rc

  say "4/6 Claude Code"
  install_claude

  say "5/6 herdr"
  if [ "$USE_HERDR" = yes ]; then install_herdr; else info "已关闭，跳过"; fi
  link_commands

  say "6/6 登录"
  if logged_in; then
    info "本节点已登录"
  else
    do_login || true
  fi

  local keep
  if [ "$USE_HERDR" = yes ]; then
    keep="  ${B}herdr${N}          打开 herdr（离开：Ctrl+B 再按 Q；回来：再次运行 herdr）"
  else
    keep="  ${B}tmux new -s claude${N}  打开 tmux（离开：Ctrl+B 再按 D；回来：tmux attach -t claude）"
  fi
  cat <<EOF

${B}完成。${N}以后每次使用：

$keep
  ${B}ece-claude${N}     在 herdr / tmux 里运行，启动 Remote Control
                 第一次会问 Trust? 和 Enable Remote Control?，都答 y
  ${B}ece-kit${N}        打开菜单（状态、登录、设置、卸载）

Mac 上：打开 Claude 应用 → Code，找到 ${B}$NODE${N}（绿点表示在线）。
新开的终端会自动加载配置；当前终端请先运行：${B}exec \$SHELL -l${N}
EOF
}

# ---------------------------------------------------------------- 登录
do_login() {
  claude_installed || die "本节点（$NODE）还没有安装。先运行：ece-kit install"
  if ! has_tty; then
    warn "没有交互终端，跳过登录。之后运行：ece-kit login"
    return 1
  fi
  say "登录 Claude（需要 Pro / Max / Team / Enterprise 账号）"
  info "按提示把链接复制到 Mac 的浏览器里授权，再把页面显示的代码粘回这里。"
  if claude auth login </dev/tty && logged_in; then
    info "登录成功"
  else
    warn "登录没有完成。也可以运行 claude，在里面输入 /login。"
    return 1
  fi
}

# ---------------------------------------------------------------- 启动
do_start() {
  load_settings
  claude_installed || die "本节点（$NODE）还没有安装。先运行：ece-kit install"
  if ! logged_in; then
    warn "本节点还没有登录 Claude"
    do_login || die "未登录，无法启动 Remote Control"
  fi
  local dir="${1:-$WORK_DIR}"
  mkdir -p "$dir"
  cd "$dir"
  if ! in_multiplexer; then
    warn "当前不在 herdr / tmux 里：断开 SSH 后 Remote Control 会停止。"
    if has_tty; then
      if [ "$USE_HERDR" = yes ] && herdr_ok \
        && ask_yn "现在打开 herdr？进入后在面板里运行 ece-claude" y; then
        exec herdr
      fi
      ask_yn "仍在当前终端直接启动" n || exit 0
    fi
  fi
  say "在 $dir 启动 Remote Control（会话名：$NODE）"
  info "Mac 上打开 Claude 应用 → Code，找到 $NODE（绿点表示在线）。停止：Ctrl+C"
  exec claude remote-control --name "$NODE"
}

# ---------------------------------------------------------------- 状态
do_status() {
  load_settings
  say "节点 $NODE"
  if [ -d "$S" ]; then
    info "Scratch      $S（已用 $(du -sh "$S" 2>/dev/null | cut -f1)，$SCRATCH_ROOT 剩余 $(df -h "$SCRATCH_ROOT" 2>/dev/null | awk 'NR==2{print $4}')）"
  else
    info "Scratch      $S 不存在（本节点未安装）"
  fi
  if claude_installed; then
    info "Claude Code  $(latest_version)"
    if logged_in; then info "登录         已登录"; else info "登录         ${Y}未登录${N}（ece-kit login）"; fi
  else
    info "Claude Code  ${Y}未安装${N}（ece-kit install）"
  fi
  if [ "$USE_HERDR" != yes ]; then
    info "herdr        已关闭"
  elif herdr_ok; then
    info "herdr        $(herdr --version 2>/dev/null | head -n 1)"
  else
    info "herdr        ${Y}不可用${N}"
  fi
  if pgrep -u "$USER" -f 'remote-control' >/dev/null 2>&1; then
    info "Remote Control 运行中"
  else
    info "Remote Control 未运行（ece-claude）"
  fi
  if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-gpu=name,memory.used,memory.total,utilization.gpu \
      --format=csv,noheader 2>/dev/null | sed 's/^/    GPU          /' || true
  fi
  if command -v fs >/dev/null 2>&1; then
    info "home 配额    $(fs lq "$HOME" -human 2>/dev/null | awk 'NR==2{print $3" / "$2" ("$4")"}')"
  fi
  info "工作目录     $WORK_DIR"
  info "设置文件     $SETTINGS"
}

# ---------------------------------------------------------------- 卸载
do_uninstall() {
  local yes="${1:-}"
  say "删除本节点（$NODE）的安装"
  info "会删除：$BIN_DIR、$CFG_DIR（程序、登录信息、会话记录）"
  info "保留：工作目录 $WORK_DIR，以及 home 里各节点共享的命令和设置"
  if [ "$yes" != --yes ] && ! ask_yn "确认删除" n; then
    info "已取消"
    return 0
  fi
  rm -rf "$BIN_DIR" "$CFG_DIR"
  info "已删除。其他节点不受影响；重新安装运行 ece-kit install。"
  if [ "$yes" != --yes ] && ask_yn "同时删除所有节点共享的部分（命令、shell 配置块、设置）" n; then
    rm -f "$LOCAL_BIN/ece-kit" "$LOCAL_BIN/ece-claude"
    if grep -q "$LAUNCHER_MARK" "$LOCAL_BIN/claude" 2>/dev/null; then rm -f "$LOCAL_BIN/claude"; fi
    [ -L "$SHARE_LINK" ] && rm -f "$SHARE_LINK"
    for rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.cshrc"; do strip_block "$rc"; done
    rm -rf "$SETTINGS_DIR"
    info "共享部分已删除。工具目录 $KIT_ROOT 请自行删除。"
  fi
}

# ---------------------------------------------------------------- 菜单
menu() {
  load_settings
  local state def
  if ! claude_installed; then
    state="${Y}本节点未安装${N}"; def=1
  elif ! logged_in; then
    state="已安装 $(latest_version)，${Y}未登录${N}"; def=3
  else
    state="已安装 $(latest_version)，已登录"; def=2
  fi
  printf '\n%sECE Claude Kit%s  ·  节点 %s  ·  %s\n\n' "$B" "$N" "$NODE" "$state"
  cat <<'EOF'
  1. 安装或更新本节点（首次使用、换新节点选这个）
  2. 启动 Remote Control
  3. 登录 / 重新登录 Claude
  4. 检查状态
  5. 修改设置（工作目录、herdr、更新通道）
  6. 删除本节点的安装
  0. 退出

EOF
  case "$(ask "请选择" "$def")" in
    1) do_install ;;
    2) do_start ;;
    3) do_login ;;
    4) do_status ;;
    5) load_settings; ask_settings; info "已保存到 $SETTINGS" ;;
    6) do_uninstall ;;
    0|q) ;;
    *) die "无效的选择" ;;
  esac
}

usage() { sed -n '2,9p' "$KIT_ROOT/entrypoint.sh" | sed 's/^# \{0,1\}//'; }

case "${1:-}" in
  '')        menu ;;
  install)   do_install "${2:-}" ;;
  start)     shift; do_start "$@" ;;
  login)     do_login ;;
  status)    do_status ;;
  settings)  load_settings; ask_settings ;;
  uninstall) do_uninstall "${2:-}" ;;
  -h|--help|help) usage ;;
  *) usage; exit 1 ;;
esac
