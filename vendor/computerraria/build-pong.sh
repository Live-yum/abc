#!/bin/sh
set -eu

# Official Rust 1.85.1 + rust-std riscv32i-unknown-none-elf must already exist.
# Raw rustc uses precisely the upstream RISC-V modules without downloading the
# desktop-only terminal/graphics dependency graph. No upstream host build.rs
# needs to execute: the upstream linker file is passed explicitly below.
task_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
task_rustc="${COMPUTERRARIA_RUSTC:-rustc}"
task_build="$task_root/pong-build"
task_out="$task_build/output"
mkdir -p "$task_out"
"$task_rustc" +1.85.1 -vV > "$task_out/rustc-version.txt"
"$task_rustc" +1.85.1 --edition=2021 --crate-name tdriver --crate-type rlib \
  --target riscv32i-unknown-none-elf -C opt-level=3 -C panic=abort \
  -C overflow-checks=off -C lto=fat -C codegen-units=1 \
  "$task_build/app/tdriver/src/lib.rs" -o "$task_out/libtdriver.rlib"
"$task_rustc" +1.85.1 --edition=2021 --crate-name pong --crate-type bin \
  --target riscv32i-unknown-none-elf -C opt-level=3 -C panic=abort \
  -C overflow-checks=off -C lto=fat -C codegen-units=1 \
  -C link-arg=-T"$task_build/app/tdriver/link.x" \
  --extern tdriver="$task_out/libtdriver.rlib" \
  "$task_build/app/pong/src/main.rs" -o "$task_out/pong.elf"

python3 "$task_root/elf-to-rom.py" "$task_out/pong.elf"
