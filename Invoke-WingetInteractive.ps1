<#
.SYNOPSIS
    Interactive winget package upgrades - prompts y/n before each one.

.DESCRIPTION
    Does what 'winget upgrade --all' won't: walks available updates one by one
    and waits for confirmation. Under the hood it uses the COM module
    'Microsoft.WinGet.Client' - no text-table parsing, so it works regardless of
    system language (locale-proof).

    Runs on PS 5.1 and PS 7.

.PARAMETER Exclude
    List of IDs (wildcards ok) to skip without prompting.
    e.g. -Exclude 'Mozilla.Firefox','*JetBrains*'

.PARAMETER Mode
    Installer mode passed to Update-WinGetPackage: Default | Silent | Interactive.
    NOTE: 'Interactive' = the installer GUI, NOT a winget prompt.

.PARAMETER Source
    winget | msstore | All. Default 'winget' (store apps can be messy).

.PARAMETER IncludeUnknown
    Don't skip packages with InstalledVersion = 'Unknown'.

.PARAMETER AutoApprove
    No prompting - upgrade everything (like --all, but with a nice summary and log).

.PARAMETER List
    Dry-run. Just print what would be updated, touch nothing.

.PARAMETER LogPath
    Path to a log file (append). Without it, no on-disk logging.

.EXAMPLE
    .\Invoke-WingetInteractive.ps1

.EXAMPLE
    .\Invoke-WingetInteractive.ps1 -Mode Silent -Exclude 'Valve.Steam','*Nvidia*' -LogPath $env:TEMP\winget.log

.NOTES
    Author  : Quaerendir
    License : MIT
#>
[CmdletBinding()]
param(
    [string[]]$Exclude = @(),

    [ValidateSet('Default','Silent','Interactive')]
    [string]$Mode = 'Default',

    [ValidateSet('winget','msstore','All')]
    [string]$Source = 'winget',

    [switch]$IncludeUnknown,
    [switch]$AutoApprove,
    [switch]$List,
    [string]$LogPath
)

$ErrorActionPreference = 'Stop'

# ---------- helpers ----------
function Write-Log {
    param([string]$Message)
    if ($LogPath) {
        $line = "{0}  {1}" -f (Get-Date -Format 's'), $Message
        Add-Content -Path $LogPath -Value $line -Encoding UTF8
    }
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------- module bootstrap ----------
[Net.ServicePointManager]::SecurityProtocol = `
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

if (-not (Get-Module -ListAvailable -Name Microsoft.WinGet.Client)) {
    Write-Host "[*] Module Microsoft.WinGet.Client not found - installing (CurrentUser)..." -ForegroundColor Yellow
    try {
        if (-not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue)) {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force | Out-Null
        }
        Install-Module -Name Microsoft.WinGet.Client -Scope CurrentUser -Force -AllowClobber -Repository PSGallery
    } catch {
        Write-Host "[!] Module install failed: $($_.Exception.Message)" -ForegroundColor Red
        exit 2
    }
}

Import-Module Microsoft.WinGet.Client

# COM/CLI version mismatch -> best-effort repair
try {
    $null = Get-WinGetPackage -ErrorAction Stop | Select-Object -First 1
} catch {
    Write-Host "[!] Get-WinGetPackage errored - trying Repair-WinGetPackageManager..." -ForegroundColor Yellow
    try { Repair-WinGetPackageManager -ErrorAction Stop } catch {
        Write-Host "[!] Repair didn't help. Try manually (may need admin)." -ForegroundColor Red
    }
}

if (-not (Test-Admin)) {
    Write-Host "[i] Running without elevation - machine-scope packages may fail to update." -ForegroundColor DarkYellow
}

# ---------- collect updates ----------
Write-Host "[*] Scanning for available updates..." -ForegroundColor Cyan

$all = Get-WinGetPackage | Where-Object { $_.IsUpdateAvailable }

if ($Source -ne 'All') {
    $all = $all | Where-Object { $_.Source -eq $Source }
}
if (-not $IncludeUnknown) {
    $all = $all | Where-Object { $_.InstalledVersion -and $_.InstalledVersion -ne 'Unknown' }
}

# exclude wildcards by Id and Name
$pkgs = $all | Where-Object {
    $pkg = $_
    -not ($Exclude | Where-Object { $pkg.Id -like $_ -or $pkg.Name -like $_ })
}

if (-not $pkgs) {
    Write-Host "[+] No updates (after filters). Nothing to do." -ForegroundColor Green
    exit 0
}

$total = @($pkgs).Count
Write-Host ("[+] Found {0} update(s).`n" -f $total) -ForegroundColor Green

if ($List) {
    $pkgs | Sort-Object Name | Format-Table `
        @{N='Name';E={$_.Name}},
        @{N='Id';E={$_.Id}},
        @{N='Installed';E={$_.InstalledVersion}},
        @{N='Available';E={$_.AvailableVersions[0]}} -AutoSize
    exit 0
}

# ---------- loop ----------
$approveAll  = $AutoApprove.IsPresent
$rebootFlag  = $false
$stats = [ordered]@{ Updated = 0; Skipped = 0; Failed = 0 }
$i = 0

foreach ($pkg in ($pkgs | Sort-Object Name)) {
    $i++
    $latest = $pkg.AvailableVersions[0]
    $head = "[{0}/{1}] {2}" -f $i, $total, $pkg.Name
    Write-Host $head -ForegroundColor Cyan
    Write-Host ("      {0}  {1} -> {2}" -f $pkg.Id, $pkg.InstalledVersion, $latest) -ForegroundColor DarkGray

    if (-not $approveAll) {
        $ans = Read-Host "      Update? (y)es / (n)o / (a)ll / (q)uit"
        if ($ans -match '^[qQ]') {
            Write-Host "[*] Aborted by user." -ForegroundColor Yellow
            break                                          # exit foreach
        }
        elseif ($ans -match '^[aA]') { $approveAll = $true }   # approve the rest
        elseif ($ans -match '^[yYtT]') { }                     # proceed to update
        else {
            $stats.Skipped++
            Write-Host "      -> skipped`n" -ForegroundColor DarkGray
            continue                                       # next package
        }
    }

    try {
        $r = Update-WinGetPackage -Id $pkg.Id -Mode $Mode -ErrorAction Stop
        if ($r.Status -eq 'Ok') {
            $stats.Updated++
            Write-Host "      -> OK`n" -ForegroundColor Green
            Write-Log ("OK    {0} {1} -> {2}" -f $pkg.Id, $pkg.InstalledVersion, $latest)
            if ($r.RebootRequired) { $rebootFlag = $true }
        } else {
            $stats.Failed++
            Write-Host ("      -> FAIL ({0})`n" -f $r.Status) -ForegroundColor Red
            Write-Log ("FAIL  {0} status={1}" -f $pkg.Id, $r.Status)
        }
    } catch {
        $stats.Failed++
        Write-Host ("      -> FAIL: {0}`n" -f $_.Exception.Message) -ForegroundColor Red
        Write-Log ("FAIL  {0} ex={1}" -f $pkg.Id, $_.Exception.Message)
    }
}

# ---------- summary ----------
Write-Host "----------------------------------------" -ForegroundColor DarkGray
Write-Host ("Updated: {0}  Skipped: {1}  Failed: {2}" -f `
    $stats.Updated, $stats.Skipped, $stats.Failed) -ForegroundColor Cyan
if ($rebootFlag) {
    Write-Host "[!] At least one package requires a reboot." -ForegroundColor Yellow
}

if     ($stats.Failed -gt 0) { exit 1 }
else   { exit 0 }
