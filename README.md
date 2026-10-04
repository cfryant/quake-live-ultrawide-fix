# Quake Live Ultrawide Fix

True 21:9 and 32:9 (anything wider than 16:9) for **Quake Live on Steam**, with no horizontal stretching, applied to a **separate offline copy** of the game.

---

## ⚠️ Read this first: VAC / anti-cheat warning

- **What this changes:** the installer makes a **separate copy** of your Quake Live install and modifies **one game file in that copy**: `cgamex86.dll` inside `baseq3\bin.pk3`. Exactly 4 bytes change. There is **no memory patching, no DLL injection and no background process**.
- **Your original Steam install is never modified.** The script only reads it.
- **Valve treats modified game files as cheating.** Quake Live uses Valve Anti-Cheat (VAC). Running the patched copy while Steam is **online**, or trying to join servers with it, **could get you a VAC ban**. A VAC ban is **permanent** for Quake Live, and Valve may extend it to other games on the same engine. It does **not** delete your Steam account.
- Pure online servers should refuse the modified copy anyway, because its binaries no longer match. Don't rely on that.
- **Use it for offline/local play only, with Steam in Offline Mode** (Steam menu → *Go Offline…*). Never launch the patched copy while Steam is online.
- **Use at your own risk.** No warranty (see [LICENSE](LICENSE)).

---

## The problem

Quake Live only widens its horizontal field of view up to **16:9**. At wider resolutions (2560×1080, 3440×1440, 5120×1440, …) it renders a 16:9 view and **stretches it sideways** to fill the screen. At 3440×1440 everything is about 1.34× too wide. At 32:9 it's 2×. Players have reported this on the Steam forums, ESR and Reddit for years.

Setting `r_mode -1` with `r_customWidth`/`r_customHeight` gets you native resolution, but the image is still stretched.

## Why there's no config / cvar fix

