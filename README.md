# Short Stack

A client-only Roblox arcade front end managed with [Rojo](https://rojo.space/). The repository includes a responsive console library, one locally vendored Game Boy Advance implementation, an isolated Avalon R1 decorative preview, and a local-only core/ROM boundary.

## Implementation status

- **GBA / Depth:** source, client host, touch/keyboard/gamepad input, pause, in-session save states, an original generated homebrew demo path, and a local base64-ROM path are wired into the UI. **This has not been built with Rojo or tested in Roblox Studio, so do not treat it as playable or runtime-verified yet.**
- **NES, Game Boy, Game Boy Color, Master System, Game Gear, Atari 2600, and SNES:** catalog/UI entries only. No emulator cores are integrated for these systems; they are not playable.
- **Avalon R1:** a guarded, one-shot 96×64 3D console illustration is connected to the hero UI. It does not run an animation loop and is not on the emulation hot path. Roblox `EditableImage` permission/availability and visual output remain untested.
- **Zindex v1:** source was supplied and staged for review, but is not loaded or run. The supplied repository has no license file, and its virtual CPU/SoC is not a core for the requested consoles; it is not presented as a completed architecture integration.
- No commercial ROMs, BIOS files, server scripts, remotes, or online services are included.

The wording “mono Game Boy Color” has been represented as original monochrome Game Boy plus color Game Boy Color (which can run many original Game Boy titles). If a separate monochrome-only GBC mode was intended, that still needs clarification.

## Rojo setup

1. Install [Aftman](https://github.com/LPGhatguy/aftman), then run:
   ```sh
   aftman install
   ```
   `aftman.toml` pins Rojo 7.7.1.
2. Install the Rojo Studio plugin and open a Roblox place.
3. From this directory, start the sync server:
   ```sh
   rojo serve default.project.json
   ```
4. Connect the Studio plugin. `default.project.json` maps the project only to `StarterPlayerScripts.ShortStack`; it does not create any server containers.

To build a place/model file:

```sh
mkdir -p build
rojo build default.project.json --output build/ShortStack.rbxlx
```

Run the dependency-free static boundary checks with:

```sh
python3 tools/audit_project.py
```

Static checks do not replace a Rojo build, Luau type check, or Studio client playtest.

## GBA local game data

Roblox client scripts cannot read arbitrary files from a player's device. The GBA loader therefore supports only locally embedded **base64 text** in a `StringValue` named `ROM` under `ShortStack.Assets`, or a `StringValue` named `GBAROM` directly under `ShortStack`. A folder of sequentially numbered `StringValue` chunks (`1`, `2`, …) is also accepted at either location, capped at 4096 values. The decoded ROM limit is 32 MiB and the expected size is at least 192 bytes; practical limits may be lower on Roblox or constrained devices, so large images need target-device testing. ModuleScripts are rejected and never executed as ROM data. No game data is bundled.

The built-in demo is generated from the reviewed Depth source in memory; it is not a commercial title. Save states remain in memory for the current client session only.

## Source and notices

- [Depth](https://github.com/Underdog239/Depth-) at `1bab0fa33965affc1e6364b8058e3efcbf45922d` — MIT; notice in `vendor/Depth/LICENSE`.
- [Avalon R1](https://github.com/Underdog239/Avalon-r1) at `d271965e0a712d46091482f0ee862b24962c5673` — MIT; notice in `vendor/Avalon/LICENSE`.
- [Zindex v1](https://github.com/Underdog239/Zindex-v1) at `8e3a10e0d31dca583037c871e54342a28ed0cee5` — no license file was present in the supplied repository; its source is staged but unused pending clarification of permission/licensing.

See [`docs/CORE_INTEGRATION.md`](docs/CORE_INTEGRATION.md) for architecture boundaries, ROM handling, source review, and runtime-validation notes.
