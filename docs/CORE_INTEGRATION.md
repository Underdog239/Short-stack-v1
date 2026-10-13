# Core and renderer integration

## Current state (2026-10-13)

The library contains eight catalog entries. Only the GBA has a linked local implementation, from the user-supplied Depth source. Its adapter is wired to the UI and supports a generated homebrew demo, local ROM data, input, pause, and in-memory session snapshots. **Rojo, Luau, and Roblox Studio verification has not run in this environment; the GBA path is not claimed as playable or runtime-validated.**

The other seven catalog entries (NES, original GB, GBC, SMS, Game Gear, Atari 2600, SNES) are not playable: no emulation cores are connected to them. The “mono Game Boy Color” wording is still interpreted as a separate monochrome GB and color GBC, with the GBC entry noting GB compatibility.

Avalon R1 is wired only as a static, guarded decorative preview. Zindex v1 is staged but unused; it models a virtual CPU/SoC rather than one of the requested console cores, and the supplied repository contained no license file. No `RenderStepped` loop is started for either decorative renderer.

## Core API and ownership

`CoreRegistry` accepts only local modules with API version 1, a matching catalog ID, and a `Create(configuration)` function. The GBA adapter is registered locally by `AppController`; it is not discovered over the network. `GBAHost` owns the Depth machine, input, renderer, bounded scheduler, and cleanup. It stops the emulation on a frame/display failure and releases its input/render connections when the user exits.

The emulator hot path runs on `RenderStepped`, caps work to a short per-callback slice, and limits catch-up to two completed frames per callback. The starting slice is 4 ms on touch devices and 8 ms otherwise, with adaptive caps of 6/10 ms. These are conservative starting values, **not measured performance guarantees**. The Depth framebuffer uses one `EditableImage` upload when supported and a coarse 30×20 UI grid fallback otherwise. PCM mixing is disabled in the host because no audio output adapter is installed.

Avalon renders one 96×64 image during UI construction inside `pcall`, then sleeps; it is not used for game frames. Its source is MIT-licensed, but Roblox `EditableImage` availability may depend on Studio/experience permissions. If creation fails, the illustration is omitted and the app continues.

## Local GBA ROM data

Roblox client Luau does not expose arbitrary filesystem access. `ROMLoader` accepts either:

- `StringValue` named `ROM` at `ShortStack.Assets.ROM`, or
- `StringValue` named `GBAROM` directly below `ShortStack`.

A `Folder` at either location may instead contain base64 chunks in `StringValue` children named sequentially `1`, `2`, … . Missing, duplicate, non-numeric, or gapped chunk indexes are rejected; chunks are concatenated by numeric index and capped at 4096 values. The decoded size must be 192 bytes–32 MiB. Encoded-size checks happen before decoding to bound allocation, but Roblox/device string and memory limits may be lower and remain untested. ModuleScripts are rejected and are never required as game data. There is no HTTP, asset-ID loading, `loadstring`, filesystem access, cloud storage, or server trust dependency.

Only ROM data a user is authorized to use should be supplied. Nothing commercial is shipped. The built-in Depth demo is generated in memory from source; it does not depend on a downloaded ROM or BIOS. The emulator treats the game as guest instructions and does not dynamically execute ROM contents as Luau.

Save-state snapshots are opt-in, in-memory, and scoped to one running session and the exact in-memory cartridge buffer. They are not written to DataStore or persisted across sessions. Focus loss pauses the host and releases held inputs.

## Client-only and security constraints

- Keep all runtime code under `src/client` and retain the `StarterPlayerScripts.ShortStack` mapping in `default.project.json`.
- Do not add server scripts, remotes, network code loading, asset-ID `require`, `loadstring`, or obfuscated runtime loaders.
- Review each core and its license before registering it. Never assume that a catalog entry or a copied package is a playable core.
- A Roblox client is not a trust boundary for multiplayer authority. Emulator state must not control server-authoritative game state.
- Keep ROM limits and error boundaries in place; treat ROMs and save states as untrusted input, even though guest code is interpreted by the emulator.
- Preserve third-party notices. `vendor/Depth/LICENSE` and `vendor/Avalon/LICENSE` are present. No license file was supplied for Zindex v1, so it is not invoked and should not be redistributed as an enabled dependency until permission is clarified.

## Testing checklist

Before describing any console as playable:

1. Install the pinned Rojo version and build `default.project.json`.
2. Run an available Luau syntax/type checker over every `.lua` and `.luau` module.
3. Open the Rojo project in Roblox Studio and confirm the tree remains exclusively under `StarterPlayerScripts`.
4. Run the generated GBA demo on desktop and touch clients; verify display fallback, button mappings, pause/resume, focus loss, save/restore, exit, and repeated launch/cleanup.
5. Test a user-supplied authorized ROM through the base64 `StringValue` path, including invalid base64, oversized data, missing chunks, and attempted ModuleScript input.
6. Measure frame time, memory, battery/thermal behavior, and EditableImage permission fallback on low-end mobile and desktop. Adjust budgets based on measurements.
7. For each additional console, review a licensed local core, implement a bounded adapter and input/display path, then repeat its hardware-specific test suite.

## Supplied repositories

- Depth: `https://github.com/Underdog239/Depth-`, commit `1bab0fa33965affc1e6364b8058e3efcbf45922d`, MIT. Only emulator, input, render, and selected optimization/shared source is copied; its separate bootstrap/UI and installer are not used.
- Avalon R1: `https://github.com/Underdog239/Avalon-r1`, commit `d271965e0a712d46091482f0ee862b24962c5673`, MIT. It matched the Avalon source nested in Depth; only one copy is kept.
- Zindex v1: `https://github.com/Underdog239/Zindex-v1`, commit `8e3a10e0d31dca583037c871e54342a28ed0cee5`. The repository has no license file; source is staged but not loaded. It is a virtual CPU/SoC architecture, not an emulator core for the catalog systems.
