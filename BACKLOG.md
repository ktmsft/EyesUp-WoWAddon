# Backlog

Dev notes. Never shipped — `tools/build.ps1` works off an *exclude* list, so this file
is named there. Anything new in the repo root ships by default; remember that when
adding another dev-only doc.

---

## 1. 12.1 breaks the mask trick — FIXED in 1.2.5

**Status: done.** Found and fixed on the 12.1 PTR, August 2026; the fix is verified on
live (12.0.7) too, so there is one code path and no version branch. Kept here because
the measurements are the reason the settings look the way they do.

The whole HUD rests on one claim, written up at the top of `Hud.lua`: the minimap's
mask shapes the *terrain* through its alpha channel and does **not** touch the
tracking blips, because the blips aren't part of the Lua render. Point a fully
transparent mask at the minimap and the terrain vanishes while every blip stays.

That stopped being true in 12.1. The mask now reaches the blip layer.

### Measured

Flat 64×64 BGRA masks, one alpha value each, HUD otherwise untouched:

| mask | alpha | terrain | blips |
|---|---|---|---|
| `MASK_CLEAR` | 0 | gone | **gone** |
| `MASK_GHOST` | 1 | gone | **gone** |
| `MASK_DIM` | 64 | gone | **gone** |
| `ROUND_MASK` (Blizzard's) | 255 in a disc, 0 outside | full | **fine, correctly placed** |

Not a multiply — 64/255 is 25% and would have shown *something*. It behaves like a
**threshold**, with the cutoff somewhere in (64, 255].

The texture sweep is exonerated: `hideLuaTextures` was running normally under the
round mask and the blips came through. This is the mask alone.

### The way out — CONFIRMED on the PTR

**`Minimap:SetAlpha` is a separate path from the mask, and only the mask gained the
blip gate.** Round mask + `/eu hud alpha 0.1`: terrain drops to a faint wash, blips
stay at **full** strength. Verified in-client. So the HUD survives, with the two jobs
swapped over:

|  | was (≤ 12.0.7) | now (12.1) |
|---|---|---|
| shape the blips pass through | any mask, incl. fully clear | **opaque** mask — `round` |
| kill the terrain | mask alpha 0 | **frame alpha** (`hudAlpha`) |

Consequence: the visible area becomes the mask's disc rather than the full square.
That's what a minimap is anyway, so no real loss.

`MASK_VIGNETTE` (145 centre) is no longer needed to bracket the threshold — worth one
run only if we ever want the exact cutoff.

### What shipped

Frame alpha behaves identically on 12.0.7 and 12.1, so no `GetBuildInfo` branch was
needed — one code path, both clients.

- `hudMask` default `"clear"` → **`"round"`**. Opaque, so every blip inside it draws.
- `hudAlpha` default `1.0` → **`0.01`**. The map is gone at that value and the blips
  are untouched. Not 0: a frame at alpha 0 may not be drawn at all, blips included,
  and a slider whose end position silently disables the addon is not shippable.
- **One-time migration** (`db.maskGatesBlipsMigrated`, `Core.lua`). Every existing
  install has `hudMask = "clear"` and `hudAlpha = 1.0` *saved*, and `applyDefaults`
  only fills keys that are missing — so a defaults change alone would have reached
  nobody and they'd have logged into an empty HUD. Only the transparent masks are
  rewritten, and `hudAlpha` is only ever lowered, so a deliberate choice survives.
  Says so in chat once.
- Options: "Blip opacity" (0.2–1) → **"Map opacity (0.01 = blips only)"** (0.01–1).
  The old label described the opposite of what the dial now does.
- Options: **removed** "Soft edge (fade at the rim)". It flipped `hudMask` between
  `vignette` and `clear`; under a binary gate a fading rim can only be a hard cut,
  and `clear` blanks the HUD. One broken position and one catastrophic one.
- Rewrote the top-of-file essay in `Hud.lua`, which asserted the old behaviour as
  fact and was the first thing anyone read.

The transparent masks stay reachable from `/eu hud mask` — they're the diagnostic
ladder, and they are exactly what a broken HUD looks like, which is the point.

### Diagnostics added while chasing this

Keep them; they're cheap and this class of breakage will recur.

- `/eu hud track` — every tracking type, what the client said, what we decided.
- `/eu hud mask clear|ghost|dim|vignette|round` — `round` is the control case.
- `/eu hud sweep on|off` — proves `hideLuaTextures` innocent or guilty.
- `/eu hud alpha <0-1>` — frame alpha, independent of the mask.
- `applyTracking` now refuses to switch off a type it cannot identify. If
  `GetTrackingInfo` changes shape a third time, the failure is clutter rather than
  every blip silently disappearing.

---

## 2. Shape the corner map — DONE in 1.2.5

Shipped as `cornerShape` (`"circle"` default, `"square"`), the "Round off the corner
map" checkbox, and `/eu hud shape round|square`. The route below is the one taken;
kept because the *reason* it isn't a one-liner is the part worth remembering.

Two things that turned out to be load-bearing and weren't obvious up front:

- **`CLAMPTOBLACKADDITIVE` on both axes.** Tiles extend past the frame while the
  canvas is panned. Without clamping, everything outside the mask's own rectangle
  stays *unmasked* — the map keeps its corners and spills over the tray, which looks
  like the mask silently did nothing.
- **`clearShape()` before handing the window back.** The tiles are pooled and reused,
  so masks left on them outlive us — the real Battlefield Map would open as a circle
  for the rest of the session.

Not covered: only two shapes, because `MASK_ROUND` is the only shape art in the repo.
`MASK_VIGNETTE` would give a genuinely soft rim here (a MaskTexture on a normal
texture fades properly — that's unrelated to the blip gate in item 1), if that's ever
wanted.

### Original notes

**Wanted:** the replacement map in the corner is a hard square. The hole it sits in
is round (the tray's `disc` is masked with `MASK_ROUND`), so a square map in a round
hole looks like a placeholder. Offer a shape — circle, rounded square, square — as a
setting.

### What's actually there

Verified from `Corner.lua`:

- The map is `BattlefieldMapFrame`, a **MapCanvas**, reparented to `EyesUpMinimapTray`
  and sized to it. We already strip its data providers, draw our own player arrow,
  and hide its window furniture.
- Masking is a **Texture** method. `BattlefieldMapFrame` is a Frame, so
  `SetMaskTexture` is not available on it — this is not the one-liner it is for the
  Minimap.

### The likely route

`MaskTexture` regions apply to *textures*, and a single mask can be added to many:
create one with `CreateMaskTexture()` on the tray, then `AddMaskTexture(mask)` on
each terrain texture inside `ScrollContainer.Child`.

Assumed, needs a live client:

- that the canvas's terrain tiles are reachable and enumerable from Lua;
- that `AddMaskTexture` behaves on them (they're pooled and re-laid-out on pan and
  zone change, so this almost certainly needs re-applying — a patrol, like
  `Hud.ParkButtons`, rather than a one-shot at Enable);
- how the two providers we kept (map exploration, fog of war) paint, and whether
  they need masking separately.

`SetClipsChildren` is the cheap alternative and gives a **rectangle only** — good
enough for "square/rounded square", useless for a circle.

### Notes

- `MASK_ROUND.tga` already exists and is already the shape of the hole, so a circle
  costs no new art.
- Do this **after** item 1. If 12.1 has changed how masks composite, it may well have
  changed this too, and the answer found there decides whether this is worth starting.
- Config key would be `cornerShape` alongside `cornerZoom` / `cornerAlpha`, with the
  options page dropdown next to the existing corner controls.
