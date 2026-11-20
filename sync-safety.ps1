# Shared Windows sync safety helpers. Dot-sourcing this file does not touch data.

function Assert-ClaudeStopped {
    $processes = @(Get-Process -Name 'Claude', 'claude-desktop' -ErrorAction SilentlyContinue)
    if ($processes.Count -gt 0) {
        $ids = ($processes | ForEach-Object { $_.Id }) -join ', '
        throw "Quit Claude completely (including its tray icon) before syncing. Remaining Claude process IDs: $ids. No live writes are allowed. You can still use -List or -DryRun while Claude is running."
    }
}

function Read-SessionRecord([string]$Path) {
    # Read UTF-8 explicitly: Windows PowerShell otherwise defaults to ANSI.
    $text = [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false, $true))
    try { $record = ConvertFrom-Json -InputObject $text -ErrorAction Stop }
    catch { throw "Invalid session JSON in '$Path': $($_.Exception.Message)" }
    $expectedId = [IO.Path]::GetFileNameWithoutExtension($Path)
    if (-not $text.TrimStart().StartsWith('{') -or $null -eq $record -or $record -isnot [pscustomobject] -or
        $record.sessionId -isnot [string] -or
        $record.sessionId -cne $expectedId -or
        $expectedId -notmatch '^local_[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$') {
        throw "Invalid session record in '$Path': expected an object with sessionId '$expectedId'."
    }
    return $record
}

function Write-AtomicSessionFile([string]$Source, [string]$Destination) {
    $tempPath = Join-Path ([IO.Path]::GetDirectoryName($Destination)) ('.sync-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::Copy($Source, $tempPath, $false)
        if ([IO.File]::Exists($Destination)) {
            [IO.File]::Replace($tempPath, $Destination, [System.Management.Automation.Language.NullString]::Value)
        } else {
            [IO.File]::Move($tempPath, $Destination)
        }
    } finally {
        if ([IO.File]::Exists($tempPath)) { [IO.File]::Delete($tempPath) }
    }
}

function Invoke-SessionSync([object[]]$Actions, [string]$UserData, [string]$SourceBucket, [string]$DestinationBucket) {
    Assert-ClaudeStopped
    if ($Actions.Count -eq 0) { return $null }
    # Validate the entire plan before backing up or changing any session file.
    foreach ($action in $Actions) { $null = Read-SessionRecord $action.Source }

    $backupRoot = Join-Path $UserData 'claude-desktop-switcher-backups'
    $backup = Join-Path $backupRoot ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N'))
    $before = Join-Path $backup 'before'
    $staged = Join-Path $backup 'staged'
    $null = New-Item -ItemType Directory -Path $before, $staged -Force
    $entries = @()
    foreach ($action in $Actions) {
        $name = [IO.Path]::GetFileName($action.Source)
        $stagedPath = Join-Path $staged $name
        [IO.File]::Copy($action.Source, $stagedPath, $false)
        $null = Read-SessionRecord $stagedPath
        $existed = [IO.File]::Exists($action.Destination)
        if ($existed) { [IO.File]::Copy($action.Destination, (Join-Path $before $name), $false) }
        $entries += [pscustomobject]@{ Name = $name; Existed = $existed }
    }
    $manifest = [pscustomobject]@{
        SourceBucket = $SourceBucket
        DestinationBucket = $DestinationBucket
        CreatedAt = [DateTime]::UtcNow.ToString('o')
        Entries = $entries
    }
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $backup 'manifest.json') -Encoding UTF8
    Write-Host "Backup: $backup"

    # Recheck after staging in case Claude was started during the confirmation.
    Assert-ClaudeStopped
    $applied = @()
    try {
        foreach ($entry in $entries) {
            Assert-ClaudeStopped
            $destination = Join-Path $DestinationBucket $entry.Name
            Write-AtomicSessionFile (Join-Path $staged $entry.Name) $destination
            $applied += $entry
        }
    } catch {
        $failure = $_
        if (Get-Process -Name 'Claude', 'claude-desktop' -ErrorAction SilentlyContinue) {
            throw "Sync stopped because Claude started. Some changes may have been applied; quit Claude before recovering from '$backup'."
        }
        # Do not leave a half-applied batch after an I/O error. Backups survive
        # even if rollback itself fails (e.g. the drive became unavailable).
        foreach ($entry in $applied) {
            $destination = Join-Path $DestinationBucket $entry.Name
            try {
                if ($entry.Existed) {
                    Write-AtomicSessionFile (Join-Path $before $entry.Name) $destination
                } else {
                    [IO.File]::Delete($destination)
                }
            } catch { Write-Warning "Could not roll back '$destination'. Recover from '$backup'." }
        }
        throw "Sync failed; rollback attempted. Backup: '$backup'. $($failure.Exception.Message)"
    }
    return $backup
}
