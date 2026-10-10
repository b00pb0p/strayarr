#Requires -Version 5.1
<#
.SYNOPSIS
    Finds files in qBittorrent's download directories that no torrent claims.

.DESCRIPTION
    Runs ON the qBittorrent host, where both halves of the question are local:
    the WebUI API (localhost) and the filesystem. Nothing is mounted, no paths
    are translated, and only the RESULT leaves the machine.

    Safety model, in order:
      1. Default mode reports and touches nothing.
      2. -Quarantine MOVES orphans to a dated folder, preserving relative
         structure, after re-querying the API to confirm each is still an
         orphan. A move is reversible; deletion is not.
      3. You delete the quarantine folder yourself, later, by hand.

    Bias: whenever a path is ambiguous, it is added to the EXPECTED set. That
    means we may miss an orphan, never that we invent one. Missing an orphan
    costs disk space; inventing one costs data.

    SPEED (v4). One change, and only one, because it is the only one that is
    sound:

      * Per-torrent file lists are cached to disk, keyed by infohash. A
        torrent's file list is FIXED by its infohash -- it cannot change
        without becoming a different torrent -- so this cache cannot go stale.
        Save paths do move, but those come from torrents/info, which is always
        fetched fresh. First run is slow; every run after it is not.

    What was REMOVED in v4: v2 and v3 tried to skip per-file lookups by
    treating a completed torrent's content_path as a prefix -- "this torrent is
    done, so everything under its folder is accounted for". That is false. A
    torrent's folder routinely holds files the torrent never contained: extra
    episodes, leftovers from an earlier release, samples. The shortcut hid 25
    of 29 real orphans, all of them inside subfolders. Matching is per-file
    only. Do not reintroduce prefix matching.

    The disk walk is deliberately NOT cached. Its whole purpose is to observe
    the filesystem as it is right now.

.EXAMPLE
    .\Invoke-OrphanScan.ps1 -ScanPath 'D:\Downloads'

.EXAMPLE
    .\Invoke-OrphanScan.ps1 -ScanPath 'D:\Downloads' -QbUrl 'http://localhost:9090' -Quarantine 'D:\_orphans' -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)][string[]]$ScanPath,

    [string]$QbUrl  = 'http://localhost:8080',
    [string]$QbUser = '',
    [string]$QbPass = '',

    [string]$ReportDir = (Join-Path $PSScriptRoot 'reports'),
    [string]$CachePath = (Join-Path $PSScriptRoot 'reports\filelist-cache.json'),
    [switch]$NoCache,

    # Translate the paths qBittorrent reports into paths this machine can see.
    # Needed whenever the client runs in a container or behind a mapped drive:
    #   -PathMap '/data/torrents=D:\Downloads'
    [string[]]$PathMap = @(),

    [int]$MinAgeHours = 24,
    [string[]]$ExcludePattern = @(),

    [string]$Quarantine,
    [switch]$AllowHardlinked,

    [string]$NtfyUrl, [string]$NtfyTopic, [string]$NtfyToken
)

$ErrorActionPreference = 'Stop'
$swTotal = [Diagnostics.Stopwatch]::StartNew()
$script:fromCache = 0

# ---------------------------------------------------------------- helpers

