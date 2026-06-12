# sync.ps1 - Claude Desktop session sidebar one-way sync (Windows)
#
# Claude Desktop scopes its Claude Code chat sidebar per signed-in account:
#   %APPDATA%\Claude\claude-code-sessions\<account-uuid>\<org-uuid>\local_*.json
# The underlying chat transcripts (~\.claude\projects) are shared across accounts,
# so making a chat visible to another account only requires copying its small
# sidebar index entry into that account's bucket.
#
# This script is ADDITIVE ONLY: it copies entries that are missing at the
# destination and never overwrites or deletes anything.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File sync.ps1          # interactive
#   powershell -ExecutionPolicy Bypass -File sync.ps1 -List    # just list accounts

param(
    [switch]$List
)

$ErrorActionPreference = 'Stop'

# Allow overriding the store location (e.g. portable installs). Otherwise try
# both the classic installer path and the packaged app path.
function Get-ClaudeUserDataCandidates {
    if ($env:CLAUDE_USER_DATA) {
        return @($env:CLAUDE_USER_DATA)
    }

    $candidates = @()
    if ($env:APPDATA) {
        $candidates += Join-Path $env:APPDATA 'Claude'
    }

    if ($env:LOCALAPPDATA) {
        $packagesRoot = Join-Path $env:LOCALAPPDATA 'Packages'
        if (Test-Path $packagesRoot) {
            foreach ($pkg in Get-ChildItem $packagesRoot -Directory -Filter 'Claude_*' -ErrorAction SilentlyContinue) {
                $candidates += Join-Path $pkg.FullName 'LocalCache\Roaming\Claude'
            }
        }
    }

    return @($candidates | Select-Object -Unique)
}

$UserDataCandidates = @(Get-ClaudeUserDataCandidates)
if ($UserDataCandidates.Count -eq 0) {
    $UserDataCandidates = @(Join-Path $HOME 'AppData\Roaming\Claude')
}

$UserData = $null
foreach ($candidate in $UserDataCandidates) {
    if (Test-Path (Join-Path $candidate 'claude-code-sessions')) {
        $UserData = $candidate
        break
    }
}
if (-not $UserData) {
    $UserData = $UserDataCandidates[0]
}
$StoreDir  = Join-Path $UserData 'claude-code-sessions'
$LogFile   = Join-Path $UserData 'logs\main.log'
$LabelFile = Join-Path $PSScriptRoot 'accounts.conf'

if (-not (Test-Path $StoreDir)) {
    Write-Host "Session store not found: $StoreDir" -ForegroundColor Red
    if ($UserDataCandidates.Count -gt 1) {
        Write-Host "Checked locations:"
        foreach ($candidate in $UserDataCandidates) {
            Write-Host "  - $(Join-Path $candidate 'claude-code-sessions')"
        }
    }
    Write-Host "Is Claude Desktop installed, and has Claude Code been used in it?"
    exit 1
}

# ---------------------------------------------------------------------------
# Friendly labels (saved per account/org bucket in accounts.conf)
# ---------------------------------------------------------------------------
$Labels = @{}
if (Test-Path $LabelFile) {
    foreach ($line in Get-Content $LabelFile -Encoding UTF8) {
        if ($line -match '^\s*([^=#][^=]*)=(.*)$') {
            $Labels[$Matches[1].Trim()] = $Matches[2].Trim()
        }
    }
}

function Save-Label([string]$key, [string]$value) {
    $script:Labels[$key] = $value
    $out = foreach ($k in ($script:Labels.Keys | Sort-Object)) { "$k=$($script:Labels[$k])" }
    Set-Content -Path $LabelFile -Value $out -Encoding UTF8
}

# ---------------------------------------------------------------------------
# Which account signed in most recently? (best identity signal on disk -
# the app does not store account emails in plaintext anywhere)
# ---------------------------------------------------------------------------
$LastSignedIn = $null
if (Test-Path $LogFile) {
    $idLines = @(Select-String -Path $LogFile -Pattern '\[account\] Identity changed' -ErrorAction SilentlyContinue)
    if ($idLines.Count -gt 0) {
        $uuidMatches = [regex]::Matches($idLines[-1].Line, '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}')
        if ($uuidMatches.Count -gt 0) {
            $LastSignedIn = $uuidMatches[$uuidMatches.Count - 1].Value
        }
    }
}

# ---------------------------------------------------------------------------
# Enumerate account buckets and fingerprint each one
# ---------------------------------------------------------------------------
$Buckets = @()
foreach ($accDir in Get-ChildItem $StoreDir -Directory) {
    foreach ($orgDir in Get-ChildItem $accDir.FullName -Directory) {
        $files = @(Get-ChildItem $orgDir.FullName -Filter 'local_*.json' -File | Sort-Object LastWriteTime -Descending)

        $titles = @()
        $projectCounts = @{}
        foreach ($f in $files) {
            try { $j = Get-Content $f.FullName -Raw | ConvertFrom-Json } catch { continue }
            if ($titles.Count -lt 3 -and $j.title) { $titles += $j.title }
            $proj = $null
            if ($j.originCwd) { $proj = Split-Path $j.originCwd -Leaf }
            elseif ($j.cwd)   { $proj = Split-Path $j.cwd -Leaf }
            if ($proj) {
                if ($projectCounts.ContainsKey($proj)) { $projectCounts[$proj]++ }
                else { $projectCounts[$proj] = 1 }
            }
        }
        $topProjects = @($projectCounts.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 3 | ForEach-Object { $_.Key })

        $lastActive = $null
        if ($files.Count -gt 0) { $lastActive = $files[0].LastWriteTime }

        $Buckets += [pscustomobject]@{
            Key         = "$($accDir.Name)/$($orgDir.Name)"
            Path        = $orgDir.FullName
            AccountUuid = $accDir.Name
            OrgUuid     = $orgDir.Name
            Count       = $files.Count
            LastActive  = $lastActive
            Titles      = $titles
            Projects    = $topProjects
        }
    }
}

