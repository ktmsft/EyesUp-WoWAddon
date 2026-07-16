# Eyes Up

*Watch the world, not the minimap.*

You're cruising over a ridgeline, enjoying the view, and somewhere behind you was a
herb you'd have happily stopped for. You didn't see it — because seeing it would
have meant staring at a little circle in the corner instead of at the game.

**Eyes Up** takes your minimap's own tracking blips and puts them in front of you,
where you're already looking.

For WoW retail (Midnight, 12.0.7+). No libraries, no dependencies, nothing to set up.

## Install

Drop the folder into your AddOns directory. It **must** be named `EyesUp`:

```
World of Warcraft/_retail_/Interface/AddOns/EyesUp
```

WoW matches the folder name against `EyesUp.toc` — call it anything else and the
game quietly pretends the addon doesn't exist. Restart the client afterward.

## The HUD — the main event

Turn on the **heads-up display** (`/eu hud on`) and your minimap moves to the middle
of your screen, the map is masked away, and what's left is the tracking blips —
herbs, ore, fish — floating over the world, rotated so **up is the way you're
facing.** A blip above your character is a node straight ahead.

The important part: **these aren't our markers, they're the game's** — live, exact,
at the full range of your tracking (~100 yards). Eyes Up isn't guessing where the
herbs are; it's showing the tracking WoW already draws, just not in the corner.

- **You choose what shows.** The options page lists every minimap tracking type.
  Gathering is on; mailboxes, auctioneers, quest markers and the rest are off. While
  the HUD is up these **override** your normal tracking, then hand it back when it
  comes down.
- **A real map goes in the corner.** There's only one minimap, so tick **Map in the
  corner** and a live map — roads, your position — fills the hole it left.
- **It steps aside when you're not gathering.** Cities and inns (full of service
  icons the game won't let us hide), dungeons and raids, and PvP instances: the HUD
  folds away and gives your minimap back, then returns when you ride out. Cities and
  dungeons are separate toggles — and delves and ritual sites keep the HUD, since
  those are worth gathering in.
- **A keybind for everywhere else.** Bind *Toggle the heads-up display* under Escape
  → Keybindings → **Eyes Up Add On** and flick it off when you drop into a busy camp.

Size, zoom, rotation, opacity and blip tooltips are all on the page.

## The cue — the original, still here

Want something lighter, or want it *as well* as the HUD? The **cue** is a small icon
near screen center that fades in when a wanted node is in reach, with an arrow at it,
and fades out when there isn't one. It doesn't touch your minimap, so run either, or
both.

- **It doesn't lie.** By default it only fires for nodes the game *confirms* are
  there — so if it lights up, the thing is real. The catch is reach: ~15–25 yards,
  as far as the game will confirm.
- **The right icon.** Pick from a dropdown: the item the node gives (looked up from
  its name), the plain profession symbol, or your own art from `textures/`. Fishing
  always shows a fishing icon, since pools give a grab-bag of fish.
- **Optional name tag** above the icon — handy for fishing pools especially.
- **It shuts up about things you just took**, instead of pointing at the hole you're
  standing over.
- **A quiet tick**, if you want one — off by default, and never for something it
  isn't sure about.

## Want more warning? (guesses)

Tick **Show guesses** (`/eu guesses on`) and the cue also points at places a node has
*been* before, out to your full range. Be warned: **most of those won't be there** —
a zone has thousands of spawn spots and only a handful are filled at once. Guesses
draw faint and never make a sound, so they at least look like guesses.

Works far better with **GatherMate2_Data** (free, on CurseForge): a big list of
everywhere nodes have been seen, so guesses work even in a zone you've never farmed.
Eyes Up reads it if it's there and shrugs if it isn't. Nothing is bundled, nothing
required.

## Filters

Every gathering node in the game is in the filter list (**Cue & filters** page), as a
tree: by **type** (Herbs, Mining, Lumber, Fishing, Treasure), and inside each by
**expansion**. Drill into *Herbs → Midnight* and untick the one weed you keep
grabbing by accident. Species are named by what you *see* in the world ("Copper
Vein"), not what they drop ("Copper Ore").

## Settings: per character, or shared

Each character keeps its own settings and gathered nodes by default. Tick **Share
settings across all my characters** and they all read and write one shared set
instead — your current settings copy across first, so nothing is lost, then it
reloads. Flip it back any time.

## One setting it changes for you

Eyes Up turns on WoW's **soft targeting** at login and restores your old setting at
logout. It has to: that's what lets the cue ask *"what could I grab right now?"*, and
it's what powers the HUD's tracking. `/eu softtarget off` if you'd rather manage it
yourself.

## Commands & keybinds

Almost everything lives in `/eu`. The handy ones:

| | |
|---|---|
| `/eu` | open the options |
| `/eu hud on\|off` | the heads-up display |
| `/eu guesses on\|off` | also point at nodes that might not be there |
| `/eu status` | why isn't it firing? |
| `/eu toggle` | eyes up / eyes closed |
| `/eu lock` / `/eu unlock` | drag the cue, then pin it |

`/eyesup` and `/ns` work too; `/eu` alone lists the rest. Under **Escape →
Keybindings → Eyes Up Add On** you can bind *Toggle the heads-up display* and *Toggle
the addon*.

## What it can't do

Two hard limits, both the game's, not ours:

- **The cue can't see far.** ~15–25 yards for herbs, ore and lumber — as far as the
  game will confirm a node is really there. (The *HUD* reaches your full ~100-yard
  tracking range, because it's the game's own blips.) Treasures are the exception:
  they come from the game's map markers, so the cue sees those at full range and
  always knows they're real.
- **A chair can hide a herb** from the cue. The game tells us about only *one* nearby
  thing — the best one — so a chest, a door, or your own fishing bobber, if it's
  closer, is what we hear about.

And on the HUD, service and quest POIs in hubs (mailboxes, quartermasters, quest
givers) are engine-drawn and can't be hidden by any addon — which is what the city
auto-hide and the toggle keybind are for.

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
| `Cue.lua` | the cue — an icon and an arrow near screen center |
| `Overlay.lua` | the old radar, still here if you want it (`/eu mode radar`) |
| `Scan.lua` | the engine: one look around per tick |
| `Options.lua` | the knobs (two pages: HUD, and Cue & filters) |
| `Core.lua` | wakes everything up |
| `Bindings.xml` | the keybind definitions (auto-loaded, never in the .toc) |

The cue and radar share one engine: `Scan` looks around once per tick and hands the
answer to whichever renderer is on. The HUD is different — it relocates the game's
own minimap rather than drawing anything itself.
