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

```
World of Warcraft/_retail_/Interface/AddOns/EyesUp
```

WoW matches the folder name against `EyesUp.toc`. Call it anything else and the
game quietly pretends the addon doesn't exist. Then restart the client.

That's it. It works out of the box.

## The one thing worth knowing

**WoW won't tell an addon where the herbs are.** There's no API for it. The
minimap knows — those little yellow dots are real — but the game draws them
itself and won't let addons read them.

There is exactly one thing the game *will* tell us: what you could reach out and
grab right now. That's what Eyes Up is built on.

So **if the cue lights up, the thing is really there.** No false alarms. The catch
is reach — about 15–25 yards. It's a tap on the shoulder for the node you were
about to ride past, not a radar.

If you'd rather have more warning and accept that a lot of it will be wrong,
there's a switch for that. See below.

## What it does

- **One icon, near the middle of your screen.** The nearest thing you actually
  want, with an arrow pointing at it. Get close and the arrow gives up and the
  icon pulses — *it's here, look down.*
- **It gets out of the way.** Nothing nearby means nothing on screen. Not a faded
  ghost of the thing you flew past — nothing.
- **It doesn't lie.** It only fires for nodes the game confirms are actually
  there, plus treasures (which the game shows us directly).
- **It shows the real item.** Once you've gathered one of something, every one of
  that species shows its actual icon from then on. Before that it uses the art in
  `Textures/` — swap those files for your own if you like.
- **It shuts up about things you just took.** Pick a herb and that spot goes quiet
  for a few minutes, instead of the cue swinging round to point proudly at the
  hole you're standing over.
- **Filters that make sense.** By type, and by species — and species means the
  thing you *see* ("Copper Vein"), not the thing it drops ("Copper Ore"). Every
  node in the game is in the list, grouped by expansion.
- **A quiet tick**, if you want one. Off by default. It says "hey" once and then
  leaves you alone, and never for something it isn't sure about.

## Want more warning?

Tick **Show guesses** in the options (or `/eu guesses on`).

Now it also points at places a node has been *before*, out to your full detection
range.

Be warned: **most of those won't be there.** A zone has thousands of spawn spots
and only a handful are occupied at any moment. Guesses draw faint and never make
a sound, so at least they look like guesses. But they're guesses.

This works far better with **GatherMate2_Data** installed (free, on CurseForge) —
it's a big list of everywhere nodes have been seen, so guesses work even in a zone
you've never farmed. Eyes Up reads it if it's there and shrugs if it isn't.
Nothing is bundled, and nothing is required.

## One setting it changes for you

Eyes Up turns on WoW's **soft targeting** when you log in, and puts your old
setting back when you log out.

It has to. That's the setting that lets an addon ask *"what could I grab right
now?"*, and without it the cue can never fire at all. Turning the arc up also
means it notices things behind you, which is usually the whole problem.

If you'd rather manage your own settings: `/eu softtarget off`. Just know the cue
will go quiet.

## Commands

| | |
|---|---|
| `/eu` | options |
| `/eu status` | why isn't it firing? |
| `/eu guesses on\|off` | also point at things that might not be there |
| `/eu toggle` | eyes up / eyes closed |
| `/eu lock` / `/eu unlock` | drag the cue somewhere else, then pin it |
| `/eu reset` | put it back where it was |
| `/eu softtarget on\|off` | let it manage soft targeting (it needs this) |

`/eyesup` and `/ns` both work too.

## What it can't do

- **It can't see far.** ~15–25 yards for herbs, ore and lumber. That's the game's
  limit, not ours.
- **A chair can hide a herb.** The game only ever tells us about *one* nearby
  thing — the best one — so if a chest or a door or your own fishing bobber is
  closer than the herb, we hear about that instead. Nothing to be done.
- **Treasures are the exception.** Those come from the game's own map markers, so
  we see them at full range and always know they're real.

## Under the hood

| file | what it's for |
|---|---|
| `Constants.lua` | every number and magic string the addon believes in |
| `Species.lua` | every gathering node in the game (generated) |
| `Database.lua` | what we remember; how far; which way |
| `Seed.lua` | GatherMate's node list, if you have it (optional) |
| `Live.lua` | the only thing that can say "yes, it's really there" |
| `Vignettes.lua` | treasures — the game shows us these directly |
| `Cue.lua` | the cue — the point of all this |
| `Overlay.lua` | the old radar, still here if you want it (`/eu mode radar`) |
| `Scan.lua` | the engine: one look around per tick |
| `Options.lua` | the knobs |
| `Probe.lua` | diagnostics; delete it and nothing changes |
| `Core.lua` | wakes everything up |

`Scan` looks around once per tick and hands the answer to the renderer. Renderers
paint; they do no distance maths and own no timers. Adding a new way to show the
same information means writing a renderer, not touching the engine.
