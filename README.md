# ECE Claude Kit

在 CMU ECE 集群节点（`ece000`–`ece031`）上一键安装 **Claude Code + herdr**，用 Claude Code 的 **Remote Control** 从 Mac 上的 Claude 应用直接控制集群上的会话。herdr 代替 tmux，保证断开 SSH 后会话继续运行。

不需要 root，不开放任何端口：Remote Control 由节点主动向外连接 Anthropic，Mac 上的 Claude 应用通过你的账号看到这个会话。

## 一键安装

先 `ssh` 登录一台 ECE 节点（Mac 端怎么连见 [Mac 连接指南](docs/mac-ssh.md)），然后运行：

```bash
curl -fsSL https://raw.githubusercontent.com/MTDickens/ece-claude-kit/main/install.sh | bash
```

直接进入中文向导：工作目录、是否使用 herdr、Claude Code 更新通道。每项都显示默认值，回车采用默认值；再次运行沿用已保存的设置。问完后自动安装，最后引导登录 Claude（把链接复制到 Mac 浏览器授权，再把代码粘回终端）。

**换节点时，在新节点上再跑一次同一条命令。** `/scratch` 是每台机器各自的本地盘，程序和登录信息要在每台上各装一次；设置和命令放在共享的 home 里，不用重新填写。

要求：

- ECE 学生账号，能 SSH 登录集群（校外需经 CMU VPN）
- Claude **Pro / Max / Team / Enterprise** 账号。Remote Control 不支持 API key
- Mac 上的 Claude 应用登录同一个账号

## 日常使用

```bash
herdr          # 打开 herdr
ece-claude     # 在 herdr 面板里运行，启动 Remote Control
```

第一次启动会问 `Trust <目录>?` 和 `Enable Remote Control?`，都答 `y`。然后按 `Ctrl+B` 再按 `Q` 离开 herdr，Claude 继续在后台运行；再次运行 `herdr` 回到面板。

在 Mac 上打开 **Claude 应用 → Code**，会话列表里出现以节点命名的会话（如 `ece005`），绿点表示在线，点进去即可使用。浏览器打开 [claude.ai/code](https://claude.ai/code) 或手机上的 Claude App 也可以。

`ece-claude` 默认在设置的工作目录里启动，也可以指定目录：`ece-claude /scratch/$USER/my-project`。如果当前不在 herdr / tmux 里，它会提醒并提供直接打开 herdr。

## 菜单

运行 `ece-kit` 打开菜单，根据本节点状态自动选好默认项：

```text
ECE Claude Kit  ·  节点 ece005  ·  已安装 2.1.x，已登录

  1. 安装或更新本节点（首次使用、换新节点选这个）
  2. 启动 Remote Control
  3. 登录 / 重新登录 Claude
  4. 检查状态
  5. 修改设置（工作目录、herdr、更新通道）
  6. 删除本节点的安装
  0. 退出
```

“检查状态”显示 Claude Code 版本、登录状态、herdr、Remote Control 是否在运行、GPU 占用和 home 配额。

以下子命令保留给自动化使用，普通使用直接运行 `ece-kit`：

```bash
ece-kit install [--yes]    # --yes：不提问，沿用已保存的设置或默认值
ece-kit start [目录]       # 等同于 ece-claude
ece-kit login
ece-kit status
ece-kit settings
ece-kit uninstall [--yes]  # --yes：只删除本节点的程序和登录信息
```

## 文件放在哪里

ECE 的 home 在 AFS 上，只有 2GB，超额后无法登录；AFS 的登录凭证 24 小时过期，长时间运行的进程会写不了文件。所以程序、登录信息和工作目录都放在本节点的 `/scratch`。

| 位置 | 内容 | 范围 |
|---|---|---|
| `/scratch/$USER/claude-bin/` | Claude Code 程序版本（`~/.local/share/claude` 软链接到这里） | 本节点 |
| `/scratch/$USER/claude-config/` | Claude 设置、登录信息、会话记录（`CLAUDE_CONFIG_DIR`） | 本节点 |
| `/scratch/$USER/work/` | 默认工作目录 | 本节点 |
| `~/.local/share/ece-claude-kit/` | 本工具（几十 KB） | 所有节点 |
| `~/.local/bin/claude` | 启动脚本：自动选用本节点上的 Claude Code 版本 | 所有节点 |
| `~/.local/bin/ece-kit`、`ece-claude` | 命令 | 所有节点 |
| `~/.local/bin/herdr` | herdr | 所有节点 |
| `~/.config/ece-claude-kit/settings.env` | 设置 | 所有节点 |
| `~/.zshrc`（或 `.bashrc`、`.cshrc`） | `# >>> ece-claude-kit >>>` 配置块 | 所有节点 |

`/scratch/$USER` 设为只有自己可访问（700）。**`/scratch` 里超过 28 天的文件会被自动删除**：如果哪天 `claude` 报“本节点还没安装”，重新运行一键安装命令即可，可能需要重新登录。重要代码请用 git 推送到远端，或备份到 `/afs/ece.cmu.edu/usr/$USER`。

为什么 `~/.local/bin/claude` 是启动脚本而不是官方安装器的软链接：home 在所有节点共享，官方软链接指向某个具体版本；在 A 节点自动更新后，B 节点的 `claude` 就会指向一个本机不存在的版本。启动脚本每次在本节点的版本目录里选最新的一个。Claude Code 会保留自定义启动脚本，不会覆盖。

## 常见问题

| 现象 | 处理 |
|---|---|
| Mac 上看不到会话 | 确认 `ece-claude` 在运行（`ece-kit status`）、账号相同，且是 Pro/Max/Team/Enterprise |
| `herdr --version` 报 `GLIBC_2.xx not found` | 预编译程序与 RHEL 8 不兼容。`ece-kit settings` 关闭 herdr，改用 tmux |
| 节点重启后会话离线 | 重新 `herdr`，再运行 `ece-claude`。同一目录下会恢复之前的会话 |
| 登录链接打不开 / 粘贴代码失败 | 运行 `claude`，在里面输入 `/login` |
| `claude` 报本节点没安装 | 新节点或 scratch 被清理，重新运行一键安装 |

## 使用规范

ECE 集群是共享资源：

- 不要用 `--permission-mode bypassPermissions` 之类跳过所有确认的模式
- 留意 Claude 启动的进程，不要长时间占满 GPU 或全部 CPU；跑任务前先 `nvidia-smi`
- 不要把受限数据（研究组保密数据、他人代码）发给外部 API；课程作业是否允许使用 AI 以各课程规定为准
- 本工具不安装任何隧道或代理服务；不要在集群上运行 Tailscale 等绕过 CMU VPN 的工具，除非 ECE-ITS 书面同意

参考：[CMU Computing Policy](https://www.cmu.edu/policies/information-technology/computing.html)、[ECE Linux 资源指南](https://cmu-enterprise.atlassian.net/wiki/spaces/ITS/pages/3549888534/ECE+Linux+Computing+Resources+Guide)、[Claude Code Remote Control](https://code.claude.com/docs/en/remote-control)、[herdr](https://herdr.dev/docs/)。

## 维护

```bash
bash tests/test_kit.sh     # 在临时 HOME / scratch 中跑完整流程，用假的下载器，不联网
shellcheck -x entrypoint.sh install.sh bin/* tests/*.sh
```

维护指引见 [`skills/ece-claude-kit/SKILL.md`](skills/ece-claude-kit/SKILL.md)。
