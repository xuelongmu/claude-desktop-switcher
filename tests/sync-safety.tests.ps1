# Run: powershell -NoProfile -ExecutionPolicy Bypass -File tests/sync-safety.tests.ps1
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'sync-safety.ps1')

function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
}
function Assert-Throws([scriptblock]$Operation, [string]$Pattern) {
    $caught = $null
    try { & $Operation } catch { $caught = $_ }
    Assert ($null -ne $caught -and $caught.Exception.Message -like $Pattern) "Expected error matching '$Pattern'; got '$caught'"
}
# Isolate the process guard from the user's live desktop.
$script:ClaudeRunning = $false
function Get-Process { param($Name, $ErrorAction) if ($script:ClaudeRunning) { [pscustomobject]@{ Id = 1 } } }

$root = Join-Path ([IO.Path]::GetTempPath()) ('switcher-test-' + [guid]::NewGuid().ToString('N'))
$source = Join-Path $root 'source'
$destination = Join-Path $root 'destination'
$null = New-Item -ItemType Directory -Path $source, $destination
$one = 'local_11111111-1111-1111-1111-111111111111.json'
$two = 'local_22222222-2222-2222-2222-222222222222.json'
$only = 'local_33333333-3333-3333-3333-333333333333.json'
$utf8 = [Text.UTF8Encoding]::new($false)
function Put-Record([string]$Folder, [string]$Name, [string]$Title) {
    $json = @{sessionId = $Name.Replace('.json', ''); title = $Title} | ConvertTo-Json
    [IO.File]::WriteAllText((Join-Path $Folder $Name), $json, $utf8)
}
function Read-BytesText([string]$Path) { [Convert]::ToBase64String([IO.File]::ReadAllBytes($Path)) }

try {
    Put-Record $source $one ('Renamed ' + [char]0x4e2d + [char]0x6587)
    Put-Record $source $two 'Added'
    Put-Record $destination $one 'Original'
    Put-Record $destination $only 'Destination only'
    $original = Read-BytesText (Join-Path $destination $one)
    $actions = @($one, $two | ForEach-Object {
        [pscustomobject]@{ Source = Join-Path $source $_; Destination = Join-Path $destination $_ }
    })

    $script:ClaudeRunning = $true
    Assert-Throws { Invoke-SessionSync $actions $root $source $destination } '*Quit Claude completely*'
    Assert (-not (Test-Path (Join-Path $root 'claude-desktop-switcher-backups'))) 'Running app must prevent writes'
    $script:ClaudeRunning = $false

    [IO.File]::WriteAllText((Join-Path $source $two), '{broken', $utf8)
    Assert-Throws { Invoke-SessionSync $actions $root $source $destination } '*Invalid session JSON*'
    Assert ((Read-BytesText (Join-Path $destination $one)) -eq $original) 'Invalid batch must not partially update'
    [IO.File]::WriteAllText((Join-Path $source $two), '{"sessionId":"wrong"}', $utf8)
    Assert-Throws { Read-SessionRecord (Join-Path $source $two) } '*Invalid session record*'
    $wrapped = '[{"sessionId":"' + $two.Replace('.json', '') + '"}]'
    [IO.File]::WriteAllText((Join-Path $source $two), $wrapped, $utf8)
    Assert-Throws { Read-SessionRecord (Join-Path $source $two) } '*Invalid session record*'
    Put-Record $source $two 'Added'

    $backup = Invoke-SessionSync $actions $root $source $destination
    Assert ((Read-BytesText (Join-Path $source $one)) -eq (Read-BytesText (Join-Path $destination $one))) 'Update preserves UTF-8 bytes'
    Assert ((Read-BytesText (Join-Path $source $two)) -eq (Read-BytesText (Join-Path $destination $two))) 'Missing record is added'
    Assert ((Read-BytesText (Join-Path (Join-Path $backup 'before') $one)) -eq $original) 'Backup preserves original bytes'
    Assert ((Read-SessionRecord (Join-Path $destination $only)).title -eq 'Destination only') 'Destination-only record survives'
    $manifest = Get-Content -LiteralPath (Join-Path $backup 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert ($manifest.Entries.Count -eq 2 -and $manifest.Entries[0].Existed -and -not $manifest.Entries[1].Existed) 'Manifest distinguishes updates and adds'

    # An OS-level lock on the second destination forces a real replace failure
    # after the first update has succeeded, exercising batch rollback.
    $preFailure = Read-BytesText (Join-Path $destination $one)
    Put-Record $source $one 'Must be rolled back'
    $lock = [IO.File]::Open((Join-Path $destination $two), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        Assert-Throws { Invoke-SessionSync $actions $root $source $destination } '*Sync failed; rollback attempted*'
    } finally { $lock.Dispose() }
    Assert ((Read-BytesText (Join-Path $destination $one)) -eq $preFailure) 'Earlier updates roll back after replace failure'
    Assert (@(Get-ChildItem -LiteralPath $destination -Filter '.sync-*.tmp' -Force).Count -eq 0) 'Temporary files are cleaned up'
    Write-Host 'PASS: running-app guard, malformed JSON, identity validation, add/update, UTF-8, backup, destination-only preservation, I/O rollback.'
} finally {
    # The only deletion target is this test's unique, verified temp directory.
    $resolved = [IO.Path]::GetFullPath($root)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolved) -notmatch '^switcher-test-[0-9a-f]{32}$') { throw 'Unexpected test cleanup path' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
