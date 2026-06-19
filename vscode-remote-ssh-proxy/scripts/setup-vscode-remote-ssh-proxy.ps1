[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$HostName,

    [Parameter(Mandatory = $true)]
    [string]$User,

    [string]$Alias,
    [int]$Port = 22,
    [Alias("RemoteForwardPort")]
    [int]$ForwardPort = 7897,
    [string]$LocalProxyHost = "127.0.0.1",
    [int]$LocalProxyPort = 0,
    [string]$ProxyUrl,
    [string]$KeyPath,
    [string]$PasswordEnvVar = "CODEX_REMOTE_SSH_PASSWORD",
    [string[]]$Extensions = @("openai.chatgpt", "anthropic.claude-code", "ms-python.python"),
    [switch]$SkipRemoteBootstrap,
    [switch]$SkipExtensionInstall,
    [switch]$OpenInVSCode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function ConvertTo-SafeToken {
    param([Parameter(Mandatory = $true)][string]$Value)
    $safe = $Value -replace '[^A-Za-z0-9._-]+', '-'
    $safe = $safe.Trim('-')
    if ([string]::IsNullOrWhiteSpace($safe)) {
        return "remote"
    }
    return $safe
}

function Resolve-HomePath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ($Path -eq "~") {
        return $HOME
    }
    if ($Path.StartsWith("~/") -or $Path.StartsWith("~\")) {
        return (Join-Path $HOME $Path.Substring(2))
    }
    return $Path
}

function ConvertTo-SshConfigPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $full = [System.IO.Path]::GetFullPath((Resolve-HomePath $Path))
    $sshDirFull = [System.IO.Path]::GetFullPath((Join-Path $HOME ".ssh"))
    if ($full.StartsWith($sshDirFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        return "~/.ssh/" + (Split-Path -Leaf $full)
    }
    return ($full -replace '\\', '/')
}

function ConvertTo-ShSingleQuoted {
    param([Parameter(Mandatory = $true)][string]$Value)
    $singleQuote = [char]39
    $doubleQuote = [char]34
    return $singleQuote + $Value.Replace("$singleQuote", "$singleQuote$doubleQuote$singleQuote$doubleQuote$singleQuote") + $singleQuote
}

function Set-PrivateKeyPermissions {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ($env:OS -ne "Windows_NT") {
        return
    }
    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        & icacls $Path /inheritance:r /grant:r "${identity}:F" | Out-Null
    }
    catch {
        Write-Warning "Could not tighten private-key ACLs automatically: $($_.Exception.Message)"
    }
}

function Test-LocalProxyPort {
    param(
        [Parameter(Mandatory = $true)][string]$HostValue,
        [Parameter(Mandatory = $true)][int]$PortValue
    )
    try {
        $client = [System.Net.Sockets.TcpClient]::new()
        $async = $client.BeginConnect($HostValue, $PortValue, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne(700)) {
            Write-Warning "Local proxy $HostValue`:$PortValue did not accept a quick connection. Start the proxy before using VS Code Remote SSH."
            return
        }
        $client.EndConnect($async)
        $client.Close()
    }
    catch {
        Write-Warning "Local proxy $HostValue`:$PortValue is not reachable right now. Start the proxy before using VS Code Remote SSH."
    }
}

function Update-SshConfig {
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Parameter(Mandatory = $true)][string]$AliasValue,
        [Parameter(Mandatory = $true)][string]$IdentityFile
    )

    $configDir = Split-Path -Parent $ConfigPath
    New-Item -ItemType Directory -Force -Path $configDir | Out-Null

    $configText = ""
    if (Test-Path -LiteralPath $ConfigPath) {
        $configText = Get-Content -Raw -LiteralPath $ConfigPath
    }

    $start = "# >>> codex-vscode-remote-ssh-proxy: $AliasValue"
    $end = "# <<< codex-vscode-remote-ssh-proxy: $AliasValue"
    $pattern = "(?ms)^" + [regex]::Escape($start) + "\r?\n.*?^" + [regex]::Escape($end) + "\r?\n?"
    $configText = [regex]::Replace($configText, $pattern, "")

    $unmanagedHostPattern = "(?im)^\s*Host\s+" + [regex]::Escape($AliasValue) + "\s*$"
    if ($configText -match $unmanagedHostPattern) {
        Write-Warning "An unmanaged Host '$AliasValue' already exists in $ConfigPath. Prefer a different alias unless the user asked to keep this name."
    }

    $block = @"
