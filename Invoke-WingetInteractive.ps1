<#
.SYNOPSIS
    Interaktywny upgrade pakietow winget - pyta y/n przed kazdym.

.DESCRIPTION
    Robi to, czego 'winget upgrade --all' nie potrafi: przechodzi po
    dostepnych aktualizacjach jedna po drugiej i pyta o potwierdzenie.
    Pod spodem uzywa modulu COM 'Microsoft.WinGet.Client' - zero parsowania
    tekstowej tabeli, wiec dziala niezaleznie od jezyka systemu (locale-proof).

    Pelza po PS 5.1 i PS 7.

.PARAMETER Exclude
    Lista ID (wildcardy ok) do pominiecia bez pytania.
    np. -Exclude 'Mozilla.Firefox','*JetBrains*'

.PARAMETER Mode
    Tryb instalatora przekazany do Update-WinGetPackage: Default | Silent | Interactive.
    UWAGA: 'Interactive' = GUI instalatora, NIE pytanie win-geta.

.PARAMETER Source
    winget | msstore | All. Domyslnie 'winget' (store apps potrafia robic syf).

.PARAMETER IncludeUnknown
    Nie pomijaj pakietow z InstalledVersion = 'Unknown'.

.PARAMETER AutoApprove
    Bez pytania - leci wszystko (jak --all, ale z ladnym summary i logiem).

.PARAMETER List
    Dry-run. Tylko wypisz co jest do update'u, nic nie ruszaj.

.PARAMETER LogPath
    Sciezka do pliku logu (append). Bez tego brak logowania na dysk.

.EXAMPLE
    .\Invoke-WingetInteractive.ps1

.EXAMPLE
    .\Invoke-WingetInteractive.ps1 -Mode Silent -Exclude 'Valve.Steam','*Nvidia*' -LogPath $env:TEMP\winget.log

.NOTES
    Author : Quaerendir
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

# ---------- bootstrap modulu ----------
[Net.ServicePointManager]::SecurityProtocol = `
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

if (-not (Get-Module -ListAvailable -Name Microsoft.WinGet.Client)) {
    Write-Host "[*] Brak modulu Microsoft.WinGet.Client - instaluje (CurrentUser)..." -ForegroundColor Yellow
    try {
        if (-not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue)) {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force | Out-Null
        }
        Install-Module -Name Microsoft.WinGet.Client -Scope CurrentUser -Force -AllowClobber -Repository PSGallery
    } catch {
        Write-Host "[!] Instalacja modulu padla: $($_.Exception.Message)" -ForegroundColor Red
        exit 2
    }
}

Import-Module Microsoft.WinGet.Client

# COM/CLI version mismatch -> best-effort repair
try {
    $null = Get-WinGetPackage -ErrorAction Stop | Select-Object -First 1
} catch {
    Write-Host "[!] Get-WinGetPackage zwraca blad - probuje Repair-WinGetPackageManager..." -ForegroundColor Yellow
    try { Repair-WinGetPackageManager -ErrorAction Stop } catch {
        Write-Host "[!] Repair nie pomogl. Sprobuj recznie (moze wymagac admina)." -ForegroundColor Red
    }
}

if (-not (Test-Admin)) {
    Write-Host "[i] Dzialasz bez elevacji - pakiety machine-scope moga sie nie zaktualizowac." -ForegroundColor DarkYellow
}

# ---------- zbierz updaty ----------
Write-Host "[*] Skanuje dostepne aktualizacje..." -ForegroundColor Cyan

$all = Get-WinGetPackage | Where-Object { $_.IsUpdateAvailable }

if ($Source -ne 'All') {
    $all = $all | Where-Object { $_.Source -eq $Source }
}
if (-not $IncludeUnknown) {
    $all = $all | Where-Object { $_.InstalledVersion -and $_.InstalledVersion -ne 'Unknown' }
}

# exclude wildcards po Id i Name
$pkgs = $all | Where-Object {
    $pkg = $_
    -not ($Exclude | Where-Object { $pkg.Id -like $_ -or $pkg.Name -like $_ })
}

if (-not $pkgs) {
    Write-Host "[+] Brak aktualizacji (po filtrach). Nic do roboty." -ForegroundColor Green
    exit 0
}

$total = @($pkgs).Count
Write-Host ("[+] Znaleziono {0} aktualizacji.`n" -f $total) -ForegroundColor Green

if ($List) {
    $pkgs | Sort-Object Name | Format-Table `
        @{N='Name';E={$_.Name}},
        @{N='Id';E={$_.Id}},
        @{N='Installed';E={$_.InstalledVersion}},
        @{N='Available';E={$_.AvailableVersions[0]}} -AutoSize
    exit 0
}

# ---------- petla ----------
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
            Write-Host "[*] Przerwano przez uzytkownika." -ForegroundColor Yellow
            break                                          # wychodzi z foreach
        }
        elseif ($ans -match '^[aA]') { $approveAll = $true }   # zatwierdz reszte
        elseif ($ans -match '^[yYtT]') { }                     # leci do update
        else {
            $stats.Skipped++
            Write-Host "      -> pominiete`n" -ForegroundColor DarkGray
            continue                                       # nastepny pakiet
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
    Write-Host "[!] Co najmniej jeden pakiet wymaga restartu." -ForegroundColor Yellow
}

if     ($stats.Failed -gt 0) { exit 1 }
else   { exit 0 }
