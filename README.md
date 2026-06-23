# VS Code Remote SSH Proxy Skill

[English](README.md) | [中文](README.zh-CN.md)

A Codex skill for setting up VS Code Remote SSH on Windows when a remote Linux/HPC server needs to use your local Clash/Mihomo proxy through SSH reverse port forwarding.

The skill helps Codex configure:

- SSH config with `RemoteForward` and no explicit `Port 22` line
- Passwordless key-based SSH login
- Remote VS Code and Claude Code proxy settings
- Default remote VS Code extensions for Codex, Claude Code, and Python

## What It Does

The bundled skill focuses on three jobs:

1. Helps VS Code remember the SSH login by bootstrapping key-based authentication. It may use the remote password once to install a public key, but it does not store plaintext passwords.
2. Configures the remote server for Codex by writing the SSH `RemoteForward` rule and remote VS Code/Claude Code proxy settings:

   ```json
   {
     "http.proxy": "http://127.0.0.1:<ForwardPort>",
     "http.proxySupport": "override",
     "http.proxyStrictSSL": false,
     "http.useLocalProxyConfiguration": false,
     "claudeCode.environmentVariables": [
       { "name": "HTTP_PROXY", "value": "http://127.0.0.1:<ForwardPort>" },
       { "name": "HTTPS_PROXY", "value": "http://127.0.0.1:<ForwardPort>" },
       { "name": "NO_PROXY", "value": "localhost,127.0.0.1" }
     ]
   }
   ```

3. Installs the default Remote SSH extensions for Codex, Claude Code, and Python:

   ```text
   openai.chatgpt
   anthropic.claude-code
   ms-python.python
   ```

## Install

Clone this repository, then copy the skill folder into your Codex skills directory:

```powershell
git clone https://github.com/fire-lit-band/vscode-remote-ssh-proxy-skill.git
Copy-Item `
  -Recurse `
  -Force `
  ".\vscode-remote-ssh-proxy-skill\vscode-remote-ssh-proxy" `
  "$env:USERPROFILE\.codex\skills\"
```

Or run the included installer from the repository root:

```powershell
.\install.ps1
```

Restart Codex or open a new Codex thread after installation.

## Usage

Ask Codex something like:

```text
Use $vscode-remote-ssh-proxy to configure VS Code Remote SSH for host server.example.edu, user myuser.
```

Codex should ask you to confirm your Clash/Mihomo local proxy port first. In Clash/Mihomo, check either:

- System proxy address, such as `127.0.0.1:7897`
- Mixed proxy port, such as `7897`

If your local proxy port is not `7897`, tell Codex the actual port.

## Port Model

`RemoteForward` has two port roles:

```sshconfig
RemoteForward <ForwardPort> 127.0.0.1:<LocalProxyPort>
```

- `ForwardPort`: the port opened on the remote server. Remote VS Code uses `http://127.0.0.1:<ForwardPort>`.
- `LocalProxyPort`: the port where Clash/Mihomo listens on your Windows machine.

Common case:

```sshconfig
RemoteForward 7897 127.0.0.1:7897
```

If Clash/Mihomo listens locally on `7890`, but you still want the remote server to use `7897`:

```sshconfig
RemoteForward 7897 127.0.0.1:7890
```

The script supports that with:

```powershell
-ForwardPort 7897 -LocalProxyPort 7890
```

## Manual Script Usage

The skill normally drives the script for you, but you can also run it directly:

```powershell
$env:CODEX_REMOTE_SSH_PASSWORD = "<temporary remote password>"
& "$env:USERPROFILE\.codex\skills\vscode-remote-ssh-proxy\scripts\setup-vscode-remote-ssh-proxy.ps1" `
  -HostName "server.example.edu" `
  -User "myuser" `
  -Alias "my-remote" `
  -LocalProxyPort 7897
Remove-Item Env:\CODEX_REMOTE_SSH_PASSWORD -ErrorAction SilentlyContinue
```

If passwordless SSH already works, omit `CODEX_REMOTE_SSH_PASSWORD`.

## Security Notes

- Do not commit passwords, private keys, or real server credentials.
- Passwords are used only transiently through `CODEX_REMOTE_SSH_PASSWORD`.
- The script writes a managed block into `~/.ssh/config`; it does not intentionally overwrite unmanaged host blocks.
- If the remote server blocks reverse forwarding, SSH may still work, but the proxy tunnel will not.

## Repository Layout

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

## License

MIT