$start
Host $AliasValue
    HostName $HostName
    User $User
    Port $Port
    IdentityFile $IdentityFile
    IdentitiesOnly yes
    RemoteForward $ForwardPort ${LocalProxyHost}:$LocalProxyPort
    ServerAliveInterval 60
    ServerAliveCountMax 3
$end
"@

    $newText = $configText.TrimEnd()
    if ($newText.Length -gt 0) {
        $newText += [Environment]::NewLine + [Environment]::NewLine
    }
    $newText += $block + [Environment]::NewLine
    Set-Content -LiteralPath $ConfigPath -Value $newText -Encoding ASCII
}

function New-RemoteBootstrapScript {
    param(
        [Parameter(Mandatory = $true)][string]$PublicKey,
        [Parameter(Mandatory = $true)][string]$RemoteProxyUrl
    )

    $template = @'
set -eu

PUBKEY=__PUBKEY__
PROXY_URL=__PROXY_URL__

umask 077
mkdir -p "$HOME/.ssh"
touch "$HOME/.ssh/authorized_keys"
if ! grep -qxF "$PUBKEY" "$HOME/.ssh/authorized_keys" 2>/dev/null; then
  printf '%s\n' "$PUBKEY" >> "$HOME/.ssh/authorized_keys"
fi
chmod 700 "$HOME/.ssh"
chmod 600 "$HOME/.ssh/authorized_keys"

update_settings() {
  dir="$1"
  mkdir -p "$dir"
  file="$dir/settings.json"
  py=""
  if command -v python3 >/dev/null 2>&1; then
    py=python3
  elif command -v python >/dev/null 2>&1; then
    py=python
  fi

  if [ -n "$py" ]; then
    SETTINGS_PATH="$file" PROXY_URL="$PROXY_URL" "$py" - <<'PY'
import json
import os
import shutil
import time

path = os.environ["SETTINGS_PATH"]
proxy_url = os.environ["PROXY_URL"]
data = {}

if os.path.exists(path):
    try:
        with open(path, "r") as handle:
            raw = handle.read().strip()
        if raw:
            parsed = json.loads(raw)
            if isinstance(parsed, dict):
                data = parsed
    except Exception:
        backup = path + ".bak.codex-" + time.strftime("%Y%m%d%H%M%S")
        shutil.copy2(path, backup)
        data = {}

data["http.proxy"] = proxy_url
data["http.proxySupport"] = "override"
data["http.proxyStrictSSL"] = False
data["http.useLocalProxyConfiguration"] = False
data["claudeCode.environmentVariables"] = [
    {"name": "HTTP_PROXY", "value": proxy_url},
    {"name": "HTTPS_PROXY", "value": proxy_url},
    {"name": "NODE_TLS_REJECT_UNAUTHORIZED", "value": "0"},
    {"name": "HTTPPROXY", "value": proxy_url},
    {"name": "HTTPSPROXY", "value": proxy_url},
    {"name": "NODETLSREJECTUNAUTHORIZED", "value": "0"},
]

with open(path, "w") as handle:
    json.dump(data, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
  else
    if [ -f "$file" ]; then
      cp "$file" "$file.bak.codex-$(date +%Y%m%d%H%M%S)"
    fi
    cat > "$file" <<EOF
{
  "http.proxy": "$PROXY_URL",
  "http.proxySupport": "override",
  "http.proxyStrictSSL": false,
  "http.useLocalProxyConfiguration": false,
  "claudeCode.environmentVariables": [
    { "name": "HTTP_PROXY", "value": "$PROXY_URL" },
    { "name": "HTTPS_PROXY", "value": "$PROXY_URL" },
    { "name": "NODE_TLS_REJECT_UNAUTHORIZED", "value": "0" },
    { "name": "HTTPPROXY", "value": "$PROXY_URL" },
    { "name": "HTTPSPROXY", "value": "$PROXY_URL" },
    { "name": "NODETLSREJECTUNAUTHORIZED", "value": "0" }
  ]
}
EOF
  fi
}

update_settings "$HOME/.vscode-server/data/Machine"
update_settings "$HOME/.vscode-server-insiders/data/Machine"
printf 'remote-bootstrap-ok\n'
'@

    return $template.
        Replace("__PUBKEY__", (ConvertTo-ShSingleQuoted $PublicKey)).
        Replace("__PROXY_URL__", (ConvertTo-ShSingleQuoted $RemoteProxyUrl))
}

function Invoke-OpenSsh {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [string]$InputText,
        [string]$Password
    )

    $ssh = (Get-Command ssh -ErrorAction Stop).Source
    $envNames = @("SSH_ASKPASS", "SSH_ASKPASS_REQUIRE", "DISPLAY", $PasswordEnvVar)
    $oldEnv = @{}
    foreach ($name in $envNames) {
        $oldEnv[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
    }

    $tempDir = $null
    try {
        if (-not [string]::IsNullOrEmpty($Password)) {
            $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-ssh-askpass-" + [guid]::NewGuid().ToString("N"))
            New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
            $askpassCmd = Join-Path $tempDir "askpass.cmd"
            $askpassPs1 = Join-Path $tempDir "askpass.ps1"

            $askpassCmdText = "@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -File ""%~dp0askpass.ps1""`r`n"
            Set-Content -LiteralPath $askpassCmd -Value $askpassCmdText -Encoding ASCII

            $askpassPs1Text = @"
`$value = [Environment]::GetEnvironmentVariable('$PasswordEnvVar', 'Process')
[Console]::Out.Write(`$value)
"@
            Set-Content -LiteralPath $askpassPs1 -Value $askpassPs1Text -Encoding ASCII

            [Environment]::SetEnvironmentVariable($PasswordEnvVar, $Password, "Process")
            [Environment]::SetEnvironmentVariable("SSH_ASKPASS", $askpassCmd, "Process")
            [Environment]::SetEnvironmentVariable("SSH_ASKPASS_REQUIRE", "force", "Process")
            [Environment]::SetEnvironmentVariable("DISPLAY", "localhost:0", "Process")
        }

        if ($PSBoundParameters.ContainsKey("InputText")) {
            $InputText | & $ssh @Arguments
        }
        else {
            & $ssh @Arguments
        }

        if ($LASTEXITCODE -ne 0) {
            throw "ssh exited with code $LASTEXITCODE"
        }
    }
    finally {
        foreach ($name in $envNames) {
            [Environment]::SetEnvironmentVariable($name, $oldEnv[$name], "Process")
        }
        if ($tempDir -and (Test-Path -LiteralPath $tempDir)) {
            Remove-Item -LiteralPath $tempDir -Recurse -Force
        }
    }
}

