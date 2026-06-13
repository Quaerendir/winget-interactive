# winget-interactive

Interaktywny upgrade pakietów `winget` — pyta **y/n przed każdym**.

To, czego `winget upgrade --all` nie potrafi: przechodzi po dostępnych
aktualizacjach jedna po drugiej i czeka na potwierdzenie. Pod spodem moduł COM
`Microsoft.WinGet.Client` zamiast parsowania tekstowej tabeli — więc działa
**niezależnie od języka systemu** (żadnego regexa na zlokalizowane nagłówki).

Pełza po **PowerShell 5.1 i 7**.

## Oneliner

Najprostszy (bez parametrów):

```powershell
irm https://raw.githubusercontent.com/Quaerendir/winget-interactive/main/Invoke-WingetInteractive.ps1 | iex
```

Z parametrami `irm | iex` **nie zadziała** — `iex` na stringu z blokiem `param()`
nie przyjmie argumentów. Trzeba przez scriptblock:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/Quaerendir/winget-interactive/main/Invoke-WingetInteractive.ps1))) -Mode Silent -Exclude 'Valve.Steam','*Nvidia*'
```

Jeśli ExecutionPolicy marudzi:

```powershell
powershell -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/Quaerendir/winget-interactive/main/Invoke-WingetInteractive.ps1 | iex"
```

## Lokalnie

```powershell
.\Invoke-WingetInteractive.ps1
.\Invoke-WingetInteractive.ps1 -List                      # dry-run, tylko lista
.\Invoke-WingetInteractive.ps1 -Mode Silent -LogPath $env:TEMP\winget.log
.\Invoke-WingetInteractive.ps1 -Exclude 'Mozilla.Firefox','*JetBrains*'
.\Invoke-WingetInteractive.ps1 -AutoApprove               # jak --all, ale z summary+logiem
```

## W pętli

Przy każdym pakiecie:

- `y` (lub `t`) — zaktualizuj
- `n` / Enter — pomiń
- `a` — zatwierdź ten i całą resztę bez pytania
- `q` — wyjdź

## Parametry

| Param | Opis |
|---|---|
| `-Exclude` | Lista ID/Name (wildcardy ok) do pominięcia bez pytania |
| `-Mode` | `Default` \| `Silent` \| `Interactive` — tryb instalatora. Uwaga: `Interactive` to GUI installera, **nie** pytanie win-geta |
| `-Source` | `winget` (default) \| `msstore` \| `All` |
| `-IncludeUnknown` | Nie pomijaj pakietów z `InstalledVersion = Unknown` |
| `-AutoApprove` | Leci wszystko bez pytania |
| `-List` | Dry-run |
| `-LogPath` | Append log do pliku |

## Gotchas

- Pakiety **machine-scope** wymagają elevacji — skrypt ostrzega, jeśli lecisz bez admina.
- Przy pierwszym uruchomieniu może doinstalować moduł z PSGallery (`-Scope CurrentUser`)
  + provider NuGet. Wymusza TLS 1.2 (PS 5.1 lubi defaultować na coś starszego).
- Jeśli `Get-WinGetPackage` rzuca błędem (rozjazd wersji COM vs CLI App Installera),
  skrypt robi best-effort `Repair-WinGetPackageManager`.
- Źródło `msstore` bywa kapryśne (agreementy, „Unknown" wersje) — dlatego domyślnie tylko `winget`.

## Exit codes

`0` ok · `1` co najmniej jeden update padł · `2` bootstrap modułu padł

## Licencja

MIT — patrz [LICENSE](LICENSE).
