# VS Code Remote SSH Proxy Skill

[English](README.md) | [中文](README.zh-CN.md)

这是一个 Codex skill，用于在 Windows 上配置 VS Code Remote SSH。当远端 Linux/HPC 服务器需要通过 SSH 反向端口转发使用你本机的 Clash/Mihomo 代理时，可以使用这个 skill。

这个 skill 会帮助 Codex 配置：

- 带 `RemoteForward` 的 SSH 配置
- 基于 SSH key 的免密登录
- 远端 VS Code 和 Claude Code 代理设置
- Codex、Claude Code、Python 这些默认远端 VS Code 扩展

## 功能

这个 skill 主要做三件事：

1. 帮助 VS Code “保存”登录状态：脚本会使用一次性密码安装 SSH 公钥，之后 VS Code Remote SSH 通过 SSH key 登录，不会保存明文密码。
2. 在远程服务器上配置 Codex 使用的代理环境：写入 SSH `RemoteForward` 规则，并设置远端 VS Code / Claude Code 代理：

   ```json
   {
     "http.proxy": "http://127.0.0.1:<ForwardPort>",
     "http.proxySupport": "override",
     "http.proxyStrictSSL": false,
     "http.useLocalProxyConfiguration": false,
     "claudeCode.environmentVariables": [
       { "name": "HTTP_PROXY", "value": "http://127.0.0.1:<ForwardPort>" },
       { "name": "HTTPS_PROXY", "value": "http://127.0.0.1:<ForwardPort>" },
       { "name": "NODE_TLS_REJECT_UNAUTHORIZED", "value": "0" },
       { "name": "HTTPPROXY", "value": "http://127.0.0.1:<ForwardPort>" },
       { "name": "HTTPSPROXY", "value": "http://127.0.0.1:<ForwardPort>" },
       { "name": "NODETLSREJECTUNAUTHORIZED", "value": "0" }
     ]
   }
   ```

3. 安装 Codex、Claude Code、Python 等默认 Remote SSH 扩展：

   ```text
   openai.chatgpt
   anthropic.claude-code
   ms-python.python
   ```

## 安装

克隆这个仓库，然后把 skill 文件夹复制到你的 Codex skills 目录：

```powershell
git clone https://github.com/fire-lit-band/vscode-remote-ssh-proxy-skill.git
Copy-Item `
  -Recurse `
  -Force `
  ".\vscode-remote-ssh-proxy-skill\vscode-remote-ssh-proxy" `
  "$env:USERPROFILE\.codex\skills\"
```

也可以在仓库根目录运行安装脚本：

```powershell
.\install.ps1
```

安装后重启 Codex，或者新开一个 Codex 对话。

## 用法

可以这样问 Codex：

```text
Use $vscode-remote-ssh-proxy to configure VS Code Remote SSH for host server.example.edu, user myuser.
```

Codex 会先让你确认 Clash/Mihomo 的本地代理端口。你可以在 Clash/Mihomo 信息里查看：

- 系统代理地址，例如 `127.0.0.1:7897`
- 混合代理端口，例如 `7897`

如果你的本地代理端口不是 `7897`，告诉 Codex 实际端口即可。

## 端口模型

`RemoteForward` 里有两个端口角色：

```sshconfig
RemoteForward <ForwardPort> 127.0.0.1:<LocalProxyPort>
```

- `ForwardPort`：远端服务器上打开的监听端口。远端 VS Code 会使用 `http://127.0.0.1:<ForwardPort>`。
- `LocalProxyPort`：你 Windows 本机 Clash/Mihomo 监听的端口。

最常见的情况是两边都用 `7897`：

```sshconfig
RemoteForward 7897 127.0.0.1:7897
```

如果 Clash/Mihomo 本机监听的是 `7890`，但你希望远端服务器仍然使用 `7897`：

```sshconfig
RemoteForward 7897 127.0.0.1:7890
```

脚本可以这样传参：

```powershell
-ForwardPort 7897 -LocalProxyPort 7890
```

## 手动运行脚本

通常由 Codex 调用脚本即可；你也可以手动运行：

```powershell
$env:CODEX_REMOTE_SSH_PASSWORD = "<temporary remote password>"
& "$env:USERPROFILE\.codex\skills\vscode-remote-ssh-proxy\scripts\setup-vscode-remote-ssh-proxy.ps1" `
  -HostName "server.example.edu" `
  -User "myuser" `
  -Alias "my-remote" `
  -LocalProxyPort 7897
Remove-Item Env:\CODEX_REMOTE_SSH_PASSWORD -ErrorAction SilentlyContinue
```

如果 SSH 已经可以免密登录，就不要设置 `CODEX_REMOTE_SSH_PASSWORD`。

## 安全说明

- 不要提交密码、私钥或真实服务器凭据。
- 密码只通过 `CODEX_REMOTE_SSH_PASSWORD` 临时使用。
- 脚本会向 `~/.ssh/config` 写入受管理的配置块；它不会故意覆盖非脚本管理的 Host 配置。
- 如果远端服务器禁止反向端口转发，SSH 连接本身可能仍然成功，但代理隧道不会生效。

## 仓库结构

```text
.
|-- README.md
|-- README.zh-CN.md
|-- LICENSE
|-- install.ps1
`-- vscode-remote-ssh-proxy/
    |-- SKILL.md
    |-- agents/openai.yaml
    `-- scripts/setup-vscode-remote-ssh-proxy.ps1
```

## 许可证

MIT
