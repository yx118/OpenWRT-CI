#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY

set -euo pipefail

RUST_FEED="$PWD/feeds/packages/lang/rust"
RUST_MAKEFILE="$RUST_FEED/Makefile"
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPORT_DIR="${GITHUB_WORKSPACE:-$PWD}/build-reports"
mkdir -p "$REPORT_DIR"

# 不同源码树/feed 可能没有 rust 包（如某些精简分支），此时直接跳过，不影响固件构建
if [ ! -f "$RUST_MAKEFILE" ] || [ ! -f "$RUST_FEED/rust-values.mk" ]; then
	echo "rust feed not available, prebuilt Rust toolchain skipped" | tee -a "$REPORT_DIR/rust-toolchain.txt"
	exit 0
fi

# Ask the feed for its target triple so CI and OpenWrt use the same mapping.
if ! RUST_TARGET=$(make --no-print-directory -s -f - TOPDIR="$PWD" ci-rust-target 2>/dev/null <<'MAKE'
include $(TOPDIR)/rules.mk
include $(TOPDIR)/feeds/packages/lang/rust/rust-values.mk
.PHONY: ci-rust-target
ci-rust-target:
	@printf '%s\n' '$(RUSTC_TARGET_ARCH)'
MAKE
); then
	echo "rust feed does not expose RUSTC_TARGET_ARCH, prebuilt Rust toolchain skipped" | tee -a "$REPORT_DIR/rust-toolchain.txt"
	exit 0
fi
if [ -z "${RUST_TARGET//[[:space:]]/}" ]; then
	echo "empty Rust target triple, prebuilt Rust toolchain skipped" | tee -a "$REPORT_DIR/rust-toolchain.txt"
	exit 0
fi

RUSTUP_BIN=$(command -v rustup || true)
if [ -z "$RUSTUP_BIN" ]; then
	for candidate in "$HOME/.cargo/bin/rustup" /usr/bin/rustup; do
		if [ -x "$candidate" ]; then RUSTUP_BIN=$candidate; break; fi
	done
fi
if [ -z "$RUSTUP_BIN" ]; then
	echo "rustup is missing from the GitHub runner" >&2
	exit 1
fi
PATH="$(dirname "$RUSTUP_BIN"):$PATH"
export PATH
RUST_TOOLCHAIN=$(rustup show active-toolchain | awk '{print $1}')
printf 'Rust toolchain: %s\nRust target: %s\n' "$RUST_TOOLCHAIN" "$RUST_TARGET" | tee "$REPORT_DIR/rust-toolchain.txt"

rustup target add --toolchain "$RUST_TOOLCHAIN" "$RUST_TARGET"
RUST_ROOT=$(rustup run "$RUST_TOOLCHAIN" rustc --print sysroot)
test -d "$RUST_ROOT/lib/rustlib/$RUST_TARGET/lib"
for tool in cargo rustc rustdoc; do
	test -x "$RUST_ROOT/bin/$tool"
done

# Replace the source bootstrap before OpenWrt expands its host build rules.
{
	printf 'CI_RUST_ROOT:=%s\n' "$RUST_ROOT"
	cat "$SCRIPT_DIR/rust-prebuilt.mk"
} > "$RUST_FEED/ci-prebuilt.mk"

# HostBuild 锚点不存在时（feed 结构不同）只告警，回落到源码编译 Rust，不中断构建
if grep -q '^$(eval $(call HostBuild))$' "$RUST_MAKEFILE"; then
	# shellcheck disable=SC2016 # Match the literal Make expression.
	sed -i '/^include \.\/ci-prebuilt\.mk$/d; /^$(eval $(call HostBuild))$/i include ./ci-prebuilt.mk' "$RUST_MAKEFILE"
	if grep -Fxq 'include ./ci-prebuilt.mk' "$RUST_MAKEFILE"; then
		echo "prebuilt Rust toolchain injected"
	else
		echo "warning: failed to inject prebuilt Rust toolchain, falling back to source build"
	fi
else
	echo "warning: rust feed has no '$(eval $(call HostBuild))' anchor, falling back to source build"
fi

"$RUST_ROOT/bin/rustc" --version | tee -a "$REPORT_DIR/rust-toolchain.txt"
echo "Using runner Rust $RUST_TOOLCHAIN for $RUST_TARGET" | tee -a "$REPORT_DIR/rust-toolchain.txt"
sha256sum "$RUST_MAKEFILE" >> "$REPORT_DIR/rust-toolchain.txt"