I checked this by disassembling the game binaries (Steam build listed under [Supported game build](#supported-game-build)):

- **Vertical FOV is fixed.** The game logic module (`cgamex86.dll`) works out the vertical FOV from `cg_fov` on a fixed 640×480 (4:3) basis.
- **Horizontal FOV uses one of four presets.** It's computed from the vertical FOV and the aspect preset `r_aspectRatio`, read as an integer: `0` = 4:3, `1` = 16:9, `2` = 16:10, anything else = 5:4. There is no ultrawide preset, and fractions are truncated.
- **The engine resets `r_aspectRatio` itself** on every video restart, setting `1` (16:9) for any mode 16:9 or wider. Values you set in the console or a config don't last.
- **There's no other knob.** The executable has no `r_customPixelAspect`, `cg_fovAspect` or `r_stretch`-style cvar. Raising `cg_fov` changes zoom but not the aspect ratio.
- **Flawless Widescreen has no Quake Live plugin**, and it works by patching memory at runtime anyway.

## How the fix works

The 16:9 preset computes:

```
fov_x = 2 * atan( tan(fov_y / 2) * 16 / 9 )
```

The `9.0` is stored once in `cgamex86.dll` (file offset `0x7246C`) and used only by this code. The installer replaces it with

```
16 * Height / Width        (3440x1440 -> 6.6977, 5120x1440 -> 4.5)
```

so the "16:9" preset now produces the correct horizontal FOV for your resolution. The engine already selects that preset for any ultrawide mode, so no cvar changes are needed for the FOV. The result is proper **Hor+**: the vertical view matches 16:9 players and you see more at the sides.

Diagram (no screenshots yet; this is a schematic, not a capture):

```
16:9 view (what the game renders)        Stock QL on 21:9: same view, stretched
+------------------------+               +-----------------------------------+
|        (  o  )         |               |          (    o    )             |   <- circles become ovals
+------------------------+               +-----------------------------------+

Patched copy on 21:9: same vertical view, more world at the sides, no stretch
+-----------------------------------+
|  ......  (  o  )  ......          |   <- circles stay round
+-----------------------------------+
```

> **Before/after screenshots:** none yet. I'd rather not fake any. Contributions welcome.

## Supported resolutions

Any resolution **wider than 16:9**. The installer refuses 16:9 and narrower because the stock game already handles those correctly.

Horizontal FOV is shown for `cg_fov 100`; stock 16:9 is about 115.7°.

| Resolution | Aspect | Patch value (16·H/W) | Bytes at 0x7246C | Horizontal FOV @ cg_fov 100 | Patched `cgamex86.dll` SHA-256 |
|---|---|---|---|---|---|
| 2560×1080 | 64:27 (≈2.37) | 6.7500 | `00 00 D8 40` | 129.5° | `fcb02358b0b245ff8e3acb780ff1ca4f5384e8c455b25d003268b560c1bf6039` |
| 3440×1440 | 43:18 (≈2.39) | 6.6977 | `59 53 D6 40` | 129.8° | `d5e1f9edf61a32b4f22c2c95b1b16bec60f46323eecf93ae3e6ee818604eb034` |
| 3840×1600 | 12:5 (2.40) | 6.6667 | `55 55 D5 40` | 130.0° | `1ece70c7f9d0cfc6c9688aee65757807b7fe095e5cd6a7afc5a8571a3dc371d4` |
| 5120×2160 | 64:27 (≈2.37) | 6.7500 | `00 00 D8 40` | 129.5° | `fcb02358b0b245ff8e3acb780ff1ca4f5384e8c455b25d003268b560c1bf6039` |
| 3840×1080 | 32:9 (≈3.56) | 4.5000 | `00 00 90 40` | 145.1° | `3020401a4192b87b4ae939153e6bacb212088d49177d8a297250dcd24cb7d82e` |
| 5120×1440 | 32:9 (≈3.56) | 4.5000 | `00 00 90 40` | 145.1° | `3020401a4192b87b4ae939153e6bacb212088d49177d8a297250dcd24cb7d82e` |
| 5760×1080 | 16:3 (≈5.33) | 3.0000 | `00 00 40 40` | 156.3° | `a888d98d895b69b7a0cdfe66c3d0f3775b541fa52599d2e848cac49785d4583e` |

Other resolutions work too. The installer computes the value and prints the expected hash.

## Supported game build

The installer checks the original file before doing anything and **aborts if it doesn't match**:

| File | SHA-256 |
|---|---|
| `cgamex86.dll` (inside `baseq3\bin.pk3`), original | `310542161ae03cc09a2edf7c5933a3cb5e2f13d791f59d5a33a62721bbf39953` |
| expected bytes at offset `0x7246C` | `00 00 10 41` (float 9.0) |

Steam build 1168251 ships this file. The DLL inside `bin.pk3` is dated 2016-06-03.

## Requirements

- Windows 10/11 with **Windows PowerShell 5.1** (built in) or PowerShell 7+. No third-party tools; it uses built-in .NET `System.IO.Compression`.
- Quake Live installed through Steam (app 282440), or a copy of it (`-SourcePath`).
- About 1.1 GB of free space on the destination drive.
- A monitor or resolution wider than 16:9.

## Install

1. Download the latest release zip from this repository's **Releases** page and extract it.
2. Close Quake Live.
3. Open PowerShell in the extracted folder and dry-run first. This checks everything and writes nothing:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\Install-UltrawideFix.ps1 -Destination 'D:\Games\QuakeLive-Ultrawide' -WhatIf
   ```
4. Run it for real:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\Install-UltrawideFix.ps1 -Destination 'D:\Games\QuakeLive-Ultrawide'
   ```
   Options:
   - `-Width 3440 -Height 1440` overrides the primary monitor's resolution, which is otherwise read in physical pixels, DPI-aware.
   - `-SourcePath <folder>` uses a specific install instead of auto-detecting Steam.
   - `-NoShortcut` skips the desktop shortcut.
   - `-Force` skips the confirmation prompt.

The destination must be **outside every Steam library** and must not already contain files.

What the installer does:

1. Finds the Steam install from the registry `SteamPath` and `libraryfolders.vdf`.
2. Verifies the original `cgamex86.dll` and computes the patched hash.
3. Copies the install, then patches and repacks `bin.pk3` **in the copy only**.
4. Deletes the stale unpacked `cgamex86.dll` in each `<steamid>\baseq3` folder of the copy. The game unpacks the patched one on launch.
5. Writes a managed block in `autoexec.cfg` (`r_mode -1`, `r_customWidth/Height`, `r_fullscreen 1`, `vid_xpos/vid_ypos 0`, `sv_pure 0`), keeping any lines you already had.
6. Writes a small `ultrawide-fix.json` marker and creates the desktop shortcut **"Quake Live (Ultrawide, Offline)"**.
7. Prints all hashes and confirms the source `bin.pk3` is unchanged.

## Test

1. **Switch Steam to Offline Mode first:** Steam menu → *Go Offline…* → *Restart in Offline Mode*.
2. Start **"Quake Live (Ultrawide, Offline)"** from the desktop.
3. Play → *Start a Match* → match type **Offline**. Or open the console and run `/map campgrounds ffa`, then `/addbot keel 3`.
4. Check:
   - The game fills the screen at your native resolution.
   - Round things (rocket explosion rings, item spheres) look **round**, not oval.
   - You see more at the sides than before.
   - In the console, `r_aspectRatio` should read `1` (expected; the patched preset is the one in use).

## Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File .\Uninstall-UltrawideFix.ps1 -Destination 'D:\Games\QuakeLive-Ultrawide'
```

It asks for confirmation, deletes the copy and removes the shortcut, but only if the shortcut points into that folder.

It refuses folders without the `ultrawide-fix.json` marker and anything inside a Steam library. The Steam install is never touched. A copy made by hand, without the installer, can simply be deleted in Explorer.

## Limitations

- **Only the 3D view is fixed.** Menus are laid out on a 4:3 canvas and stay stretched. Some HUD elements may also stay stretched.
- At 32:9 and wider, the horizontal FOV becomes very wide (145°+ at `cg_fov 100`). Lower `cg_fov` if it feels too fisheye.
- **Game updates:** Steam updates never touch the copy, so the copy stays as it was. If a future game update changes `cgamex86.dll`, re-running the installer on the new version **refuses** with an "unsupported game version" message until the offset is re-verified.
- Offline and local play only (see the warning at the top).

## Contents

| File | Purpose |
|---|---|
| `Install-UltrawideFix.ps1` | Creates the patched offline copy (supports `-WhatIf`) |
| `Uninstall-UltrawideFix.ps1` | Removes the copy and its shortcut (supports `-WhatIf`) |
| `docs/index.html` | Single-page explainer |

**No game files are included in this repository or its releases.** The scripts patch a copy of your own install locally. `.gitignore` blocks `*.pk3`, `*.dll` and `*.exe`.

## License

[MIT](LICENSE) © 2026 Christopher Fryant. Quake Live is a trademark of its respective owner; this project is unofficial and not affiliated with id Software, Bethesda or Valve.
