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
# known install paths, then do a bounded search under app-data roots.
function Add-UniquePath([System.Collections.ArrayList]$paths, [string]$path) {
    if ($path -and -not $paths.Contains($path)) {
        [void]$paths.Add($path)
    }
}

function Get-KnownClaudeUserDataCandidates {
    $candidates = [System.Collections.ArrayList]@()

    if ($env:APPDATA) {
        Add-UniquePath $candidates (Join-Path $env:APPDATA 'Claude')
    }

    if ($env:LOCALAPPDATA) {
        Add-UniquePath $candidates (Join-Path $env:LOCALAPPDATA 'Claude')

        $packagesRoot = Join-Path $env:LOCALAPPDATA 'Packages'
        if (Test-Path $packagesRoot) {
            foreach ($pkg in Get-ChildItem $packagesRoot -Directory -Filter 'Claude_*' -ErrorAction SilentlyContinue) {
                Add-UniquePath $candidates (Join-Path $pkg.FullName 'LocalCache\Roaming\Claude')
            }
        }
    }

    return @($candidates)
}

function Find-ClaudeUserDataCandidates {
    $candidates = [System.Collections.ArrayList]@()
    $searchRoots = @()

    if ($env:APPDATA -and (Test-Path $env:APPDATA)) {
        $searchRoots += [pscustomobject]@{ Path = $env:APPDATA; Depth = 4 }
    }
    if ($env:LOCALAPPDATA) {
        $localClaude = Join-Path $env:LOCALAPPDATA 'Claude'
        if (Test-Path $localClaude) {
            $searchRoots += [pscustomobject]@{ Path = $localClaude; Depth = 4 }
        }

        $packagesRoot = Join-Path $env:LOCALAPPDATA 'Packages'
        if (Test-Path $packagesRoot) {
            $searchRoots += [pscustomobject]@{ Path = $packagesRoot; Depth = 5 }
        }
    }

    foreach ($root in $searchRoots) {
        try {
            foreach ($store in Get-ChildItem $root.Path -Directory -Filter 'claude-code-sessions' -Recurse -Depth $root.Depth -ErrorAction SilentlyContinue) {
                Add-UniquePath $candidates (Split-Path $store.FullName -Parent)
            }
        } catch {
            continue
        }
    }

    return @($candidates)
}

function Get-ClaudeSessionStoreInfo([string]$userData) {
    $storeDir = Join-Path $userData 'claude-code-sessions'
    $bucketCount = 0
    $chatCount = 0
    $lastActive = $null
    $uuidPattern = '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

    if (Test-Path $storeDir) {
        foreach ($accDir in Get-ChildItem $storeDir -Directory -ErrorAction SilentlyContinue) {
            if ($accDir.Name -notmatch $uuidPattern) { continue }
            foreach ($orgDir in Get-ChildItem $accDir.FullName -Directory -ErrorAction SilentlyContinue) {
                if ($orgDir.Name -notmatch $uuidPattern) { continue }
                $files = @(Get-ChildItem $orgDir.FullName -File -Filter 'local_*.json' -ErrorAction SilentlyContinue)
                if ($files.Count -gt 0) {
                    $bucketCount++
                    $chatCount += $files.Count
                    $newest = @($files | Sort-Object LastWriteTime -Descending | Select-Object -First 1)[0]
                    if ($newest -and (-not $lastActive -or $newest.LastWriteTime -gt $lastActive)) {
                        $lastActive = $newest.LastWriteTime
                    }
                }
            }
        }
    }

    [pscustomobject]@{
        UserData    = $userData
        StoreDir    = $storeDir
        Exists      = Test-Path $storeDir
        BucketCount = $bucketCount
        ChatCount   = $chatCount
        LastActive  = $lastActive
        IsValid     = $bucketCount -gt 0
    }
}

function Get-ClaudeUserDataCandidates {
    if ($env:CLAUDE_USER_DATA) {
        return @($env:CLAUDE_USER_DATA)
    }

    $candidates = [System.Collections.ArrayList]@()
    foreach ($candidate in Get-KnownClaudeUserDataCandidates) {
        Add-UniquePath $candidates $candidate
    }
    foreach ($candidate in Find-ClaudeUserDataCandidates) {
        Add-UniquePath $candidates $candidate
    }

    return @($candidates)
}

