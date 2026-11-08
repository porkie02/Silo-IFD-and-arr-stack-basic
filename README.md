# PoE Leveling HUD

A small always-on-top overlay that guides you through the Path of Exile campaign.
It reads only the game's `Client.txt` log file. It never reads game memory and
never sends input to the game.

## Setup (Windows)
1. Install Python 3.10+ from python.org and tick **"Add python.exe to PATH"**.
   Tkinter comes with it.
2. Optional, for global hotkeys: `pip install pynput`
3. Put `leveling_hud.py` and `route.json` in the same folder.
4. Run it: `python leveling_hud.py`
   (or rename it to `leveling_hud.pyw` to run it without a console window).
5. Set PoE to **Windowed Fullscreen** (Options → Graphics). The overlay can't
   draw over exclusive fullscreen.

On first run it looks for `Client.txt` in the usual install folders. If it
can't find it, it asks you to pick it from `Path of Exile\logs\`.

## Auto-sync
The HUD works out where you are from the log, so you don't have to set it by hand:
- **On start-up** it scans the recent log and jumps to the step for your last zone.
- **On login** (game restart or reconnect) it syncs on the first zone you enter.
- **If you turn up in a different act** (e.g. you played without the HUD), it
  uses the zone name plus area level to find the right step. That is how it
  tells The Coast in Act 1 from The Coast in Act 6.
- **Per character:** progress is saved per character name (picked up from
  level-up lines), and switching characters restores their step.
- **⟳ button / right-click → Resync / Ctrl+Alt+S** forces a resync to your
  current zone.
Hideouts and other zones that aren't on the route are ignored.

## Using it
- The step advances automatically when you enter the zone it's waiting for.
  Town steps only advance when they are the very next step, so portalling
  to town mid-zone won't skip ahead.
- **◀ / ▶** or the mouse wheel step back and forward manually.
- Drag the header bar to move the HUD.
- **Right-click** opens the menu: jump to an act, opacity, choose the log file,
  reset progress.
- Hotkeys (with pynput): Ctrl+Alt+→ next, Ctrl+Alt+← previous, Ctrl+Alt+H hide/show, Ctrl+Alt+S resync.
- The status line shows your level against the area level, and turns
  amber or red when you're outside the XP safe range.
- Progress, position and opacity are saved in `hud_state.json`.

## Editing the route
`route.json` holds a list of acts, and each act holds a list of steps:
```json
{ "zone": "The Coast", "do": "Take the waypoint.", "tip": "optional hint", "strict": false }
```
`zone` must match the game's "You have entered X." text exactly. Use `null` for
steps you tick off by hand. The included route covers Acts 1–2.
