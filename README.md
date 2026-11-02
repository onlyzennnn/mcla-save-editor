# mc4.sav — Midnight Club: Los Angeles save editor

**English** · [Português](README.pt-BR.md)

Save editor and format documentation for **Midnight Club: Los Angeles** (Xbox 360, Complete Edition),
as written by the [MC_LA_Recompiled](https://github.com/robertoaraujo77/MC_LA_Recompiled) PC runtime.

![The editor with a save open, showing money, reputation, career progression and the garage slots](og.png)

The editor is useful. The format documentation below is the point: as far as I can tell the
`mc4.sav` layout has never been published anywhere. The save editors floating around fan forums
are closed binaries from 2013 with no notes attached, so anyone who wants to touch this file
starts from zero. This repository is the notes.

## Credits

- **[robertoaraujo77 / MC_LA_Recompiled](https://github.com/robertoaraujo77/MC_LA_Recompiled)** — the recompiled PC runtime this work is based on. Every byte documented here was read from a save its ReXGlue runtime produced, and its `userdata` layout is what the tools expect. None of this exists without that project.
- **holdmysocks** — the original MCLA recompilation, and **RenanQueiroz** for the fork the project above builds on.
- **u/leveldock6** — the [r/midnightclub guide](https://www.reddit.com/r/midnightclub/comments/17hht3b/guide_unlocking_the_audi_r8_for_purchase_in_mcla/) that located the Audi R8 lock in `tune/vehicle/0xe94bde63` inside `xarchive_cache.rpf`.
- **[nicolas-found42 / carmodels#38](https://github.com/nicolas-found42/carmodels/pull/38)** — documented the RPF3 container and the Jenkins one-at-a-time name hashing, which is how the archive side of this was understood.

## Scope

Works on the save the recompiled runtime writes:

```
<game folder>\userdata\B13EBABEBABEBABE\545407F8\00000001\mc4.sav\mc4.sav
```

A save from a real Xbox 360 lives inside an STFS container. Extract the inner `mc4.sav` first;
these tools read the plain file, not the package. The sibling `mc4.sav.header` is a small
XContent header with no hash of the contents, so it needs no changes after an edit.

Close the game before editing. Both tools refuse to write a file whose structure does not
validate, and neither one ever changes the file size.

## Tools

**[Open the editor](https://onlyzennnn.github.io/mcla-save-editor/)** — drop the save in, edit, download the patched file. It runs entirely in the browser; the save never leaves your machine. `index.html` is the whole thing, so downloading that one file and opening it offline works the same way.

It edits money, reputation, career progression, the garage slots (vehicle, label, plate) and
**performance upgrades** — a button per car maxes all thirteen categories, or one button does the
whole garage. There is a language selector in the corner.

For the command line, `scripts/mcla-save-editor.ps1` covers `info`, `garage`, `roster`, `cars`,
`setcar`, `money`, `rep`, `progress`, `stats`, `find`, `get`, `set`, `diff` and `selftest`. The
performance feature is in the browser editor only.

`tests/render.test.js` runs the page's own script against a synthetic save in a minimal DOM and
checks that every field actually reaches the bytes. Pass a path to run it against a real `mc4.sav`.

### Unlocking cars, as a mod

Eighteen of the 48 vehicles are gated above their own class: the Audi R8 is a `B0` car with
`UnlockingGroup A0`, so it never reaches the showroom until A class. That gate is game data, not
save data — it lives in `tune/vehicle/vehicle.lst`, which the archive stores under the name
`0xe94bde63` because RPF3 keys entries by Jenkins one-at-a-time hash and `joaat("vehicle.lst")` is
`0xE94BDE63`.

`scripts/mcla-mod-unlock.ps1` reads **your** copy of that file and writes a mod folder for
[LARecomp](https://github.com/mzzvxm/LARecomp)'s mod loader:

```powershell
.\scripts\mcla-mod-unlock.ps1 list  -Lst <your vehicle.lst>
.\scripts\mcla-mod-unlock.ps1 build -Lst <your vehicle.lst> -Out .\mods -Cars vp_aud_r8_08
```

It changes only the `UnlockingGroup` lines, leaves the rest of the file byte for byte, and
re-parses the result before writing. Nothing from the game ships with this repository.

The mod loader packs the folder into `xarchive_mods.rpf` and mounts it last, so it wins per file
and everything it does not contain still comes from the shipped archives. That is the difference
from swapping `xarchive_cache.rpf` wholesale, which is what the Reddit guides do: the swap also
replaces the localized strings, which is why that route costs you the translation.

**This needs a build with a mod loader.** `MC_LA_Recompiled` does not have one — its binaries
contain no `modloader`, `xarchive_mods`, `textures_replace` or `rims` strings. LARecomp has the
loader but ships no release, so you compile it yourself.

## Format

Integers are **big-endian** throughout: the game is PowerPC. There is no checksum anywhere in
the file, so edits need no rehash and no resigning. The section walk ending exactly at EOF is
the only integrity check there is, and both tools use it as one.

### Container

```
u32  capacity        (0x0E in every save seen)
u32  section count
```

then, repeated until EOF:

```
u32  name length
     name  (ASCII, no terminator)
u8   flag
u32  data size
     data[size]
```

A 537,428-byte save holds nine sections:

| Section | Flag | Size |
|---|---|---|
| `Stats` | 1 | 16,908 |
| `LocalOptions` | 9 | 254,032 |
| `EditorData` | 5 | 42,256 |
| `ColorData` | 1 | 160 |
| `UserVinylData` | 1 | 17,292 |
| `RubberbandMgr` | 2 | 200 |
| `Career` | 11 | 200,000 |
| `RaceFavorites` | 1 | 6,400 |
| `enableGps` | 1 | 1 |

Offsets below are relative to a section's **data** start, not to the file.

### Career

| Offset | Type | Meaning |
|---|---|---|
| `+0x2D9` | u32 | Money. See the note below: the offset is computed, not fixed |
| `+0x2DD` | u32 | Unknown. **Do not write.** See [What does not work](#what-does-not-work). |
| `+0x2E1` | u32 | Reputation |
| `+0x2E5` | u32 | Number of progression blocks (43) |
| `+0x2E9` | — | Progression blocks, 65 bytes each: name, zero padding, and a completion flag in the **last** byte of the block |

Money is not at a fixed offset. `Career+4` is a version byte that must read `0x0B`, `Career+5` is a
u32 count, and money sits at `Career + 9 + count * 0x30`. Every save seen here has a count of 15,
which works out to `0x2D9` — but a save with a different count puts money somewhere else, so
compute it. This structure is confirmed by [unknownv2/save-editor-tools](https://github.com/unknownv2/save-editor-tools/blob/dev/Midnight%20Club%20LA/MidnightClubLA.cs),
a 2013 editor whose reader matches this container byte for byte.

Career also holds race series names (`hw_tournament1`, `dt_local_hangout1_series`, and so on) and
per-class counters in 65-byte blocks named `Tuner_0`, `Muscle_0`, `Exotic_0`, `Luxury_0`. Those
counters track races run with each class; they are not unlocks.

### LocalOptions

| Offset | Type | Meaning |
|---|---|---|
| `+0x53F` | u8 | Number of cars the game reads |
| `+0x543` | u8 | Index of the last car (count minus one) |
| `+1293` | — | Performance blocks, same 8,176 stride as the slots |
| `+0x24FD` | — | Garage slots, 29 of them, 8,176 bytes each |

**The garage is read sequentially from slot 0 and stops at the counter.** A car written into a
slot past that counter is in the file and invisible in game. This is the single most useful fact
in this document and it cost an evening to find.

Inside a slot:

| Offset | Size | Meaning |
|---|---|---|
| `+0` | 32 | Vehicle prefab name, NUL-terminated, padded with `0xCD` |
| `+32` | 33 | Garage list label (`83 GOLF/GTI`), same termination and padding |
| `+2186` | 7 | License plate, exactly seven characters |
| `+687`, `+1215` | 1 | Per-slot id, assigned by the game |

A slot the game filled by purchase and a slot written by hand differ only in those fields, so an
injected car renders with whatever wheels the game picks by default. The rest of the 8,176 bytes is
not empty — a car carries roughly 4,000 bytes of dense, unaligned data in here, and it changes as
the car is customized. Visual customization has not been decoded.

### Performance upgrades

These live in their own array, **not** in the garage slot:

```
LocalOptions + 1293 + N * 8176
```

Same stride as the slots, but the base sits exactly one stride earlier, so the block for the car
named in slot N is one slot "behind" it. That offset is what made this hard to see: buying a part
for the car in slot 1 writes into the bytes that look like slot 0.

| Offset in the block | Size | Meaning |
|---|---|---|
| `+95` | 13 | One byte per upgrade category, level `0`, `1` or `2` |
| `+126` | 1 | Tune percentage the shop displays, `0` to `100` |

The percentage is the sum of the 13 levels over 26. All thirteen at level 2 is 100%, thirteen at
level 1 is 50%, and two single levels read as 8%. Every car in a 12-car garage matched that
arithmetic exactly. Writing level 2 across the thirteen bytes and 100 into `+126` **was confirmed
in game**: the car showed 100% tune with every category installed.

### Per-car ledger

```
LocalOptions + 246573 + N * 336
```

A second per-car array, keyed by the **Jenkins one-at-a-time hash of the vehicle name** at `+71`,
with cumulative money spent on that car at `+77` (mirrored at `+149`) and a bitmask at `+140..+144`
that tracks purchases. It is bookkeeping only: zeroing an entire record changed nothing in game, so
do not bother writing here.

### Stats

Records of 16 bytes. The FourCC sits at an **absolute** file offset where `offset % 16 == 2`:

```
fourcc[4]  u32 id @+4  u8 type @+8  u24 @+9  value @+12
```

Type `0x28` and `0x00` mean the value is a float; everything else is an unsigned integer. A
normal save holds around 100 records: `gWIN` wins, `gDAM` damage, `gNIT` nitrous, `tPUR` cars
purchased, and so on.

### Vehicle names

The garage stores the prefab name as text, and only names the game knows will load. The 48 valid
names come from `tune/vehicle/0xe94bde63` inside `xarchive_cache.rpf`; both tools carry the list.
The pattern is `vp_<make>_<model>_<year>`, for example `vp_vw_golf_83`, `vp_chv_camaross_69`,
`vp_aud_r8_08`.

Those names exist **only** as Jenkins one-at-a-time hashes in the RPF3 table of contents. A
plain-text search over the whole 7.8 GB disc image finds none of them, which is why grepping the
game files for a car name never works.

## Verified in game

Read on screen in a running game, not inferred:

- Money at `Career+0x2D9`, watched change twice
- The car counter at `LocalOptions+0x53F`, seen going 2 to 3 the moment a car was bought
- Slot prefab name and label, confirmed by a car appearing in the garage with the right model and the right text
- Reputation at `Career+0x2E1`, matching the number on screen
- Progression flags, matching the player's actual career position
- Performance upgrades: writing level 2 into the thirteen bytes at `+95` and 100 into `+126` made
  the car read 100% tune in the shop with every category installed

## What does not work

Spending time here again is not necessary.

- **`Career+0x2DD`** crashes the game on load when set to 0, 1 or 4. It did not change across a
  real in-game group unlock either, so it is not the vehicle group.
- **Reputation does not gate vehicle groups.** Raising it to 500,000 unlocked nothing in the showroom.
- **Progression flags do not gate them either.** All 43 marked complete changed nothing.
- **The Audi R8 lock is not in the save.** It lives in `tune/vehicle/0xe94bde63` inside
  `xarchive_cache.rpf`, as Social Club lines on the R8's `Vehicle` block. Writing `vp_aud_r8_08`
  into a garage slot does nothing until that game file is modded. Two r/midnightclub threads carry
  that mod: the [original guide](https://www.reddit.com/r/midnightclub/comments/17hht3b/guide_unlocking_the_audi_r8_for_purchase_in_mcla/)
  and a [later purchasable-R8 post](https://www.reddit.com/r/midnightclub/comments/1i0crmk/midnight_club_la_purchasable_audi_r8_xbox_360_mod/).
  Even with the mod the car's `UnlockingGroup A0` still requires group 4 for the showroom.
- **Wheels cannot be fixed from the save.** A purchased slot and a hand-written slot are
  byte-identical outside name, label, plate and id, so a car injected into the garage renders with
  whatever the game resolves by default.

- **The per-car ledger is not the upgrade state.** Zeroing an entire 336-byte record, and separately
  setting its `+140..+144` bitmask to all ones, both left the shop exactly as it was.
- **`RubberbandMgr` is not a difficulty dial.** It is three int32 values followed by 188 bytes of
  `0xCD` filler. The values moved `[14, 2, 2]` to `[-4, 3, 3]` across a session, which is runtime
  bookkeeping, not a setting.

Still open: which field unlocks vehicle groups, and where visual customization is stored. The
vehicle's group itself is game data, not save data — `tune/vehicle/0xe94bde63` carries a `Group`
and an `UnlockingGroup` per car, along with `BaseSpeed`, `ModsSpeed`, `BaseAccel`, `ModsAccel`,
`BaseHndlg` and `ModsHndlg`. The `Mods` values are the ceiling a fully upgraded car reaches, which
is what the 13 levels above interpolate toward.

## Not in this repository

No game data, by design. The ISO, `xarchive_cache.rpf`, `0xe94bde63` and any modded archive all
belong to Rockstar and are not redistributed here. Personal save files are excluded too. The
`.gitignore` is set up to keep them out by accident as well as on purpose.

## License

MIT. See [LICENSE](LICENSE).
