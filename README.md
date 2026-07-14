# Eyes Up

*Watch the world, not the minimap.*

You know the moment. You're cruising over a ridgeline, enjoying the view, and
somewhere behind you — a long way behind you now — was a herb you'd have happily
stopped for. You didn't see it, because seeing it would have meant staring at a
little circle in the corner of your screen instead of at the game.

**Eyes Up** pops a small icon near the middle of your screen when there's
something worth stopping for, with an arrow pointing at it. When there isn't,
there's nothing on screen at all.

For WoW retail (Midnight, 12.0.7+). No libraries, no dependencies, nothing to set
up.

## Install

Drop the folder in your AddOns directory. It **must** be named `EyesUp`:

```
World of Warcraft/_retail_/Interface/AddOns/EyesUp
```

WoW matches the folder name against `EyesUp.toc`. Call it anything else and the
game will quietly pretend the addon doesn't exist. Then restart the client.

## The one thing to understand

Here's the honest bit, up front, because it shapes everything else.

**WoW will not tell an addon where the herbs are.** There's no API for it. The
minimap knows — those little yellow dots are real — but the game draws them
itself and won't let addons read them. That's not us being lazy; Blizzard has
actually been *closing* that door, not opening it.

There is exactly one thing the game *will* tell us: what you could reach out and
grab right now. That's what Eyes Up is built on.

So by default, **if the cue lights up, the thing is really there.** No false
alarms, ever. The catch is reach — it's about 15–25 yards, not 60. It's a tap on
the shoulder for the node you were about to ride past, not a radar.

If you'd rather have more warning and accept that a lot of it will be wrong, see
`/eu guesses on` below.

## Sixty seconds with it

1. **`/eu status`** — tells you if everything's switched on and working.
2. Go for a ride. When you pass something worth grabbing, it'll show up.
3. **`/eu`** — the options. Turn node types on and off, recolor them, mute the
   one weed you keep picking by accident.
4. **`/eu unlock`** — drag the cue somewhere that suits you. **`/eu lock`** when
   you like where it is.

## What it does

- **One icon, near the middle of your screen.** The nearest thing you actually
  want, with an arrow. Get close and the arrow gives up and the icon pulses —
  *it's here, look down.*
- **It gets out of the way.** Nothing nearby means nothing on screen. Not a faded
  ghost of the thing you flew past — nothing.
- **It doesn't lie.** By default it only fires for nodes the game has confirmed
  are actually there, plus treasures (which the game shows us directly).
- **It shows the real item.** Once you've gathered one of something, every one of
  that species shows its actual icon from then on. Before that it uses the art in
  `Textures/` — nicer than a generic leaf, and you can swap it for your own.
- **It shuts up about things you just took.** Pick a herb and that spot goes quiet
  for a few minutes, instead of the cue swinging round to point proudly at the
  hole you're standing over.
- **Filters that make sense.** By type, and by species — and species means the
  thing you *see* ("Copper Vein"), not the thing it drops ("Copper Ore").
- **A quiet tick**, if you want one. Off by default. It says "hey" once and then
  leaves you alone. It never chimes for something it isn't sure about.
- **The radar** is still in here if you liked it: `/eu mode radar` (or `both`).

## Want more warning?

```
/eu guesses on
```

Now it'll also point at places a node has been *before* — out to 60 yards.

Be warned: **most of those won't be there.** A zone has thousands of spawn spots
and only a handful are occupied at any moment. The guesses draw faint and never
make a sound, so at least they look like guesses. But they're guesses.

This works much better if you install **GatherMate2_Data** (free, on CurseForge).
It's a big list of everywhere nodes have been seen, so the guesses work even in a
zone you've never farmed. Eyes Up reads it if it's there and shrugs if it isn't —
it's optional, and nothing is bundled or required.

*(GatherMate is also how Eyes Up knows which direction a confirmed node is in, in
a zone you've never gathered in. Without it, the addon uses your own recorded
gathers instead — so it'll point once you've picked one of something.)*

## Commands

| | |
|---|---|
| `/eu` | options |
| `/eu status` | why isn't it firing? |
| `/eu near` | list everything it can see right now, and why |
| `/eu guesses on\|off` | also point at things that might not be there |
| `/eu toggle` | eyes up / eyes closed |
| `/eu mode cue\|radar\|both` | which face it wears |
| `/eu lock` / `/eu unlock` | move things around |
| `/eu reset` | put them back where they were |
| `/eu demo` | scatter imaginary nodes, for a look |
| `/eu clear` | forget this map |
| `/eu seed` | is the GatherMate data being used? |
| `/eu softtarget on\|off` | let it manage soft targeting (it needs this) |
| `/eu debug` | narrate everything |
| `/eu probe` | diagnostics — see below |

`/eyesup` and `/ns` both work too.

## One setting it changes for you

Eyes Up turns on WoW's **soft targeting** (`SoftTargetInteract`,
`SoftTargetInteractArc`) when you log in, and puts your old setting back when you
log out.

It has to. That's the setting that lets an addon ask "what could I grab right
now?", and without it the cue can never fire at all. Turning the arc up also means
it notices things *behind* you, which is usually the whole problem.

If you'd rather manage your own settings: `/eu softtarget off`. Just know the cue
will go quiet.

## What it can't do

- **It can't see very far.** ~15–25 yards for herbs, ore and lumber. That's the
  game's limit, not ours — we ask for your full detection range and take whatever
  the engine gives.
- **A chair can hide a herb.** The game only ever tells us about *one* nearby
  thing — the best one — so if a chest or a door or your own fishing bobber is
  closer than the herb, we hear about that instead. Nothing to be done.
- **Treasures are the exception** — those come from the game's own map markers, so
  we see those at full range and always know they're real.
- **Gather spell names are English-only.** Other clients need their spell names
  added to `NS.GatherSpellNames` in `Constants.lua`. It's a two-line change.

## Diagnostics

`/eu probe` is a self-contained fact-finder for the things above — how far soft
targeting really reaches, what the game will and won't tell us, how big the zone
actually is. It changes nothing unless you ask and puts back anything it borrows.
Delete `Probe.lua` and the addon is unchanged.

`/eu near` is the one you'll actually want: it lists everything the cue can
currently see, how far, which way, and whether it's a real thing or a guess.

## Coming from NodeSight?

Same addon, new name. Your old data lives in a file named after the old addon:

1. Log out.
2. Find `WTF/Account/<ACCOUNT>/<Realm>/<Character>/SavedVariables/NodeSight.lua`
3. Copy it next to itself as `EyesUp.lua`.
4. Log back in — it'll find the old table, adopt it, and say so.

Or don't. It's not much of a loss.

## Under the hood

| file | what it's for |
|---|---|
| `Constants.lua` | every number and magic string the addon believes in |
| `Database.lua` | what we remember; how far; which way |
| `Seed.lua` | GatherMate's node list, if you have it (optional) |
| `Live.lua` | the only thing that can say "yes, it's really there" |
| `Vignettes.lua` | treasures — the game shows us these directly |
| `Overlay.lua` | the radar (a renderer) |
| `Cue.lua` | the cue (a renderer) — the point of all this |
| `Scan.lua` | the engine: one look around per tick |
| `Options.lua` | the knobs |
| `Probe.lua` | diagnostics; delete it and nothing changes |
| `Core.lua` | wakes everything up |

`Scan` looks around once per tick and hands the answer to whichever renderer you
asked for. Renderers paint; they do no distance math and own no timers. Adding a
new way to show the same information means writing a renderer, not touching the
engine.
