[CmdletBinding()]
param(
    [string]$CodexSkillsDir = (Join-Path $env:USERPROFILE ".codex\skills")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$source = Join-Path $repoRoot "vscode-remote-ssh-proxy"
$target = Join-Path $CodexSkillsDir "vscode-remote-ssh-proxy"

if (-not (Test-Path -LiteralPath (Join-Path $source "SKILL.md"))) {
    throw "Could not find skill source at $source"
}

New-Item -ItemType Directory -Force -Path $CodexSkillsDir | Out-Null
Copy-Item -LiteralPath $source -Destination $CodexSkillsDir -Recurse -Force

Write-Host "Installed skill to: $target"
Write-Host "Restart Codex or open a new thread before using `$vscode-remote-ssh-proxy."
