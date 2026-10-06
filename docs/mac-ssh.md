# Mac 连接 ECE 节点

ECE 集群要求连接 [CMU VPN](https://www.cmu.edu/computing/services/endpoint/network-access/vpn/how-to/index.html)。下面假设你在 Mac 本地有一个已经接入 CMU VPN 的 SOCKS5 代理（例如通过 [academic-vpn-kit](https://github.com/MTDickens/academic-vpn-kit) 搭建的节点，或 Clash 等客户端）。把下文的 `127.0.0.1:1145` 换成你自己的代理地址；如果 Mac 直接连着 CMU VPN，删掉 `ProxyCommand` 那一行即可。

## SSH 配置

在 `~/.ssh/config` 加入（把 `你的AndrewID` 换成自己的）：

```sshconfig
Host ece ece0*
    User 你的AndrewID
    ProxyCommand nc -X 5 -x 127.0.0.1:1145 %h %p
    StrictHostKeyChecking accept-new

Host ece
    HostName ece005.ece.local.cmu.edu

Host ece0*
    HostName %h.ece.local.cmu.edu
```

```bash
ssh ece        # 默认节点（改 Host ece 下的编号即可换默认）
ssh ece012     # 任意编号，自动补成 ece012.ece.local.cmu.edu
```

说明：

- `nc -X 5` 把**主机名**交给代理解析。`ece.local.cmu.edu` 是 CMU 内网域名，只有 VPN 那一端能解析。用 Clash 时，确保 `cmu.edu` 的规则指向接入 VPN 的节点，例如 `DOMAIN-SUFFIX,cmu.edu,<节点或代理组>`。
- 把别名都写在第一条 `Host` 行里：OpenSSH 改写 `HostName` 后不会重新匹配 `Host *.ece.local.cmu.edu` 这类规则，`ProxyCommand` 必须直接作用在别名上。
- `StrictHostKeyChecking accept-new`：第一次连新节点时自动记下指纹；已记录的指纹变化时仍会拒绝连接。
- 密码是 Andrew 密码。连续认证失败可能触发账号临时锁定。

## VS Code

Remote-SSH 直接使用同一份配置：`Remote-SSH: Connect to Host` → 输入 `ece` 或 `ece012`。带通配符的主机不会出现在下拉列表中，手动输入即可。

VS Code 会在远端 home 安装约几百 MB 的服务端，而 home 只有 2GB。空间不够时，在 VS Code 设置里把它放到 scratch：

```json
"remote.SSH.serverInstallPath": { "ece": "/scratch/你的AndrewID" }
```

## 在 Mac 上控制 Claude Code

集群上用本仓库的 `ece-claude` 启动 Remote Control 后，打开 Mac 上的 **Claude 应用 → Code**，在会话列表里找到以节点命名的会话（绿点表示在线）。这条连接走的是 Anthropic 的服务，不经过 SSH，SSH 断开也不影响，只要节点上的进程还在运行。
