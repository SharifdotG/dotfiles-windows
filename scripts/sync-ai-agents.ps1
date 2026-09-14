<#
.SYNOPSIS
    Synchronizes MCP servers and custom skills between Claude Code and Google Antigravity.

.DESCRIPTION
    Claude Code and Antigravity store their configurations in different places and schemas:
      - Skills store:      ~\.agents\skills
      - Claude skills:     ~\.claude\skills            (junctions into store)
      - Antigravity skills: ~\.gemini\config\skills     (junctions into store)
                           ~\.gemini\config\skills.json (explicit entry)
      - Claude MCP:        ~\.claude.json              (mcpServers map)
      - Antigravity MCP:   ~\.gemini\config\mcp_config.json (serverUrl + headers + stdio)

    This script ensures any MCP servers or skills configured in either Claude Code or the
    agent store are available and working in both environments on Windows.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Info($msg) { Write-Host "[-] $msg" -ForegroundColor Cyan }
function Write-Success($msg) { Write-Host "[+] $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "[!] $msg" -ForegroundColor Yellow }

$claudeConfig = Join-Path $HOME '.claude.json'
$geminiConfigDir = Join-Path $HOME '.gemini\config'
$geminiMcpConfig = Join-Path $geminiConfigDir 'mcp_config.json'
$geminiSkillsJson = Join-Path $geminiConfigDir 'skills.json'
$geminiSkillsDir = Join-Path $geminiConfigDir 'skills'
$claudeSkillsDir = Join-Path $HOME '.claude\skills'
$skillsStore = Join-Path $HOME '.agents\skills'

# Ensure directories exist
foreach ($dir in $geminiConfigDir, $geminiSkillsDir, $claudeSkillsDir, $skillsStore) {
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
}

# -----------------------------------------------------------------------------
# 1. Sync MCP Servers: Claude Code -> Antigravity
# -----------------------------------------------------------------------------
Write-Info "Checking MCP servers in $claudeConfig..."
if (Test-Path -LiteralPath $claudeConfig) {
    try {
        $claudeJson = Get-Content -LiteralPath $claudeConfig -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    } catch {
        Write-Warn "Failed to parse $claudeConfig as JSON: $_"
        $claudeJson = $null
    }

    if ($claudeJson -and $claudeJson.Contains('mcpServers')) {
        $existingGemini = [ordered]@{}
        if (Test-Path -LiteralPath $geminiMcpConfig) {
            try {
                $rawGemini = Get-Content -LiteralPath $geminiMcpConfig -Raw -Encoding utf8
                if ($rawGemini.Trim()) {
                    $parsed = $rawGemini | ConvertFrom-Json -AsHashtable
                    if ($parsed.Contains('mcpServers')) {
                        $existingGemini = $parsed.mcpServers
                    }
                }
            } catch {
                Write-Warn "Could not read existing $geminiMcpConfig, starting fresh: $_"
            }
        }

        $mergedMcp = [ordered]@{}
        $added = 0
        $updated = 0

        # Copy existing gemini servers first
        foreach ($k in $existingGemini.Keys) {
            $mergedMcp[$k] = $existingGemini[$k]
        }

        # Import and translate from Claude Code
        foreach ($name in $claudeJson.mcpServers.Keys) {
            $src = $claudeJson.mcpServers[$name]
            $entry = [ordered]@{}

            # Determine transport: HTTP/SSE vs Stdio
            if ($src.Contains('url') -or $src.Contains('serverUrl') -or ($src.Contains('type') -and $src.type -eq 'http')) {
                $url = if ($src.Contains('serverUrl')) { $src.serverUrl } else { $src.url }
                $entry['type'] = 'http'
                $entry['serverUrl'] = $url
                $entry['url'] = $url
                if ($src.Contains('headers') -and $src.headers) {
                    $entry['headers'] = $src.headers
                }
            } else {
                # Stdio transport
                $entry['type'] = 'stdio'
                $cmd = "$($src.command)"
                $args = if ($src.Contains('args')) { @($src.args) } else { @() }

                # On Windows, wrap npx/npm/pnpm/yarn in cmd /c
                if ($cmd -in 'npx', 'npm', 'pnpm', 'yarn') {
                    $args = @('/c', $cmd) + $args
                    $cmd = 'cmd'
                }
                $entry['command'] = $cmd
                $entry['args'] = $args
                $entry['env'] = if ($src.Contains('env') -and $src.env) { $src.env } else { @{} }
            }

            if (-not $mergedMcp.Contains($name)) {
                $added++
            } else {
                $updated++
            }
            $mergedMcp[$name] = $entry
        }

        $output = [ordered]@{ mcpServers = $mergedMcp }
        $jsonOut = ConvertTo-Json -InputObject $output -Depth 20
        Set-Content -LiteralPath $geminiMcpConfig -Value $jsonOut -Encoding utf8NoBOM
        Write-Success "Antigravity MCP config updated ($geminiMcpConfig): $($mergedMcp.Count) server(s) active ($added new, $updated refreshed)."
    } else {
        Write-Warn "No mcpServers block found in $claudeConfig."
    }
} else {
    Write-Warn "Claude config $claudeConfig not found."
}

# -----------------------------------------------------------------------------
# 2. Sync Skills: Store -> Claude + Antigravity
# -----------------------------------------------------------------------------
Write-Info "Checking skills in store ($skillsStore)..."
$skills = Get-ChildItem -LiteralPath $skillsStore -Directory -ErrorAction Ignore

# Register skills.json for Antigravity
$resolvedStore = (Resolve-Path $skillsStore).Path.Replace('\', '/')
$skillsJsonObj = [ordered]@{
    entries = @(
        [ordered]@{ path = $resolvedStore }
    )
}
ConvertTo-Json -InputObject $skillsJsonObj -Depth 5 | Set-Content -LiteralPath $geminiSkillsJson -Encoding utf8NoBOM
Write-Success "Antigravity skills.json updated ($geminiSkillsJson)."

# Link each skill into both environments
$claudeLinked = 0; $claudeKept = 0
$geminiLinked = 0; $geminiKept = 0

foreach ($skill in $skills) {
    # Check for SKILL.md
    $skillMd = Join-Path $skill.FullName 'SKILL.md'
    if (-not (Test-Path -LiteralPath $skillMd)) {
        continue
    }

    # Link to Claude
    $cLink = Join-Path $claudeSkillsDir $skill.Name
    if (Test-Path -LiteralPath $cLink) {
        $claudeKept++
    } else {
        New-Item -ItemType Junction -Path $cLink -Target $skill.FullName | Out-Null
        $claudeLinked++
    }

    # Link to Antigravity
    $gLink = Join-Path $geminiSkillsDir $skill.Name
    if (Test-Path -LiteralPath $gLink) {
        $geminiKept++
    } else {
        New-Item -ItemType Junction -Path $gLink -Target $skill.FullName | Out-Null
        $geminiLinked++
    }
}

Write-Success "Claude skills ($claudeSkillsDir): $claudeLinked linked, $claudeKept already present."
Write-Success "Antigravity skills ($geminiSkillsDir): $geminiLinked linked, $geminiKept already present."
Write-Success "Sync complete! Both Claude Code and Antigravity are synchronized."
