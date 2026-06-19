---
name: vscode-remote-ssh-proxy
description: Configure VS Code Remote SSH hosts on Windows that need reverse proxy forwarding through a local Clash/Mihomo proxy. Use when the user provides a remote SSH hostname or IP, username, and password or key, and wants Codex to confirm the local proxy port, set up an SSH Host entry, RemoteForward to 127.0.0.1, key-based login, remote VS Code http.proxy/http.proxySupport/http.proxyStrictSSL/http.useLocalProxyConfiguration settings, Claude Code proxy environment variables, and default remote VS Code extensions for Linux/HPC servers.
---

# VS Code Remote SSH Proxy

## Overview

Use this skill to configure Windows VS Code Remote SSH connections for servers that should reach the user's local proxy through SSH reverse port forwarding. The standard setup is:

- Confirm the Clash/Mihomo local proxy port first. The usual port is `7897`, visible as either `127.0.0.1:7897` in the system proxy address or `7897` in the mixed proxy port.
- Local SSH config contains `RemoteForward <ForwardPort> 127.0.0.1:<LocalProxyPort>`.
- The remote VS Code server settings contain `"http.proxy": "http://127.0.0.1:<ForwardPort>"`, `"http.proxySupport": "override"`, `"http.proxyStrictSSL": false`, and `"http.useLocalProxyConfiguration": false`.
- The remote Claude Code settings contain proxy environment variables for `HTTP_PROXY`, `HTTPS_PROXY`, and `NO_PROXY=localhost,127.0.0.1`.
- `ForwardPort` and `LocalProxyPort` are different concepts: `ForwardPort` is the port opened on the remote server, and `LocalProxyPort` is the local Clash/Mihomo port on the user's Windows machine. They both default to `7897` for the common case.
- After key-based login works, the script tries to install remote VS Code extensions: `openai.chatgpt`, `anthropic.claude-code`, and `ms-python.python`.
- Passwords are only used transiently to install a public key and must never be written into config files, skill files, deliverables, or final responses.

## Inputs

Collect or infer:

- `HostName`: remote DNS name or IP.
- `User`: remote username.
- `Password`: optional, used only for first-time bootstrap.
- `Alias`: optional VS Code/SSH alias. If absent, generate a stable alias from `User` and `HostName`.
- `Port`: optional SSH port, default `22`.
- `ForwardPort`: remote listening port exposed on the SSH server, default `7897`. Keep this as `7897` unless the remote server already uses that port or the user asks for a different remote proxy port.
- `LocalProxyPort`: local Clash/Mihomo proxy port. Ask the user to confirm whether their Clash/Mihomo system proxy address or mixed proxy port is `7897`; if not, ask them to provide the actual port and pass it with `-LocalProxyPort`.
- `Extensions`: optional VS Code Marketplace extension IDs, default `openai.chatgpt`, `anthropic.claude-code`, and `ms-python.python`.

## Workflow

1. Ask the user to open Clash/Mihomo information and confirm the local proxy port. If the system proxy address is `127.0.0.1:7897` or the mixed proxy port is `7897`, use `7897`; otherwise ask the user to type the shown port number.
2. Use `scripts/setup-vscode-remote-ssh-proxy.ps1` from this skill directory on Windows.
3. If the user supplied a password, set it only in the current process as `CODEX_REMOTE_SSH_PASSWORD` before running the script, then remove it immediately after the script finishes.
4. Run the script with the host and user. Pass `-Alias` when the user wants a specific VS Code remote name, and pass `-LocalProxyPort <port>` when the confirmed Clash/Mihomo port is not `7897`. Pass `-ForwardPort <remote-port>` only when the remote listening port should differ from `7897`.
5. During remote bootstrap, ensure the remote VS Code Machine settings match the UI values: `Http: Proxy` is `http://127.0.0.1:<ForwardPort>`, `Http: Proxy Support` is `override`, `Http: Proxy Strict SSL` is unchecked (`false`), and `Http: Use Local Proxy Configuration` is unchecked (`false`).
6. Let the script try to install the default remote VS Code extensions after key-based login succeeds. Pass `-SkipExtensionInstall` only when the user does not want extension installation.
7. Verify the script reports a configured SSH host and successful key-based login.
8. Tell the user the alias to select in VS Code Remote SSH. Do not repeat their password.

Example command shape:

```powershell
$env:CODEX_REMOTE_SSH_PASSWORD = "<transient random password from user>"
& "$env:USERPROFILE\.codex\skills\vscode-remote-ssh-proxy\scripts\setup-vscode-remote-ssh-proxy.ps1" `
  -HostName "server-7f3a.example.invalid" `
  -User "user-4c9e2b" `
  -Alias "remote-7f3a"
Remove-Item Env:\CODEX_REMOTE_SSH_PASSWORD -ErrorAction SilentlyContinue
```

If passwordless SSH already works, omit the environment variable. If the local Clash/Mihomo proxy port is not `7897`, pass `-LocalProxyPort <port>`. If the remote listening port also needs to change, pass `-ForwardPort <remote-port>`. If the user wants a different extension list, pass `-Extensions @("publisher.extension", "publisher.other")`.

## What The Script Does

- Creates `~/.ssh` if needed.
- Generates a per-host Ed25519 key if one does not already exist.
- Updates `~/.ssh/config` with a managed block containing `HostName`, `User`, `Port`, `IdentityFile`, `IdentitiesOnly yes`, and `RemoteForward <ForwardPort> 127.0.0.1:<LocalProxyPort>`.
- Uses a transient askpass helper when `CODEX_REMOTE_SSH_PASSWORD` is set, so OpenSSH can install the public key without storing the password.
- Appends the public key to remote `~/.ssh/authorized_keys` if missing.
- Updates both `~/.vscode-server/data/Machine/settings.json` and `~/.vscode-server-insiders/data/Machine/settings.json` on the remote host with `"http.proxy": "http://127.0.0.1:<ForwardPort>"`, `"http.proxySupport": "override"`, `"http.proxyStrictSSL": false`, `"http.useLocalProxyConfiguration": false`, and Claude Code proxy environment variables.
- Uses the local VS Code CLI to try installing `openai.chatgpt`, `anthropic.claude-code`, and `ms-python.python` on the Remote SSH target. If `code` is unavailable or remote extension installation fails, it warns without failing the SSH/proxy setup.
- Tests that the resulting alias can authenticate with the key.

## Safety Notes

- Do not commit or save passwords. Use the password only inside the current shell environment and clear it after use.
- Do not overwrite unmanaged SSH config blocks. If an alias collision is reported, choose a new alias unless the user explicitly asks to replace the existing alias.
- If remote settings JSON is invalid and Python is available remotely, the script backs it up before rewriting a clean settings file. If no remote Python is available, it backs up existing settings before writing the two proxy settings.
- The remote server must allow SSH login and should allow `authorized_keys` key authentication for the final passwordless VS Code workflow.

## Troubleshooting

- If first-time login fails, confirm the hostname, username, port, and password, then rerun with a fresh password environment variable.
- If VS Code connects but remote extensions cannot download, confirm the user's local Clash/Mihomo proxy is listening on `127.0.0.1:<LocalProxyPort>` before starting the SSH session, and confirm the remote VS Code setting points at `http://127.0.0.1:<ForwardPort>`.
- If extension installation fails but SSH works, open VS Code Remote SSH for the alias and install the same Marketplace IDs from the Extensions view.
- If the remote rejects reverse forwarding, inspect server-side `AllowTcpForwarding` policy; the SSH alias can still work, but the remote proxy will not.