$UserDataCandidates = @(Get-ClaudeUserDataCandidates)
if ($UserDataCandidates.Count -eq 0) {
    $UserDataCandidates = @(Join-Path $HOME 'AppData\Roaming\Claude')
}

$StoreMatches = @($UserDataCandidates | ForEach-Object { Get-ClaudeSessionStoreInfo $_ })
$ValidStores = @($StoreMatches | Where-Object { $_.IsValid } | Sort-Object ChatCount, BucketCount, LastActive -Descending)
$UserData = if ($ValidStores.Count -gt 0) { $ValidStores[0].UserData } else { $UserDataCandidates[0] }
$StoreDir  = Join-Path $UserData 'claude-code-sessions'
$LogFile   = Join-Path $UserData 'logs\main.log'
$LabelFile = Join-Path $PSScriptRoot 'accounts.conf'

if (-not (Test-Path $StoreDir)) {
    Write-Host "Session store not found: $StoreDir" -ForegroundColor Red
    Write-Host "Checked locations:"
    foreach ($match in $StoreMatches) {
        Write-Host "  - $($match.StoreDir)"
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

function Get-BucketDisplayName([object]$b) {
    if ($script:Labels.ContainsKey($b.AccountUuid)) { return $script:Labels[$b.AccountUuid] }
    if ($script:Labels.ContainsKey($b.Key)) { return $script:Labels[$b.Key] }
    return "account $($b.AccountUuid.Substring(0,8))..."
}

function Get-BucketLabel([object]$b) {
    if ($script:Labels.ContainsKey($b.AccountUuid)) { return $script:Labels[$b.AccountUuid] }
    if ($script:Labels.ContainsKey($b.Key)) { return $script:Labels[$b.Key] }
    return $null
}

function Write-BucketList {
    Write-Host ""
    Write-Host "Claude Desktop accounts on this machine" -ForegroundColor Cyan
    Write-Host "(the app doesn't store emails on disk, so accounts are identified by their chats)" -ForegroundColor DarkGray

    $i = 0
    foreach ($b in $script:Buckets) {
        $i++
        $label = Get-BucketLabel $b
        if ($label) {
            $header = "[$i] $label ($($b.AccountUuid.Substring(0,8))...)"
        } else {
            $header = "[$i] unnamed account ($($b.AccountUuid.Substring(0,8))...)"
        }
        if ($b.AccountUuid -eq $script:LastSignedIn) { $header += "   <- last signed in" }

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
}

# ---------------------------------------------------------------------------
# Show and optionally name the accounts
# ---------------------------------------------------------------------------
Write-BucketList

if ($List) { exit 0 }

$labelsChanged = $false
$i = 0
foreach ($b in $Buckets) {
    $i++
    if (-not (Get-BucketLabel $b)) {
        $name = Read-Host "Name for account [$i] (e.g. 'work', Enter to skip)"
        if ($name) {
            Save-Label $b.AccountUuid $name
            $labelsChanged = $true
        }
    }
}

if ($labelsChanged) {
    Write-BucketList
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

function Select-BucketPair {
    while ($true) {
        $raw = Read-Host "Copy chats FROM,TO account numbers (e.g. 1,2; Enter for separate prompts)"
        if (-not $raw) {
            $source = Select-Bucket "Copy chats FROM account #" 0
            $destination = Select-Bucket "Copy chats TO account #" $source
            return [pscustomobject]@{ Source = $source; Destination = $destination }
        }

        $matches = @([regex]::Matches($raw, '\d+') | ForEach-Object { [int]$_.Value })
        if ($matches.Count -ne 2) {
            Write-Host "Enter exactly two account numbers, like 1,2." -ForegroundColor Yellow
            continue
        }

        $source = $matches[0]
        $destination = $matches[1]
        if ($source -lt 1 -or $source -gt $script:Buckets.Count -or $destination -lt 1 -or $destination -gt $script:Buckets.Count) {
            Write-Host "Enter numbers from 1 to $($script:Buckets.Count)." -ForegroundColor Yellow
            continue
        }
        if ($source -eq $destination) {
            Write-Host "Source and destination must be different accounts." -ForegroundColor Yellow
            continue
        }

        return [pscustomobject]@{ Source = $source; Destination = $destination }
    }
}

$selection = Select-BucketPair
$srcIdx = $selection.Source
$dstIdx = $selection.Destination
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