if ($Buckets.Count -lt 2) {
    Write-Host "Found $($Buckets.Count) account bucket(s) in $StoreDir." -ForegroundColor Yellow
    Write-Host "Syncing needs at least two accounts that have used Claude Code in the desktop app."
    exit 1
}

# ---------------------------------------------------------------------------
# Show the accounts
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "Claude Desktop accounts on this machine" -ForegroundColor Cyan
Write-Host "(the app doesn't store emails on disk, so accounts are identified by their chats)" -ForegroundColor DarkGray

$i = 0
foreach ($b in $Buckets) {
    $i++
    if ($Labels.ContainsKey($b.Key)) {
        $header = "[$i] $($Labels[$b.Key])"
    } else {
        $header = "[$i] unnamed account ($($b.AccountUuid.Substring(0,8))...)"
    }
    if ($b.AccountUuid -eq $LastSignedIn) { $header += "   <- last signed in" }

    Write-Host ""
    Write-Host $header -ForegroundColor White
    if ($b.LastActive) {
        Write-Host ("    {0} chats | last active {1:yyyy-MM-dd HH:mm}" -f $b.Count, $b.LastActive)
    } else {
        Write-Host ("    {0} chats" -f $b.Count)
    }
    if ($b.Projects.Count -gt 0) {
        Write-Host ("    projects: {0}" -f ($b.Projects -join ', '))
    }
    foreach ($t in $b.Titles) {
        Write-Host ("      - {0}" -f $t) -ForegroundColor DarkGray
    }
}
Write-Host ""

if ($List) { exit 0 }

# ---------------------------------------------------------------------------
# Offer to name unnamed accounts (saved to accounts.conf for next time)
# ---------------------------------------------------------------------------
$i = 0
foreach ($b in $Buckets) {
    $i++
    if (-not $Labels.ContainsKey($b.Key)) {
        $name = Read-Host "Name for account [$i] (e.g. 'zerospace dev', Enter to skip)"
        if ($name) { Save-Label $b.Key $name }
    }
}

function Get-BucketDisplayName([object]$b) {
    if ($script:Labels.ContainsKey($b.Key)) { return $script:Labels[$b.Key] }
    return "account $($b.AccountUuid.Substring(0,8))..."
}

# ---------------------------------------------------------------------------
# Pick source and destination
# ---------------------------------------------------------------------------
function Select-Bucket([string]$promptText, [int]$exclude) {
    while ($true) {
        $raw = Read-Host $promptText
        $n = 0
        if ([int]::TryParse($raw, [ref]$n) -and $n -ge 1 -and $n -le $script:Buckets.Count -and $n -ne $exclude) {
            return $n
        }
        Write-Host "Enter a number from 1 to $($script:Buckets.Count)$(if ($exclude -gt 0) { " (other than $exclude)" })." -ForegroundColor Yellow
    }
}

$srcIdx = Select-Bucket "Copy chats FROM account #" 0
$dstIdx = Select-Bucket "Copy chats TO account #" $srcIdx
$src = $Buckets[$srcIdx - 1]
$dst = $Buckets[$dstIdx - 1]

# ---------------------------------------------------------------------------
# Plan and confirm
# ---------------------------------------------------------------------------
$srcFiles = @(Get-ChildItem $src.Path -Filter 'local_*.json' -File)
$toCopy = @($srcFiles | Where-Object { -not (Test-Path (Join-Path $dst.Path $_.Name)) })

Write-Host ""
Write-Host ("{0} chats at source; {1} already present at destination; {2} to copy." -f `
    $srcFiles.Count, ($srcFiles.Count - $toCopy.Count), $toCopy.Count)

if ($toCopy.Count -eq 0) {
    Write-Host "Nothing to do - '$(Get-BucketDisplayName $dst)' is already up to date." -ForegroundColor Green
    exit 0
}

$claudeProc = Get-Process -Name 'Claude' -ErrorAction SilentlyContinue
if ($claudeProc) {
    Write-Host "Note: Claude Desktop is running. Copying is safe, but the sidebar only" -ForegroundColor Yellow
    Write-Host "re-reads this folder on account switch or app restart." -ForegroundColor Yellow
}

$confirm = Read-Host "Copy $($toCopy.Count) chat(s) from '$(Get-BucketDisplayName $src)' to '$(Get-BucketDisplayName $dst)'? [y/N]"
if ($confirm -notmatch '^[yY]') {
    Write-Host "Aborted - nothing was copied."
    exit 0
}

# ---------------------------------------------------------------------------
# Copy (additive: only files missing at the destination)
# ---------------------------------------------------------------------------
$copied = 0
foreach ($f in $toCopy) {
    $title = $f.BaseName
    try {
        $j = Get-Content $f.FullName -Raw | ConvertFrom-Json
        if ($j.title) { $title = $j.title }
    } catch { }
    Copy-Item $f.FullName (Join-Path $dst.Path $f.Name)
    $copied++
    Write-Host ("  + {0}" -f $title) -ForegroundColor Green
}

Write-Host ""
Write-Host "Copied $copied chat(s). Switch to that account (or restart Claude Desktop) to see them." -ForegroundColor Green
Write-Host "Tip: archive synced chats you don't want instead of deleting them -"
Write-Host "deleted ones reappear on the next sync, archived ones stay hidden."