function Normalize-Path {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    ($Path -replace '/', '\').TrimEnd('\')
}

# The directory holding a file, by plain string work on an already-normalised
# path. Deliberately NOT Split-Path: that rewrites separators to the platform's
# own, so its answer stops matching the backslash form everything else here
# compares in. The first version of the narrowed re-verification used it, and
# the equivalence test caught 242 candidates it would have wrongly cleared for
# moving on a platform where the separators differ.
function Get-ParentDir {
    param([string]$Path)
    $i = $Path.LastIndexOf('\')
    if ($i -lt 0) { return $Path }
    $Path.Substring(0, $i)
}

# Applied to every path qBittorrent reports, before comparison. Longest prefix
# wins, so nested mappings behave predictably. Needed whenever the client sees
# different paths from this machine -- a container, a mapped drive, a remote
# mount. Without it, every reported path simply passes through unchanged.
$script:MapRules = @()
foreach ($m in $PathMap) {
    $parts = $m -split '=', 2
    if ($parts.Count -ne 2) { throw "Bad -PathMap entry '$m'. Expected 'from=to'." }
    $script:MapRules += , @((Normalize-Path $parts[0]), (Normalize-Path $parts[1]))
}
$script:MapRules = @($script:MapRules | Sort-Object { $_[0].Length } -Descending)

function Convert-ClientPath {
    param([string]$Path)
    $p = Normalize-Path $Path
    if (-not $p) { return $null }
    foreach ($rule in $script:MapRules) {
        if ($p -eq $rule[0]) { return $rule[1] }
        if ($p.StartsWith($rule[0] + '\', [StringComparison]::OrdinalIgnoreCase)) {
            return (Normalize-Path ($rule[1] + $p.Substring($rule[0].Length)))
        }
    }
    $p
}


function Format-Size {
    param([long]$Bytes)
    $u = 'B','KB','MB','GB','TB'; $i = 0; $n = [double]$Bytes
    while ($n -ge 1024 -and $i -lt 4) { $n /= 1024; $i++ }
    '{0:N1} {1}' -f $n, $u[$i]
}

# Returns the number of hard links, or $null when it cannot tell.
#
# $null matters. The previous version returned 1 ("not linked") on any failure,
# including on platforms where fsutil does not exist -- so the guard that skips
# hardlinked files would silently protect nothing while appearing to work. An
# unknown answer must block the move, not permit it.
function Get-HardlinkCount {
    param([string]$Path)
    if ($IsLinux -or $IsMacOS) {
        try {
            $n = & stat -c '%h' "$Path" 2>$null
            if ($LASTEXITCODE -eq 0 -and $n -match '^\d+$') { return [int]$n }
        } catch {
            Write-Verbose "stat failed for '$Path': $($_.Exception.Message)"
        }
        # Unknown link count. The caller treats $null as "do not move".
        return $null
    }
    try {
        $out = & fsutil.exe hardlink list "$Path" 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        return (@($out | Where-Object { $_.Trim() })).Count
    } catch { return $null }
}

# ------------------------------------------------------------ API session

function Connect-Qb {
    $s = $null
    try {
        Invoke-RestMethod -Uri "$QbUrl/api/v2/auth/login" -Method Post `
            -Body @{ username = $QbUser; password = $QbPass } `
            -SessionVariable s -TimeoutSec 30 | Out-Null
    } catch {
        throw "Could not log in to qBittorrent at $QbUrl : $($_.Exception.Message)"
    }
    $s
}

# Builds the expected set. Returns exact file paths and directory prefixes
# separately: a disk file is expected if it matches a path, or if any of its
# ancestor directories is a known root.
#
# -OnlyUnder narrows which torrents have their file list fetched, and exists
# for the re-verification before a move. That pass must not trust the cache, so
# it used to re-fetch every torrent: 1,739 requests, many minutes, to confirm
# three files in one folder. But a torrent only ever claims files beneath its
# own save or download directory, so one whose directories are not an ancestor
# of any candidate cannot claim any candidate, and its file list cannot change
# the answer. Those are skipped. content_path still comes from the fresh
# torrent list for EVERY torrent, since that costs no extra request.
#
# The test is a plain prefix with no separator check, on purpose. That can only
# over-include (E:\tv also matches E:\tv-4k), which costs a request, and never
# under-include, which would cost a file.
function Build-Expected {
    param($Session, [hashtable]$Cache, [ref]$ApiCalls, [string[]]$OnlyUnder)

    $paths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    try {
        $torrents = Invoke-RestMethod -Uri "$QbUrl/api/v2/torrents/info" -WebSession $Session -TimeoutSec 120
    } catch {
        throw "Could not list torrents: $($_.Exception.Message)"
    }
    if (-not $torrents) {
        throw "qBittorrent returned no torrents. Refusing to continue: with an empty expected set, every file on disk looks like an orphan."
    }

    $i = 0
    foreach ($t in $torrents) {
        $i++
        # Write-Progress is surprisingly expensive in 5.1 -- update sparingly.
        if ($i % 50 -eq 0) {
            Write-Progress -Activity 'Building expected set' -Status "$i / $($torrents.Count)" `
                -PercentComplete (($i / $torrents.Count) * 100)
        }

        # content_path is added as an EXACT path only. It is never used as a
        # prefix: owning a folder does not mean owning everything in it.
        $cp = Convert-ClientPath $t.content_path
        if ($cp) { [void]$paths.Add($cp) }

        $rootDirs = @()
        if ($t.save_path)     { $rootDirs += (Convert-ClientPath $t.save_path) }
        if ($t.download_path) { $rootDirs += (Convert-ClientPath $t.download_path) }

        if ($PSBoundParameters.ContainsKey('OnlyUnder')) {
            $relevant = $false
            foreach ($r in $rootDirs) {
                if (-not $r) { continue }
                foreach ($d in $OnlyUnder) {
                    if ($d.StartsWith($r, [StringComparison]::OrdinalIgnoreCase)) { $relevant = $true; break }
                }
                if ($relevant) { break }
            }
            if (-not $relevant) { continue }
        }

        $names = $null
        if (-not $NoCache -and $Cache.ContainsKey($t.hash)) {
            $names = $Cache[$t.hash]
            $script:fromCache++
        } else {
            try {
                $files = Invoke-RestMethod -Uri "$QbUrl/api/v2/torrents/files?hash=$($t.hash)" `
                    -WebSession $Session -TimeoutSec 60
            } catch {
                throw "Could not read file list for '$($t.name)': $($_.Exception.Message)"
            }
            $ApiCalls.Value++
            $names = @($files | ForEach-Object { $_.name })
            $Cache[$t.hash] = $names
        }

        foreach ($nm in $names) {
            $rel = Normalize-Path $nm
            foreach ($r in $rootDirs) {
                $full = Normalize-Path (Join-Path $r $rel)
                [void]$paths.Add($full)
                [void]$paths.Add("$full.!qB")   # partial-download sidecar
            }
        }
    }
    Write-Progress -Activity 'Building expected set' -Completed

    [pscustomobject]@{ Paths = $paths; Torrents = $torrents }
}

# Exact match only. See the v4 note above for why there is no prefix logic.
function Test-Expected {
    param([string]$Path, $Expected)
    $Expected.Paths.Contains($Path)
}

# ------------------------------------------------------------------ cache

$cache = @{}
if (-not $NoCache -and (Test-Path -LiteralPath $CachePath)) {
    try {
        $raw = Get-Content -LiteralPath $CachePath -Raw | ConvertFrom-Json
        foreach ($p in $raw.PSObject.Properties) { $cache[$p.Name] = @($p.Value) }
        Write-Host ("Cache: {0} torrent file-lists loaded" -f $cache.Count)
    } catch {
        Write-Warning "Cache unreadable, rebuilding: $($_.Exception.Message)"
        $cache = @{}
    }
}

# -------------------------------------------------------------- expected

$session  = Connect-Qb
$apiCalls = 0
$swApi    = [Diagnostics.Stopwatch]::StartNew()
$expected = Build-Expected -Session $session -Cache $cache -ApiCalls ([ref]$apiCalls)
$swApi.Stop()

Write-Host ("qBittorrent: {0} torrents | {1} cached, {2} fetched | expected {3} paths | api {4:N1}s" -f `
    $expected.Torrents.Count, $script:fromCache, $apiCalls, $expected.Paths.Count, $swApi.Elapsed.TotalSeconds)

if (-not $NoCache) {
    # Drop entries for torrents that no longer exist, so the file cannot grow forever.
    $live = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($t in $expected.Torrents) { [void]$live.Add($t.hash) }
    $pruned = @{}
    foreach ($k in $cache.Keys) { if ($live.Contains($k)) { $pruned[$k] = $cache[$k] } }
    $dir = Split-Path $CachePath -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $pruned | ConvertTo-Json -Depth 4 -Compress | Set-Content -LiteralPath $CachePath -Encoding UTF8
}

# ------------------------------------------------------------ walk disk

$swWalk  = [Diagnostics.Stopwatch]::StartNew()
$cutoff  = (Get-Date).AddHours(-$MinAgeHours)
$orphans = New-Object System.Collections.Generic.List[object]
$walkErrors = 0
$seenFiles  = 0

foreach ($root in $ScanPath) {
    $rootN = Normalize-Path $root
    if (-not (Test-Path -LiteralPath $rootN)) { throw "ScanPath does not exist: $rootN" }
    Write-Host "Scanning $rootN ..."
    try {
        $files = [System.IO.Directory]::EnumerateFiles($rootN, '*', [System.IO.SearchOption]::AllDirectories)
    } catch {
        Write-Warning "Could not enumerate $rootN : $($_.Exception.Message)"
        $walkErrors++; continue
    }
    foreach ($path in $files) {
        $seenFiles++
        $p = Normalize-Path $path
        if (Test-Expected -Path $p -Expected $expected) { continue }

        $skip = $false
        foreach ($pat in $ExcludePattern) { if ($p -match $pat) { $skip = $true; break } }
        if ($skip) { continue }

        try { $info = New-Object System.IO.FileInfo($p) } catch { $walkErrors++; continue }
        if ($info.LastWriteTime -gt $cutoff) { continue }

        $orphans.Add([pscustomobject]@{
            Path = $p; Bytes = $info.Length; Size = Format-Size $info.Length; Modified = $info.LastWriteTime
        })
    }
}
$swWalk.Stop()

$orphans = @($orphans | Sort-Object Bytes -Descending)
$total   = ($orphans | Measure-Object Bytes -Sum).Sum
if (-not $total) { $total = 0 }

Write-Host ""
Write-Host ("Scanned {0} file(s) in {1:N1}s" -f $seenFiles, $swWalk.Elapsed.TotalSeconds)
Write-Host ("Orphans: {0} file(s), {1}" -f $orphans.Count, (Format-Size $total)) -ForegroundColor Yellow
if ($walkErrors) { Write-Warning "$walkErrors path(s) could not be read; they are simply absent from this report." }
$orphans | Select-Object -First 15 | Format-Table Size, Modified, Path -AutoSize

# ---------------------------------------------------------------- report

if (-not (Test-Path -LiteralPath $ReportDir)) { New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null }
$stamp  = Get-Date -Format 'yyyy-MM-dd_HHmm'
$report = Join-Path $ReportDir "orphans-$stamp.json"
[pscustomobject]@{
    generated   = (Get-Date).ToString('o')
    host        = $env:COMPUTERNAME
    scanPaths   = $ScanPath
    torrents    = $expected.Torrents.Count
    expected    = $expected.Paths.Count
    apiCalls    = $apiCalls
    filesSeen   = $seenFiles
    walkErrors  = $walkErrors
    secondsApi  = [math]::Round($swApi.Elapsed.TotalSeconds, 1)
    secondsWalk = [math]::Round($swWalk.Elapsed.TotalSeconds, 1)
    orphanCount = $orphans.Count
    orphanBytes = $total
    orphans     = $orphans
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $report -Encoding UTF8
Write-Host "Report: $report"
Write-Host ("Total {0:N1}s (api {1:N1}s, walk {2:N1}s)" -f `
    $swTotal.Elapsed.TotalSeconds, $swApi.Elapsed.TotalSeconds, $swWalk.Elapsed.TotalSeconds)

if ($NtfyUrl -and $NtfyTopic) {
    $body = @{
        topic   = $NtfyTopic
        title   = "$($env:COMPUTERNAME): $($orphans.Count) orphans"
        message = "$(Format-Size $total) not claimed by any torrent`n$($expected.Torrents.Count) torrents checked"
        tags    = @('wastebasket')
    } | ConvertTo-Json
    $h = @{}
    if ($NtfyToken) { $h['Authorization'] = "Bearer $NtfyToken" }
    try {
        Invoke-RestMethod -Uri $NtfyUrl -Method Post -Body $body -ContentType 'application/json' -Headers $h -TimeoutSec 20 | Out-Null
        Write-Host "Notified $NtfyTopic"
    } catch { Write-Warning "ntfy failed: $($_.Exception.Message)" }
}

# ------------------------------------------------------------ quarantine

if (-not $Quarantine) {
    Write-Host ""
    Write-Host "Report only. Re-run with -Quarantine <dir> to move these, or add -WhatIf to preview." -ForegroundColor Cyan
    return
}
if ($orphans.Count -eq 0) { return }

Write-Host ""
Write-Host "Re-verifying against a fresh torrent list before moving anything..."
$freshCache = @{}          # deliberately cold: verification must not trust cached state
$freshCalls = 0
# Only the directories that actually hold a candidate. See Build-Expected.
$orphanDirs = @($orphans | ForEach-Object { Get-ParentDir $_.Path } | Sort-Object -Unique)
$swVerify = [Diagnostics.Stopwatch]::StartNew()
$fresh = Build-Expected -Session $session -Cache $freshCache -ApiCalls ([ref]$freshCalls) -OnlyUnder $orphanDirs
$swVerify.Stop()
Write-Host ("Re-fetched {0} of {1} torrents: only those that could claim a file in the {2} folder(s) holding candidates ({3:N1}s)" -f `
    $freshCalls, $fresh.Torrents.Count, $orphanDirs.Count, $swVerify.Elapsed.TotalSeconds)

$dest = Join-Path $Quarantine (Get-Date -Format 'yyyy-MM-dd')
$moved = 0; $movedBytes = 0; $skipped = 0

foreach ($o in $orphans) {
    if (Test-Expected -Path $o.Path -Expected $fresh) {
        Write-Warning "Now claimed by a torrent, skipping: $($o.Path)"; $skipped++; continue
    }
    if (-not (Test-Path -LiteralPath $o.Path)) { $skipped++; continue }

    if (-not $AllowHardlinked) {
        $links = Get-HardlinkCount $o.Path
        if ($null -eq $links) {
            Write-Warning "Could not determine hard-link count, skipping to be safe: $($o.Path)"
            $skipped++; continue
        }
        if ($links -gt 1) {
            Write-Warning "Hardlinked (also lives elsewhere), skipping: $($o.Path)"
            $skipped++; continue
        }
    }

    $rel = $o.Path
    foreach ($root in $ScanPath) {
        $rn = Normalize-Path $root
        if ($rel.StartsWith($rn, [StringComparison]::OrdinalIgnoreCase)) {
            $rel = $rel.Substring($rn.Length).TrimStart('\'); break
        }
    }
    $target    = Join-Path $dest $rel
    $targetDir = Split-Path $target -Parent

    if ($PSCmdlet.ShouldProcess($o.Path, "Move to $target")) {
        try {
            if (-not (Test-Path -LiteralPath $targetDir)) { New-Item -ItemType Directory -Path $targetDir -Force | Out-Null }
            Move-Item -LiteralPath $o.Path -Destination $target -ErrorAction Stop
            $moved++; $movedBytes += $o.Bytes
        } catch {
            Write-Warning "Move failed for $($o.Path): $($_.Exception.Message)"; $skipped++
        }
    }
}

Write-Host ""
Write-Host ("Quarantined {0} file(s), {1} -> {2}" -f $moved, (Format-Size $movedBytes), $dest) -ForegroundColor Green
if ($skipped) { Write-Host "Skipped $skipped file(s); see warnings above." -ForegroundColor Yellow }
Write-Host "Nothing has been deleted. Review that folder, then remove it yourself when you're satisfied." -ForegroundColor Cyan
