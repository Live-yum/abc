# Computerraria Pong source and ROM

This directory retains the MIT-licensed source, patched RISC-V build copy,
compiled RV32I program and provenance for TerraForge's bundled Pong button.
See `LICENSE` and `pong-provenance.json` for ownership and exact source hashes.
`upstream/` is unmodified; `pong-build-fix.patch` documents the two host-only
conditional-compilation guards applied to `pong-build/app/tdriver`.

Run `sh vendor/computerraria/build-pong.sh` from the repository root with official
Rust 1.85.1 and the `riscv32i-unknown-none-elf` target already installed. The build
uses the existing rustup shim on PATH (override with `COMPUTERRARIA_RUSTC`) and
does not download tools. `elf-to-rom.py` extracts the physical load image. The
expected 2,288-byte ROM hash is
`d2a7d5a26eb168a55c80ae60b32205957d8f2ae215cbdce7c5d50acc2049946d`.

CPU startup must begin at hardware PC 0, even though ELF e_entry is 8. This folder
contains no host CPU emulator and no Terraria/WireHead executable or world file.
See [the application workflow](../../docs/COMPUTERRARIA.md) for the verified
physical layout, display representation and runtime/profile evidence boundaries.
