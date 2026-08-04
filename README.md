# Dramatic Shape Voxel Mod

A mod for the [Pokémon Gen 1 Recompilation
Project](https://github.com/bryanthaboi/pokemon-gen1-recomp-project).

The overworld as a voxelized 3D diorama, in stereoscopic 3D if you have
something to see it with. Also supports experimental first-person and
third-person cameras.

## Controls

Every key is free-roam only, and each one is also a row on the OPTIONS
menu.

| control | does |
| --- | --- |
| `3`, or the **VOXEL** options row | OFF → 15 → 35 → 50 → 75 → 1ST → 3RD → OFF (camera pitch) |
| `SELECT` (pad / touch) | the same step as `3` — for the machines with no number row |
| `5`, or the **V-GRID** options row | OFF / ON — a one-pixel wireframe on every voxel |
| `6`, or the **T-SHIFT** options row | OFF → 1 → 2 → 3 → OFF (miniature blur) |
| `7`, or the **V-CURVE** options row | OFF → 1 → 2 → 3 — bend the world over the horizon |
| `8`, or the **3D-BTL** options row | ON / OFF — fight on the map instead of on a white field |
| `9`, or the **WATER** options row | FULL / SKY / OFF — waves and reflections on water. **SKY** gives the surface its pixel-tall wave columns and puts the sky, the sun, the moon and the cast in them; **FULL** adds a screen-space ray march that also reflects the shoreline, the trees and the buildings standing behind it |
| the **BACK SPRITES** options row | OFF / ON — keep your own Pokémon on the battle menu, seen from behind in its classic slot, instead of standing it on the map; the foe is still out there. Only on the menu while **3D-BTL** is on, because it decides nothing without it |
| the **AA** options row | OFF / 2X / 4X — smooth the stair-stepped edges of the 3D world by rendering the diorama larger than the window and folding it back down. The ladder is samples per display pixel: 2X is a canvas root-two wider and taller, 4X one exactly twice the size. Every edge in the projected picture softens with the silhouettes — the tileset's own texels are quads in a perspective view and cross the pixel grid at the same arbitrary angles — so the diorama reads smoother rather than sharper. The most expensive row in the mod, so it is OFF by default and **FULL** leaves it alone |
| the **DAYTIME** options row | SYNC / DAY / NIGHT / DUSK / DAWN / CYCLE — what time it is outdoors, on the diorama *and* on the flat 2D world; held at SYNC (and off the menu) while VOXEL is FULL |
| the **3D** options row | OFF / SBS / T/B / ROW / COL / CHECK / ANAGL / LEIA — stereoscopic 3D, with **3D DEPTH**, **3D FOCUS** and **3D SWAP** appearing under it. See [Stereoscopic 3D](#stereoscopic-3d) |

## Free-roam cameras (1ST / 3RD)

The last two rungs of the **VOXEL** ladder are experimental, and they are
the same camera: **1ST** stands it in the player's own eyes, **3RD** pulls
it back onto a boom behind their shoulder. Both steer, and on both the grid
walk is replaced by continuous camera-relative movement — push in any
direction and you go there, at any angle, not just along the four compass
lines. Collision, warps, ledges, encounters and scripts all still run
through the engine's own machinery.

| control | does |
| --- | --- |
| mouse | look (the cursor is captured; left click is A, right click is B) |
| right stick | look |
| a touch drag off the overlay's controls | look |
| left stick / touch d-pad / arrow keys | walk, relative to where the camera looks |
| wheel, `Q` / `E`, pinch, or a stick click | **3RD only** — let the boom out and pull it in (`Q` and left stick click out, `E` and right stick click in) |

On an **orbit rung** the same wheel, `Q`/`E` and pinch drive the engine's own
survey zoom. On **1ST** they do nothing at all: the eye is in your head, and
there is no distance to change.

On **3RD** the boom shortens against whatever is behind you, so backing into
a wall walks the camera in to your shoulders rather than through it — squeeze
it all the way in and the view is 1ST until you step clear. The character
turns to face where they are walking, and every sprite in the world — yours,
the NPCs', the figures drawn into the furniture — turns to face the camera
and shows the frame it would look like from where the camera actually
stands, so walking behind someone shows you their back.

## The battle camera

A fight staged on the map (**3D-BTL**, on by default) is shot with a solved
over-the-shoulder rig — and you can steer it.

| control | does |
| --- | --- |
| right stick, a touch drag, or the mouse | swing the shot around the arena (→) and raise the seat (↑) |
| wheel, `Q` / `E`, pinch, or a stick click | the lens (`Q` / left stick click out, `E` / right stick click in) |

Both axes stop where the composition does. Left stops at the shot the rig was
solved for — there is nothing to the left of it. Right ends **side-on**: the
eye square to the arena's axis, both Pokémon at the same distance instead of
one behind the other. Down stops at the rig's own low stance; up is 45° above
it. The lens opens as you swing or climb, by exactly the amount the two
Pokémon spread apart, so they stay framed at every angle. Move animations
follow the pair's position *and* its separation, so a beam still lands on the
Pokémon it was aimed at.

Where you leave the camera is where the next battle opens.

**BACK SPRITES locks it.** That setting pins your own Pokémon to the GB's slot
on the menu while the foe stands out on the map, and no angle holds a
composition that is half frame and half world — so with it on, the shot holds
the one the rig was solved for.

## Stereoscopic 3D

The **3D** options row renders the whole diorama from two viewpoints and
packs the pair for whatever will separate them again. It is off by default,
because it costs a second render of the world — which makes it the most
expensive row in the mod after **AA**, and the two multiply.

| rung | for |
| --- | --- |
| `OFF` | one viewpoint, as ever |
| `SBS` | side by side — a 3D TV's own mode, capture, and headsets running a desktop viewer |
| `T/B` | over and under, the same set of consumers |
| `ROW` | row-interlaced: passive 3D televisions and projectors |
| `COL` | column-interlaced: the passive monitors that use it |
| `CHECK` | checkerboard: likewise |
| `ANAGL` | red-cyan, by the Dubois matrix — a pair of paper glasses and any screen at all |
| `LEIA` | a Leia / Simulated Reality autostereoscopic panel. No glasses |

Three more rows appear under it while it is on.

| control | does |
| --- | --- |
| **3D DEPTH** | how much of the budget to spend. 100% puts the far horizon 2.5% of the screen's width apart — and *holds* it there at every camera angle, every zoom rung and every window size, because the separation is solved from the budget rather than set as a distance. Up if your eyes take it happily, down for a small window or a long evening |
| **3D FOCUS** | where the screen is. Everything nearer than the focus comes out of the display toward you and everything past it sits behind the glass, so **NEAR** pushes the diorama into the room and **FAR** sinks it into the desk. **MID** puts the screen on whatever the camera is looking at |
| **3D SWAP** | swap the eyes. Nothing in software can ask a pair of glasses which way round its filters are, or a lenticular panel which column it starts on — and a picture with its eyes crossed still *looks* like 3D, just inside out. If it feels wrong in a way you cannot name, try this |

Three things worth knowing before you blame the mod:

- **Battles are in 3D too**, mons and move effects both — the effects stand
  on a plane through the two Pokémon rather than on the glass, so a burst
  aimed at the foe bursts at the foe's distance. The rest of the 2D screens
  are split at zero depth: menus, dialogs, the title and a battle's own text
  box and HUDs sit on the screen plane, which is where they belong — the row
  is a statement about your display, and the display does not stop expecting
  its format between one screen and the next. A full-screen flash (an
  encounter starting, a warp fading out) dissolves the depth away and back
  rather than dropping it for a frame at a time. This part needs Windows;
  elsewhere the world goes 3D and the 2D screens stay flat, with the reason
  on the console.
- **Mark the game's `.exe` DPI-aware** if you run the display above 100%
  scaling and you are using `ROW`, `COL`, `CHECK` or `LEIA`. Those four need
  the mod's pixels to land one-for-one on the panel's own, and a scaled
  display stretches the finished frame *after* every shader in it. Nothing
  inside the process can correct that — DPI awareness is declared once, and
  SDL declares it while LÖVE starts up, long before a mod exists — but the
  executable can be told from outside: **right-click the .exe → Properties →
  Compatibility → Change high DPI settings → tick "Override high DPI scaling
  behaviour", scaling performed by "Application"**. The mod prints the same
  advice to the console when it detects the situation.
- **`LEIA` falls back to `SBS`** wherever the Simulated Reality runtime, an
  SR display, or the mod's own `leiasr_shim.dll` is missing, and says which
  on the console. If the picture is 3D but does not respond to your head
  moving, that is a *different* failure and the console will not have caught
  it — see [`leiasr_shim/README.md`](leiasr_shim/README.md).

## Licenses

This mod is released under the **MIT License** — see [`LICENSE`](LICENSE).

Release archives include one compiled binary of the mod's own:
`assets/leiasr/leiasr_shim.dll`, built from
[`leiasr_shim/`](leiasr_shim/) by this repository's release workflow and MIT
like the rest of the mod. It statically links
[bo3b/SR-lib](https://github.com/bo3b/SR-lib)'s wrapper around the Simulated
Reality SDK.

The Simulated Reality **runtime** is not redistributed. It comes from the
user's own SR installation, is shared between every SR application on the
machine, and shipping a second copy of it is how version conflicts start.

Everything else in this mod is original to it, except that the voxel
geometry and shape profiles are derived from the tile and sprite data of
the original game, as documented by the
[pret/pokered](https://github.com/pret/pokered) disassembly. No ROM
data, artwork or audio is included; the mod reads the assets the host
game already has.