# winget-interactive

Interactive `winget` package upgrades — **prompts y/n before each one**.

What `winget upgrade --all` won't do: walk available updates one by one and wait
for confirmation. Under the hood it uses the `Microsoft.WinGet.Client` COM module
instead of parsing the text table — so it works **regardless of system language**
(no regex against localized headers).

Runs on **PowerShell 5.1 and 7**.

## One-liner

Simplest (no parameters):

```powershell
irm https://raw.githubusercontent.com/Quaerendir/winget-interactive/main/Invoke-WingetInteractive.ps1 | iex
```

With parameters, `irm | iex` **won't work** — `iex` on a string containing a
`param()` block can't take arguments. Use the scriptblock form:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/Quaerendir/winget-interactive/main/Invoke-WingetInteractive.ps1))) -Mode Silent -Exclude 'Valve.Steam','*Nvidia*'
```

If ExecutionPolicy complains:

```powershell
powershell -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/Quaerendir/winget-interactive/main/Invoke-WingetInteractive.ps1 | iex"
```

## Local

```powershell
.\Invoke-WingetInteractive.ps1
.\Invoke-WingetInteractive.ps1 -List                      # dry-run, list only
.\Invoke-WingetInteractive.ps1 -Mode Silent -LogPath $env:TEMP\winget.log
.\Invoke-WingetInteractive.ps1 -Exclude 'Mozilla.Firefox','*JetBrains*'
.\Invoke-WingetInteractive.ps1 -AutoApprove               # like --all, but with summary + log
```

## In the loop

For each package:

- `y` (or `t`) — update
- `n` / Enter — skip
- `a` — approve this one and all remaining without asking
- `q` — quit

## Parameters

| Param | Description |
|---|---|
| `-Exclude` | List of IDs/Names (wildcards ok) to skip without prompting |
| `-Mode` | `Default` \| `Silent` \| `Interactive` — installer mode. Note: `Interactive` means the installer GUI, **not** a winget prompt |
| `-Source` | `winget` (default) \| `msstore` \| `All` |
| `-IncludeUnknown` | Don't skip packages with `InstalledVersion = Unknown` |
| `-AutoApprove` | Upgrade everything without prompting |
| `-List` | Dry-run |
| `-LogPath` | Append a log to a file |

## Gotchas

- **Machine-scope** packages need elevation — the script warns if you run without admin.
- First run may pull the module from PSGallery (`-Scope CurrentUser`) plus the NuGet
  provider. It forces TLS 1.2 (PS 5.1 likes to default to something older).
- If `Get-WinGetPackage` throws (COM vs CLI App Installer version drift), the script
  attempts a best-effort `Repair-WinGetPackageManager`.
- **`Failed to create instance: -2147023174` (0x800706BA)** from `Get-WinGetPackage`
  almost always means the `Microsoft.WinGet.Client` module is **older than the installed
  winget** (App Installer updates itself, the PowerShell module doesn't). The script
  now compares the two on start and updates the module (`-MinimumVersion` = winget's
  version, CurrentUser scope) when it lags. Verified in an elevated session: App Installer
  1.29.380 + module 1.28.240 fails; the same winget with module 1.29.380 works.
  `Repair-WinGetPackageManager` does **not** fix this. Manual fix:
  `Update-Module Microsoft.WinGet.Client -Force`. An old version left on disk is
  harmless (the newest is loaded); remove it with `Uninstall-Module ... -RequiredVersion`
  from a fresh shell, since a running session locks the old DLL.
  If the module is already current and the error persists, see the possibly related
  [winget-cli#6560](https://github.com/microsoft/winget-cli/issues/6560); workaround:
  run non-elevated (user-scope packages only), or downgrade:
  `winget install Microsoft.AppInstaller --version 1.29.280 --force` (non-elevated shell).
- If the gallery has no module version matching your winget yet, the update fails with a
  warning and the script carries on with the installed module.
- The `msstore` source is finicky (agreements, "Unknown" versions) — hence the default
  is `winget` only.

## Exit codes

`0` ok · `1` at least one upgrade failed · `2` module bootstrap failed

## License

MIT — see [LICENSE](LICENSE).
