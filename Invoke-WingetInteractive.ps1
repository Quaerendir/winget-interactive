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

# NB: never call 'exit' at script level - under 'irm | iex' it closes the whole
# PowerShell window. Main returns an exit code; 'exit' is used only for real files.

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

function Get-InstalledWinGetModuleVersion {
    $m = Get-Module -ListAvailable -Name Microsoft.WinGet.Client |
        Sort-Object Version -Descending | Select-Object -First 1
    if ($m) { $m.Version }
}

# Version of the winget CLI (matches the Microsoft.WinGet.Client numbering), or $null.
function Get-WinGetCliVersion {
    try {
        $raw = & winget --version 2>$null | Select-Object -First 1
        if ($raw -match '(\d+\.\d+\.\d+)') { return [version]$Matches[1] }
    } catch { }
    $null
}

function Install-WinGetClientModule {
    param([string]$MinimumVersion)
    if (-not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force | Out-Null
    }
    $install = @{
        Name = 'Microsoft.WinGet.Client'; Scope = 'CurrentUser'
        Force = $true; AllowClobber = $true; Repository = 'PSGallery'
    }
    if ($MinimumVersion) { $install.MinimumVersion = $MinimumVersion }
    Install-Module @install
}

function Invoke-WingetInteractiveMain {
    # ---------- module bootstrap ----------
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $modVer = Get-InstalledWinGetModuleVersion
    if (-not $modVer) {
        Write-Host "[*] Module Microsoft.WinGet.Client not found - installing (CurrentUser)..." -ForegroundColor Yellow
        try { Install-WinGetClientModule }
        catch {
            Write-Host "[!] Module install failed: $($_.Exception.Message)" -ForegroundColor Red
            return 2
        }
    }
    else {
        # Module older than the winget CLI (App Installer auto-updates, the module
        # doesn't) -> COM activation fails: 'Failed to create instance: -2147023174'.
        $cliVer = Get-WinGetCliVersion
        if ($cliVer -and $modVer -lt $cliVer) {
            Write-Host ("[*] Microsoft.WinGet.Client {0} is older than winget {1} - updating (CurrentUser)..." -f $modVer, $cliVer) -ForegroundColor Yellow
            try {
                Install-WinGetClientModule -MinimumVersion $cliVer.ToString()
                # a stale copy may already be loaded in this session - drop it so the new one is imported
                Remove-Module Microsoft.WinGet.Client -Force -ErrorAction SilentlyContinue
            } catch {
                # not fatal: gallery may lag behind winget, or we may be offline
                Write-Host "[!] Module update failed: $($_.Exception.Message)" -ForegroundColor Yellow
                Write-Host "    Continuing with the installed version; it may not work with this winget." -ForegroundColor Yellow
            }
        }
    }

    # Default Win11 policy (Restricted) blocks the module's Format.ps1xml ->
    # 'AuthorizationManager check failed'. Relax for this process only.
    if ((Get-ExecutionPolicy) -in 'Restricted','Undefined','AllSigned') {
        Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
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
        return 0
    }

    $total = @($pkgs).Count
    Write-Host ("[+] Found {0} update(s).`n" -f $total) -ForegroundColor Green

    if ($List) {
        $pkgs | Sort-Object Name | Format-Table `
            @{N='Name';E={$_.Name}},
            @{N='Id';E={$_.Id}},
            @{N='Installed';E={$_.InstalledVersion}},
            @{N='Available';E={$_.AvailableVersions[0]}} -AutoSize | Out-Host
        return 0
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

    if ($stats.Failed -gt 0) { return 1 }
    return 0
}

$prevEAP = $ErrorActionPreference
$ErrorActionPreference = 'Stop'
try { $code = @(Invoke-WingetInteractiveMain)[-1] }
finally { $ErrorActionPreference = $prevEAP }

if ($PSCommandPath) { exit $code }          # real .ps1 file: propagate exit code
else { $global:LASTEXITCODE = $code }       # iex / scriptblock: don't kill the host