function Install-VSCodeRemoteExtensions {
    param(
        [Parameter(Mandatory = $true)][string]$AliasValue,
        [string[]]$ExtensionIds
    )

    if (-not $ExtensionIds -or $ExtensionIds.Count -eq 0) {
        return
    }

    $code = Get-Command code -ErrorAction SilentlyContinue
    if (-not $code) {
        Write-Warning "VS Code CLI 'code' was not found on PATH. Skipping remote extension install."
        return
    }

    $uniqueExtensions = @()
    foreach ($extension in $ExtensionIds) {
        if ([string]::IsNullOrWhiteSpace($extension)) {
            continue
        }
        $extension = $extension.Trim()
        if ($uniqueExtensions -notcontains $extension) {
            $uniqueExtensions += $extension
        }
    }

    foreach ($extension in $uniqueExtensions) {
        Write-Host "Installing VS Code extension on ${AliasValue}: $extension"
        & $code.Source --remote "ssh-remote+$AliasValue" --install-extension $extension --force
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Could not install VS Code extension '$extension' on remote '$AliasValue'. Install it manually from the VS Code Extensions view if needed."
        }
    }
}

if (-not $Alias) {
    $Alias = ConvertTo-SafeToken "$User-$HostName"
}

if ($LocalProxyPort -le 0) {
    $LocalProxyPort = $ForwardPort
}

