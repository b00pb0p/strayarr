<#
.SYNOPSIS
    Proves the narrowed re-verification gives the same answer as the full one.

.DESCRIPTION
    Before moving anything, Invoke-OrphanScan.ps1 re-checks its candidates
    against a fresh torrent list. It used to re-fetch every torrent's file list
    for that; it now fetches only torrents that save into a folder holding a
    candidate. This is a tool that moves files it believes nobody needs, so
    "should be equivalent" is not good enough: this builds a few hundred random
    clients and checks, candidate by candidate, that the narrowed pass and the
    full pass agree on every one.

    It loads the real functions out of the script and replaces only the HTTP
    call, so it tests the shipped code and needs no qBittorrent. Runs on
    Windows PowerShell 5.1 and PowerShell 7, on any platform.

    Exit code 0 on success, 1 on any disagreement.
#>
$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Invoke-OrphanScan.ps1'

$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
if ($errors) { throw "Script does not parse: $($errors[0].Message)" }
$wanted = 'Normalize-Path', 'Get-ParentDir', 'Convert-ClientPath', 'Build-Expected', 'Test-Expected'
$found = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false) |
    Where-Object { $wanted -contains $_.Name }
if (@($found).Count -ne $wanted.Count) { throw "Expected $($wanted.Count) functions, found $(@($found).Count)" }
foreach ($f in $found) { . ([scriptblock]::Create($f.Extent.Text)) }

# The check below exercises Build-Expected. The one line it cannot reach is the
# call site that works out WHICH folders to pass it, so pin that by source: it
# must go through Get-ParentDir, the function this test uses too.
$src = Get-Content -LiteralPath $scriptPath -Raw
if ($src -notmatch '\$orphanDirs\s*=\s*@\(\$orphans \| ForEach-Object \{ Get-ParentDir \$_\.Path \}') {
    Write-Host 'The re-verification no longer derives its folders with Get-ParentDir.' -ForegroundColor Red
    exit 1
}
if ($src -notmatch '-OnlyUnder \$orphanDirs') {
    Write-Host 'The re-verification no longer passes those folders to Build-Expected.' -ForegroundColor Red
    exit 1
}

# Join-Path refuses a drive letter that does not exist, and the scenarios below
# use E:, F: and Y: wherever this runs (a CI runner, Linux, a laptop). Stand
# them up as session-only drives; nothing is read from or written to them.
foreach ($letter in 'E', 'F', 'Y') {
    if (-not (Get-PSDrive -Name $letter -ErrorAction SilentlyContinue)) {
        New-PSDrive -Name $letter -PSProvider FileSystem -Root ([System.IO.Path]::GetTempPath()) | Out-Null
    }
}

# What the functions read from script scope.
$QbUrl = 'http://test'
$NoCache = $false
$script:MapRules = @()
$script:fromCache = 0

# The stand-in client. A function outranks a cmdlet of the same name.
$script:Client = @()
$script:FileCalls = 0
function Invoke-RestMethod {
    param($Uri, $WebSession, $TimeoutSec, $Method, $Body, $SessionVariable)
    if ($Uri -like '*/torrents/info') { return $script:Client }
    if ($Uri -match 'hash=(.+)$') {
        $script:FileCalls++
        $h = $Matches[1]
        $t = $script:Client | Where-Object { $_.hash -eq $h }
        return @($t.files | ForEach-Object { [pscustomobject]@{ name = $_ } })
    }
    throw "unexpected request: $Uri"
}

$rng = New-Object System.Random 20261010
# Chosen to be awkward: a drive root, nested folders, and siblings where one
# name is a prefix of the other (tv / tv-4k), which is where a prefix test errs.
$roots = 'E:\tv', 'E:\tv-4k', 'E:\tv\sub', 'E:\TV', 'F:\m', 'F:\m\x', 'E:', 'Y:\seed\Music', 'Y:\seed'
$leafs = 'a.mkv', 'b.flac', 'Album\01.flac', 'Album\CD1\01.flac', 'Show.S01\e1.mkv', 'x'

function New-Client {
    $n = $rng.Next(1, 14)
    @(1..$n | ForEach-Object {
        $save = $roots[$rng.Next($roots.Count)]
        $files = @(1..$rng.Next(1, 5) | ForEach-Object { $leafs[$rng.Next($leafs.Count)] } | Sort-Object -Unique)
        $t = [pscustomobject]@{
            hash = "h$_"; name = "t$_"; save_path = $save; download_path = $null
            content_path = "$save\" + ($files[0] -split '\\')[0]; files = $files
        }
        if ($rng.Next(4) -eq 0) { $t.download_path = $roots[$rng.Next($roots.Count)] }
        if ($rng.Next(5) -eq 0) { $t.save_path = $t.save_path -replace '\\', '/' }   # clients report either
        $t
    })
}

$fail = 0; $checked = 0; $claimed = 0; $savedCalls = 0; $fullCalls = 0
for ($round = 1; $round -le 400; $round++) {
    $script:Client = New-Client

    # Candidates: a mix of files some torrent does claim and files none does.
    $cands = New-Object System.Collections.Generic.List[string]
    foreach ($k in 1..$rng.Next(1, 9)) {
        $r = $roots[$rng.Next($roots.Count)]
        $leaf = $leafs[$rng.Next($leafs.Count)]
        $suffix = ''
        if ($rng.Next(6) -eq 0) { $suffix = '.!qB' }
        if ($rng.Next(3) -eq 0) { $leaf = "stray$k.bin" }
        $cands.Add((Normalize-Path "$r\$leaf$suffix"))
    }
    # The same expression the script uses, through the same function.
    $dirs = @($cands | ForEach-Object { Get-ParentDir $_ } | Sort-Object -Unique)

    $calls = 0
    $script:FileCalls = 0
    $full = Build-Expected -Session $null -Cache @{} -ApiCalls ([ref]$calls)
    $fullCalls += $script:FileCalls
    $script:FileCalls = 0
    $narrow = Build-Expected -Session $null -Cache @{} -ApiCalls ([ref]$calls) -OnlyUnder $dirs
    $savedCalls += $script:FileCalls

    foreach ($c in $cands) {
        $checked++
        $a = Test-Expected -Path $c -Expected $full
        $b = Test-Expected -Path $c -Expected $narrow
        if ($a) { $claimed++ }
        if ($a -ne $b) {
            $fail++
            if ($fail -le 10) { Write-Host "DISAGREE round $round : $c  full=$a narrowed=$b" -ForegroundColor Red }
        }
    }
}

Write-Host "Candidates checked: $checked ($claimed claimed by a torrent, $($checked - $claimed) not)"
Write-Host "File-list requests: $fullCalls full, $savedCalls narrowed"
if ($claimed -lt 100 -or ($checked - $claimed) -lt 100) {
    Write-Host "The scenarios are lopsided, so agreement proves little. Fix the generator." -ForegroundColor Red
    exit 1
}
if ($savedCalls -ge $fullCalls) {
    Write-Host "Narrowing saved no requests, so it is not narrowing." -ForegroundColor Red
    exit 1
}
if ($fail) { Write-Host "$fail disagreement(s)." -ForegroundColor Red; exit 1 }
Write-Host "Narrowed re-verification agrees with the full one on every candidate." -ForegroundColor Green
