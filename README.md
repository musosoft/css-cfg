# LamaTeam Counter-Strike: Source Setup Tool, Config, Maps, and Gaming Mode Pro

LamaTeam provides a complete **Counter-Strike: Source setup utility** for players who want the fastest way to join the **LamaTeam CS:S server** with the correct config, menu shortcut, custom maps, and performance tuning already in place. If you are searching for a **CS:S autoexec download**, **Counter-Strike: Source map pack**, **CS:S server IP**, **Counter-Strike Source setup tool**, **Counter-Strike Source optimizer**, **CSS FPS boost**, or a **gaming mode tool for CS:S**, this repository is built for that exact use case.

This repository includes:

- an optimized `autoexec.cfg`
- a `GameMenu.res` shortcut for direct server join
- a Windows installer that detects your CS:S folder and downloads missing maps
- a desktop **Gaming Mode Pro** tool with a modern tabbed UI, saved selections, and reversible performance tweaks

The goal is simple: help new and returning players install the right files quickly, reduce failed joins caused by missing maps, and make it easier to reconnect to the LamaTeam server.

## LamaTeam CS:S Server IP and Quick Connect

- Website: [https://lamateam.eu](https://lamateam.eu)
- Connect page: [https://lamateam.eu/connect](https://lamateam.eu/connect)
- Discord: [https://dsc.gg/lamateam](https://dsc.gg/lamateam)
- Direct server IP: `82.208.17.101:27516`
- Steam connect link: `steam://connect/82.208.17.101:27516`
- In-game console command: `connect 82.208.17.101:27516`

After installing the config, you can also use the console alias:

```cfg
lama
```

## One-Command Windows Setup

Open **PowerShell as Administrator** and run:

```powershell
irm lamateam.eu/setup | iex
```

The installer will:

1. detect your Counter-Strike: Source install automatically
2. install the LamaTeam `autoexec.cfg`
3. add the LamaTeam server shortcut to the CS:S main menu
4. download missing LamaTeam maps from fastDL
5. optionally place the Gaming Mode tool on your desktop

This makes it a practical **Counter-Strike: Source installer**, **CS:S config installer**, and **CS:S map downloader** in one pass.

If your goal is faster join time and fewer failed connects, this is the recommended path for all LamaTeam players.

When the installer finishes, start CS:S and run:

```cfg
exec autoexec
```

If the game was already open, reconnect or restart the game client once.

## Gaming Mode Pro for Counter-Strike: Source

The integrated **Gaming Mode** in this installer is a **Windows gaming cleanup and optimization tool for CS:S**. It is designed to free resources before joining the LamaTeam server without blindly killing essential system processes.

Current Gaming Mode features:

- scans background apps, stoppable third-party services, and third-party scheduled tasks
- lets you add your own protected process names (internal list covers `discord`, `obs`, `teams`, etc.)
- offers a **Select Recommended** option to quickly mark known non-essential apps for closure
- stores previous system state so you can restore it after the session
- applies power plan, network profile, Xbox Game DVR, and DNS cache optimization toggles
- supports automatic connect to `82.208.17.101:27516` after optimization
- includes a modern icon-based tabbed interface with persistent checkbox selections

If you only need the Gaming Mode, use the main installer above or run the **Gaming Mode** shortcut created on your desktop after setup.

## Why Players Join Faster with This Tool

- Faster first join to the LamaTeam Counter-Strike: Source server
- Fewer disconnects caused by missing custom maps
- A direct CS:S menu shortcut and console alias for repeat joins
- A cleaner pre-game Windows session with reversible tweaks and restore support
- One PowerShell setup path for config, menu, maps, and desktop tooling
- Better conversion from fresh install to in-server play in minutes

## Manual Installation

If you do not want to use the installer, copy the files manually.

### `autoexec.cfg`

1. Download [`autoexec.cfg`](https://raw.githubusercontent.com/musosoft/css-cfg/main/autoexec.cfg)
2. Place it in:

```text
C:\Program Files (x86)\Steam\steamapps\common\Counter-Strike Source\cstrike\cfg
```

3. Run `exec autoexec` in the CS:S console

### `GameMenu.res`

1. Download [`gamemenu.res`](https://raw.githubusercontent.com/musosoft/css-cfg/main/gamemenu.res)
2. Place it in:

```text
C:\Program Files (x86)\Steam\steamapps\common\Counter-Strike Source\cstrike\custom\lamateam\resource
```

### Gaming Mode

1. Run the installer as Administrator.
2. Select **Create a Gaming Mode shortcut on the desktop**.
3. Use the desktop shortcut to launch the tool before gaming.

## Why Use This LamaTeam CS:S Pack

- Faster onboarding for new players joining the LamaTeam Counter-Strike: Source server
- Automatic delivery of missing maps before you connect
- A direct menu shortcut and console alias for faster reconnects
- A practical Windows cleanup tool focused on gaming sessions, not generic “optimizer” nonsense
- Backups of replaced files during setup so you can roll back if needed

## Community

- Website: [https://lamateam.eu](https://lamateam.eu)
- Connect: [https://lamateam.eu/connect](https://lamateam.eu/connect)
- Discord: [https://dsc.gg/lamateam](https://dsc.gg/lamateam)

For players searching terms like **Counter-Strike Source server config**, **CS:S public server connect**, **CS:S setup utility**, **download CS:S custom maps**, **LamaTeam autoexec**, **gaming mode for Counter-Strike: Source**, or **how to join LamaTeam CS:S**, this repository is the official install point.

Ready to join now:

- Run `irm lamateam.eu/setup | iex`
- Launch `LamaTeam-GamingMode` from your desktop
- Click **Select Recommended** on the Kill tab
- Click **Close Selected**
- Switch to **Tweaks** tab and click **Apply Gaming Mode**
- Launch CS:S and join `82.208.17.101:27516`
