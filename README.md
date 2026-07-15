# Eyes Up

*Watch the world, not the minimap.*

You know the moment. You're cruising over a ridgeline, enjoying the view, and
somewhere behind you — a long way behind you now — was a herb you'd have happily
stopped for. You didn't see it, because seeing it would have meant staring at a
little circle in the corner of your screen instead of at the game.

**Eyes Up** fixes that in the most direct way possible: it takes your minimap's
own tracking blips and puts them in front of you, where you're already looking.

For WoW retail (Midnight, 12.0.7+). No libraries, no dependencies, nothing to set
up.

## Install

Drop the folder into your AddOns directory. It **must** be named `EyesUp`:

```
World of Warcraft/_retail_/Interface/AddOns/EyesUp
```

WoW matches the folder name against `EyesUp.toc`. Call it anything else and the
game quietly pretends the addon doesn't exist. Then restart the client.

## The HUD — the main event

Turn on the **heads-up display** (in `/eu`, or `/eu hud on`) and your minimap
moves to the middle of your screen, the map itself is masked away, and what's left
is the tracking blips — herbs, ore, fish — floating over the actual world, rotated
so **up is the way you're facing.** A blip above your character is a node straight
ahead.

Here's the important part: **these aren't our markers, they're the game's.**
Live, exact, at the full range of your tracking (~100 yards). Eyes Up isn't
guessing where the herbs are — it's showing you the tracking WoW already draws,
just not in the corner.

A few things worth knowing:

- **You choose what shows.** The options page lists every minimap tracking type.
  Gathering (herbs, minerals, lumber, fish, treasure) is on; everything else —
  mailboxes, auctioneers, quest markers — is folded away and off. While the HUD is
  up, these choices **override** your normal minimap tracking, then hand it back
  when the HUD comes down.
- **A real map goes in the corner.** There's only one minimap, so while the HUD is
  up your corner map is gone — but tick **Map in the corner** and a live map
  (roads, your position) takes its place so you never lose your bearings.
- **It steps aside in cities.** You're not gathering in town, and hubs are full of
  service and quest icons the game won't let us hide, so the HUD folds away while
  you're resting and returns when you ride out.
- **A keybind**, for the busy camps that *aren't* flagged as cities: bind "Toggle
  the heads-up display" under Escape → Keybindings → **Eyes Up Add On**, and flick
  it off for a moment when you drop into a cluttered spot.

Size, zoom, rotation, opacity, and blip tooltips are all right there on the page —
no digging.

## The cue — the original, still here

Prefer something lighter, or want it *as well* as the HUD? The **cue** is a small
icon near the middle of your screen that fades in when a node you want is within
reach, with an arrow at it, and fades to nothing when there isn't one. It doesn't
touch your minimap, so you can run either, or both.

The cue is careful about what it claims:

- **It doesn't lie.** By default it only fires for nodes the game *confirms* are
  really there — so if it lights up, the thing is there. The catch is reach:
  about 15–25 yards, because that's as far as the game will confirm a node.
- **It shows the right icon.** Pick from a dropdown: the item the node gives (the
  ore, the herb — looked up from the node's own name), the plain profession
  symbol, or your own art from `textures/`. Fishing always shows a fishing icon,
  since pools give a grab-bag of fish.
- **Optional name tag.** Turn it on and the node's name floats above the icon —
  handy for fishing pools especially.
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

## Settings: per character, or shared

By default each character keeps its own settings and gathered nodes. Tick **Share
settings across all my characters** on the HUD page and every character reads and
writes one shared set instead — your current settings are copied across first, so
nothing is lost, then it reloads. Flip it back any time.

## One setting it changes for you

Eyes Up turns on WoW's **soft targeting** when you log in, and puts your old
setting back when you log out. It has to — that's the setting that lets the cue
ask *"what could I grab right now?"*, and it's what lets the HUD's tracking do its
thing. `/eu softtarget off` if you'd rather manage it yourself.

## Commands & keybinds

Almost everything lives in the options (`/eu`). The handy slash commands:

| | |
|---|---|
| `/eu` | open the options |
| `/eu hud on\|off` | the heads-up display |
| `/eu guesses on\|off` | also point at nodes that might not be there |
| `/eu status` | why isn't it firing? |
| `/eu toggle` | eyes up / eyes closed |
| `/eu lock` / `/eu unlock` | drag the cue, then pin it |

`/eyesup` and `/ns` both work too. `/eu` with no argument lists the rest.

Under **Escape → Keybindings → Eyes Up Add On** you can bind *Toggle the heads-up
display* and *Toggle the addon* to keys.

## What it can't do

Two hard limits, both the game's, not ours:

- **The cue can't see far.** ~15–25 yards for herbs, ore and lumber — that's as
  far as the game will confirm a node is really there. (The *HUD* reaches your
  full ~100-yard tracking range, because it's showing the game's own blips.)
- **A chair can hide a herb** from the cue. The game only tells us about *one*
  nearby thing — the best one — so a chest or a door or your own fishing bobber,
  if it's closer, is what we hear about.

And on the HUD, service and quest POIs in hubs (mailboxes, quartermasters, quest
givers) are drawn by the game engine and can't be hidden by any addon — which is
what the city auto-hide and the toggle keybind are for.

Treasures are the exception to the range limit: they come from the game's own map
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
| `Bindings.xml` | the keybind definitions (auto-loaded, never in the .toc) |

The cue and radar share one engine: `Scan` looks around once per tick and hands
the answer to whichever renderer is on. The HUD is different — it doesn't draw
anything itself, it relocates the game's own minimap. Adding a new way to show
what `Scan` finds means writing a renderer, not touching the engine.
