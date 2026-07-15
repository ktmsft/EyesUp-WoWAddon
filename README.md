Find it on Curseforge: https://www.curseforge.com/wow/addons/eyes-up/

# Eyes Up

*Watch the world, not the minimap.*

You know the moment. You're cruising over a ridgeline, enjoying the view, and
somewhere behind you — a long way behind you now — was a herb you'd have happily
stopped for. You didn't see it, because seeing it would have meant staring at a
little circle in the corner of your screen instead of at the game.

**Eyes Up** puts a small icon near the middle of your screen when there's
something worth stopping for, with an arrow pointing at it. When there isn't,
there's nothing on screen at all.

For WoW retail (Midnight, 12.0.7+). No libraries, no dependencies, nothing to set
up.

## Install

Drop the folder into your AddOns directory. It **must** be named `EyesUp`:

## The HUD — the main event

Turn on the **heads-up display** (in `/eu`, or `/eu hud on`) and your minimap
moves to the middle of your screen, the map itself is masked away, and what's left
is the tracking blips — herbs, ore, fish — floating over the actual world, rotated
so **up is the way you're facing.** A blip above your character is a node straight
ahead.

The one cost: there's only one minimap, so while the HUD is up, your corner map is
gone. Tick **Map in the corner** and a real map (roads, your position) takes its
place, so you don't lose your bearings. The HUD also folds away in cities — you're
not gathering there, and towns are full of mailboxes and quest markers the game
won't let us hide.

Everything about it is on the options page: what to track (herbs / minerals / fish
/ treasure), size, zoom, rotation, opacity — no digging.

## The cue — the original, still here

Prefer something lighter, or want it *as well* as the HUD? The **cue** is a small
icon near the middle of your screen that fades in when a node you want is within
reach, with an arrow at it, and fades to nothing when there isn't one. It doesn't
touch your minimap, so you can run either, or both.

The cue is careful about what it claims:

- **It doesn't lie.** By default it only fires for nodes the game *confirms* are
  really there — so if it lights up, the thing is there. The catch is reach:
  about 15–25 yards, because that's as far as the game will confirm a node.
- **It shows the real item** once you've gathered one of that species; a generic
  glyph (or your own art from `textures/`) until then.
- **It shuts up about things you just took**, instead of spinning round to point
  at the hole you're standing over.
- **A quiet tick**, if you want one — off by default, and never for something it
  isn't sure about.

  ## Want more warning? (guesses)

Tick **Show guesses** (or `/eu guesses on`) and the cue also points at places a
node has *been* before, out to your full range.

Be warned: **most of those won't be there.** A zone has thousands of spawn spots
and only a handful are occupied at once. Guesses draw faint and never make a
sound, so at least they look like guesses.

This works far better with **GatherMate2_Data** installed (free, on CurseForge) —
a big list of everywhere nodes have been seen, so guesses work even in a zone
you've never farmed. Eyes Up reads it if it's there and shrugs if it isn't.
Nothing is bundled, and nothing is required.

## Filters

Every gathering node in the game is in the filter list (on the **Cue & filters**
page), organised as a tree: by **type** (Herbs, Mining, Lumber, Fishing,
Treasure), and inside each, by **expansion**. Drill into *Herbs → Midnight* and
untick the one weed you keep grabbing by accident. Species are named by what you
*see* in the world ("Copper Vein"), not what they drop ("Copper Ore").

## One setting it changes for you

Eyes Up turns on WoW's **soft targeting** when you log in, and puts your old
setting back when you log out. It has to — that's the setting that lets the cue
ask *"what could I grab right now?"*, and it's what lets the HUD's tracking do its
thing. `/eu softtarget off` if you'd rather manage it yourself.

## Commands

Almost everything lives in the options (`/eu`). The handy ones:

| | |
|---|---|
| `/eu` | open the options |
| `/eu hud on\|off` | the heads-up display |
| `/eu guesses on\|off` | also point at nodes that might not be there |
| `/eu status` | why isn't it firing? |
| `/eu toggle` | eyes up / eyes closed |
| `/eu lock` / `/eu unlock` | drag the cue, then pin it |

`/eyesup` and `/ns` both work too. `/eu` with no argument lists the rest.

## What it can't do

Two hard limits, both the game's, not ours:

- **The cue can't see far.** ~15–25 yards for herbs, ore and lumber — that's as
  far as the game will confirm a node is really there. (The *HUD* reaches your
  full ~100-yard tracking range, because it's showing the game's own blips.)
- **A chair can hide a herb** from the cue. The game only tells us about *one*
  nearby thing — the best one — so a chest or a door or your own fishing bobber,
  if it's closer, is what we hear about.

Treasures are the exception to the first: they come from the game's own map
markers, so the cue sees those at full range and always knows they're real.

## Under the hood

| file | what it's for |
|---|---|
| `Constants.lua` | every number and magic string the addon believes in |
| `Species.lua` | every gathering node in the game (generated) |
| `Database.lua` | what we remember; how far; which way |
| `Seed.lua` | GatherMate's node list, if you have it (optional) |
| `Live.lua` | the only thing that can say "yes, it's really there" |
| `Vignettes.lua` | treasures — the game shows us these directly |
| `Hud.lua` | the heads-up display: your minimap's blips, moved to your eye |
| `Corner.lua` | a real map where the minimap used to be |
| `Cue.lua` | the cue — an icon and an arrow near screen centre |
| `Overlay.lua` | the old radar, still here if you want it (`/eu mode radar`) |
| `Scan.lua` | the engine: one look around per tick |
| `Options.lua` | the knobs (two pages: HUD, and Cue & filters) |
| `Probe.lua` | diagnostics; delete it and nothing changes |
| `Core.lua` | wakes everything up |

The cue and radar share one engine: `Scan` looks around once per tick and hands
the answer to whichever renderer is on. The HUD is different — it doesn't draw
anything itself, it relocates the game's own minimap. Adding a new way to show
what `Scan` finds means writing a renderer, not touching the engine.
