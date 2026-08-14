# Changelog

## 1.3.0 — 2026-08-14

- **Ready for 12.1.**
- **The HUD moves.** Unlock it, drag it anywhere, lock it again. A button puts it
  back in the middle. Your corner minimap is never touched.
- **Blip size slider.** Bigger dots, same circle, same hundred yards.
- **Step aside while I'm fighting** — the HUD drops when a fight starts and comes
  back when it ends. Off by default. The corner map stays.
- **The corner map is framed** like your minimap, with sliders for the frame and for
  how much of the corner the map fills.
- **Corner map opacity**, so it can sit quietly behind the rest of your UI.
- **`/eu` is eight commands now**, all of them the HUD: `on`, `off`, `size`, `move`,
  `lock`, `centre`, `blips`, `status`. Everything else lives under `/eu more`. The old
  spellings still work.
- The options page is much shorter.
- Fixed: the corner map was see-through.
- Fixed: your position arrow was hidden behind the corner map.
- Fixed: changing the shared-settings tickbox during a fight could lose settings you
  changed afterwards.

## 1.2.6 — 2026-08-09

- Eyes Up has its own icon in the AddOns list now, instead of a borrowed herb.
- Quieter at login: the note about the 12.1 map change is gone. It only ever had one
  thing to say and it has said it.

## 1.2.5 — 2026-08-08

- **Ready for 12.1.** The HUD hides the map a different way now — the old way stops
  working on the new client and would have left you looking at an empty screen.
  Nothing to do: it looks the same, and your settings come across on first login.
- **The corner map is round.** It sits in a round hole, so it may as well match it.
  Untick *Round off the corner map* in the options, or `/eu hud shape square`, if you
  preferred the square one.
- The corner map is brighter — there was a dark disc behind it, left over from when
  there was nothing in that corner to look at.
- Options: *Blip opacity* is now *Map opacity*, which is what it has always actually
  done. *Soft edge* is gone — it can't work on the new client.
