# LamaTeam Counter-Strike: Source Setup, Config, Maps, and Player Utility

LamaTeam’s CS:S setup utility helps players prepare their Counter-Strike: Source install, add the LamaTeam server connection, and find missing community maps. This repository keeps the LamaTeam CS:S server information and configuration assets together with the Windows desktop app.

## LamaTeam CS:S server

- Website: https://lamateam.eu
- Connect page: https://lamateam.eu/connect
- Discord: https://dsc.gg/lamateam
- Server: `82.208.17.101:27516`
- Steam link: `steam://connect/82.208.17.101:27516`
- Console command: `connect 82.208.17.101:27516`

The Modern PC profile installs the current `autoexec.cfg` only. The optional LamaTeam connection adds the `lama` console alias and game-menu entry; both destinations and backups are shown before applying.

## Windows setup

Run in an interactive PowerShell session:

```powershell
irm lamateam.eu/setup | iex
```

For a local checkout on a WSL network path, run `pwsh -ExecutionPolicy Bypass -NoProfile -File .\setup.ps1`. This Bypass applies only to that PowerShell process; it does not change machine or user policy. The release bootstrap uses the same child-process-only setting after verifying its launcher and app files.

The graphical app uses **WinUIShell 0.14.0** and requires **PowerShell 7.4 or later** on Windows 10 build 17763+ or Windows 11. If launched from Windows PowerShell 5.1 and PowerShell 7 is missing, setup offers to install Microsoft PowerShell 7.4.22.0 using WinGet and then continues with the commit-pinned app launcher downloaded and verified before it is run. The app requests administrator access through Windows UAC before opening. The PowerShell MSI is machine-wide and may also require administrator approval. If WinGet is unavailable, setup explains how to install PowerShell from Microsoft: https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows.

Setup separately asks before installing the pinned WinUIShell module from PowerShell Gallery for the current user. WinUIShell is MIT-licensed and currently marked as a prototype; its APIs may change. The installer verifies fetched app files against the GitHub commit tree before loading them.

The app detects CS:S automatically; paste a game folder path to use a different install. It offers independent, explicit actions:

- **Modern PC or Legacy config:** inspect the selected config before installation; existing target files are backed up before replacement. Legacy is an exact historical CS:S preset and is not a promise of compatibility with current hardware or every server.
- **Steam launch options:** current options are preserved, updates are backed up, and Steam is left running. If Steam has cached the old options, it may need a restart before the game uses the change.
- **Game validation:** validation starts in Steam and is a separate step; after it finishes, click **Apply and play** again to launch and connect.
- **LamaTeam connect entry:** opt in separately; the app shows the file and backup path first.
- **Missing maps:** scan first, then download only missing/invalid maps from `https://fastdl.lamateam.eu/maps/`. FastDL serves compressed `.bsp.bz2` files; a locally installed bzip2-capable extractor is required. The app does not download or bundle an extractor. It validates the decompressed BSP before marking it installed.
- **Gaming cleanup:** inspect apps, services, and scheduled tasks with context; nothing is preselected. Process close requests are graceful only, cannot be restored, and may not close the app. Service/task changes are journaled for retryable restoration.
- **Intro video:** optional opt-in conversion from `hl2\media\valve.bik` to `hl2\media\valve.webm`. FFmpeg must already be installed; no executable is downloaded, the source is preserved, and an existing output is not silently overwritten.
- **Config editor:** edit the selected config with syntax highlighting, Ctrl+Z undo, and immediate saves to the detected game’s `cstrike\cfg\autoexec.cfg`. The original file is backed up before the first edit.

The app is for CS:S players. LamaTeam connection and maps are optional; it does not promise generic FPS or hit-registration improvements. Clickable **muso.sk** branding stays secondary to setup.

## Manual config files

- `autoexec.cfg` — modern CS:S configuration. Install to `cstrike\cfg\autoexec.cfg` and run `exec autoexec` in the CS:S console.
- `gamemenu.res` — LamaTeam menu entry. Install to `cstrike\custom\lamateam\resource\GameMenu.res`.
- The app’s Legacy option is sourced from the repository’s historical 2016 `autoexec.cfg` revision; the retired `config.cfg` containing `unbindall` is not installed.

The app creates timestamped backups in the displayed backup folder. Review the preview and personal settings before replacing an existing config.

## Development checks

```powershell
pwsh -NoProfile -File core/tests/Invoke-CoreTests.ps1
pwsh -NoProfile -File core/tests/Invoke-ProcessTests.ps1
pwsh -NoProfile -File core/tests/Invoke-ContractTests.ps1
python -B -m unittest discover -s core/tests
python -B tests/test_bootstrap_static.py
```

The tests use temporary files and fake network/system adapters; they do not stop real processes or change Windows state. WinUIShell GUI, WinGet/UAC installation, Windows service/task actions, real FFmpeg conversion, and end-to-end public setup still require Windows validation. The public `lamateam.eu/setup` endpoint must serve the updated `main` branch before this branch’s app is available through that URL.

## Community

- LamaTeam: https://lamateam.eu
- Connect: https://lamateam.eu/connect
- Discord: https://dsc.gg/lamateam
- Creator: [muso.sk](https://muso.sk)