if (-not $ProxyUrl) {
    $ProxyUrl = "http://127.0.0.1:$ForwardPort"
}

$sshDir = Join-Path $HOME ".ssh"
New-Item -ItemType Directory -Force -Path $sshDir | Out-Null

if (-not $KeyPath) {
    $keyName = "codex_" + (ConvertTo-SafeToken $Alias) + "_ed25519"
    $KeyPath = Join-Path $sshDir $keyName
}
$KeyPath = [System.IO.Path]::GetFullPath((Resolve-HomePath $KeyPath))
$publicKeyPath = "$KeyPath.pub"

if (-not (Test-Path -LiteralPath $KeyPath)) {
    $keyComment = ConvertTo-SafeToken "$User@$HostName"
    $keygenCommand = 'ssh-keygen -t ed25519 -f "' + $KeyPath + '" -N "" -C "' + $keyComment + '"'
    & cmd.exe /d /c $keygenCommand | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "ssh-keygen failed with code $LASTEXITCODE"
    }
    Set-PrivateKeyPermissions -Path $KeyPath
}

if (-not (Test-Path -LiteralPath $publicKeyPath)) {
    & ssh-keygen -y -f $KeyPath | Set-Content -LiteralPath $publicKeyPath -Encoding ASCII
    if ($LASTEXITCODE -ne 0) {
        throw "Could not derive public key from $KeyPath"
    }
}

$publicKey = (Get-Content -Raw -LiteralPath $publicKeyPath).Trim()
$identityFile = ConvertTo-SshConfigPath $KeyPath
$configPath = Join-Path $sshDir "config"

Update-SshConfig -ConfigPath $configPath -AliasValue $Alias -IdentityFile $identityFile
Test-LocalProxyPort -HostValue $LocalProxyHost -PortValue $LocalProxyPort

$password = [Environment]::GetEnvironmentVariable($PasswordEnvVar, "Process")

if (-not $SkipRemoteBootstrap) {
    $remoteScript = New-RemoteBootstrapScript -PublicKey $publicKey -RemoteProxyUrl $ProxyUrl
    $sshArgs = @(
        "-p", [string]$Port,
        "-i", $KeyPath,
        "-o", "IdentitiesOnly=yes",
        "-o", "PreferredAuthentications=publickey,password,keyboard-interactive",
        "-o", "StrictHostKeyChecking=accept-new",
        "-T",
        "$User@$HostName",
        "sh -s"
    )
    Invoke-OpenSsh -Arguments $sshArgs -InputText $remoteScript -Password $password

    & ssh -o BatchMode=yes $Alias "printf 'codex-ssh-ok\n'"
    if ($LASTEXITCODE -ne 0) {
        throw "The SSH alias was written, but key-based verification failed for '$Alias'."
    }

    if (-not $SkipExtensionInstall) {
        Install-VSCodeRemoteExtensions -AliasValue $Alias -ExtensionIds $Extensions
    }
}

if ($OpenInVSCode) {
    $code = Get-Command code -ErrorAction SilentlyContinue
    if ($code) {
        & $code.Source --remote "ssh-remote+$Alias"
    }
    else {
        Write-Warning "VS Code CLI 'code' was not found on PATH."
    }
}

Write-Host "Configured SSH host: $Alias"
Write-Host "SSH config: $configPath"
Write-Host "Identity file: $KeyPath"
Write-Host "Local proxy: ${LocalProxyHost}:$LocalProxyPort"
Write-Host "SSH remote forward: 127.0.0.1:$ForwardPort -> ${LocalProxyHost}:$LocalProxyPort"
Write-Host "Remote VS Code proxy: $ProxyUrl"
Write-Host "VS Code Remote SSH target: $Alias"
