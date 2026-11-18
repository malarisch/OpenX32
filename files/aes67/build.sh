#!/bin/bash
# AES67 integration for OpenX32.
#
# Builds the parts of the AES67 project (https://github.com/malarisch/AES67)
# that run on the X32's i.MX25:
#   - the aes67_eth driver (netdev + PTP hardware clock), a client of the
#     spibone bus driver (owner of the FPGA control bus on SPI3 CS0, from
#     OpenAudioFPGA, prepared by files/spibone/build.sh before this), built into
#     the kernel because the OpenX32 kernel has no module support
#   - LinuxPTP (ptp4l, pmc, phc_ctl) to discipline the FPGA wallclock
#   - the Rust control plane from config_tool (aes67d, aes67cfg, aes67web)
#
# Usage (called from compile.sh, run from the OpenX32 root):
#   files/aes67/build.sh kernel      copy the aes67_eth driver into the linux tree
#   files/aes67/build.sh userspace   build LinuxPTP and the Rust tools
#   files/aes67/build.sh install     copy binaries and config into initramfs_root
#
# Environment:
#   AES67_DIR     AES67 project checkout     (default: software/aes67)
#   LINUXPTP_DIR  LinuxPTP checkout          (default: software/linuxptp)
#   AES67_CSR     csr.csv of the AES67 gateware loaded on the X32
#                 (default: the bridge build of AES67_DIR, the map the gateware was
#                 built with: litex_soc/build/aes67_bridge_lattice/csr.csv; only if
#                 that does not exist (fresh checkout, build/ is not in git) the
#                 snapshot files/aes67/csr.csv, which may be stale)
#   LINUX_DIR     kernel tree                (default: linux)
#   COMPILE_MUSL  true = musl toolchain from /opt/cross (default), false = glibc
#   COPTS         C compiler flags for the target (set by compile.sh)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AES67_DIR="${AES67_DIR:-$ROOT/software/aes67}"
LINUXPTP_DIR="${LINUXPTP_DIR:-$ROOT/software/linuxptp}"
AES67_CSR_BUILD="$AES67_DIR/litex_soc/build/aes67_bridge_lattice/csr.csv"
AES67_CSR_SNAPSHOT="$ROOT/files/aes67/csr.csv"
if [ -z "${AES67_CSR:-}" ]; then
	if [ -f "$AES67_CSR_BUILD" ]; then
		AES67_CSR="$AES67_CSR_BUILD"
	else
		AES67_CSR="$AES67_CSR_SNAPSHOT"
	fi
fi
LINUX_DIR="${LINUX_DIR:-$ROOT/linux}"
COMPILE_MUSL="${COMPILE_MUSL:-true}"
COPTS="${COPTS:--mcpu=arm926ej-s -Os}"
CROSS_COMPILE="${CROSS_COMPILE:-arm-linux-gnueabi-}"
BUILD_DIR="$ROOT/build/aes67"

if [ "$COMPILE_MUSL" = true ]; then
	RUST_TARGET=armv5te-unknown-linux-musleabi
else
	RUST_TARGET=armv5te-unknown-linux-gnueabi
fi
CARGO_TARGET_DIR="$BUILD_DIR/cargo"
RUST_BINS="aes67d aes67cfg aes67web"
PTP_BINS="ptp4l pmc phc_ctl"

die() {
	echo "aes67: $*" >&2
	exit 1
}

# Copy only when the content changed, so make does not rebuild needlessly.
copy_if_changed() {
	if ! cmp -s "$1" "$2"; then
		cp "$1" "$2"
	fi
}

need_aes67() {
	[ -d "$AES67_DIR/driver/aes67_eth" ] && [ -d "$AES67_DIR/config_tool" ] ||
		die "AES67 sources not found in $AES67_DIR (run gitinitsubmodules.sh or set AES67_DIR)"
	[ -f "$AES67_CSR" ] || die "csr.csv not found: $AES67_CSR"
	if [ "$AES67_CSR" = "$AES67_CSR_SNAPSHOT" ]; then
		echo "aes67: WARNING: no AES67 bridge build ($AES67_CSR_BUILD)," >&2
		echo "aes67: WARNING: using the snapshot $AES67_CSR_SNAPSHOT — if it does not match the" >&2
		echo "aes67: WARNING: gateware, aes67_eth fails to probe (CSR map mismatch)" >&2
	fi
	echo "aes67: CSR map $AES67_CSR"
}

# --------------------------------------------------------------------------
# Kernel driver: drivers/net/ethernet/aes67 (CONFIG_AES67_ETH), on top of
# drivers/misc/spibone (CONFIG_SPIBONE, files/spibone/build.sh)
# --------------------------------------------------------------------------
do_kernel() {
	need_aes67
	[ -f "$LINUX_DIR/drivers/misc/spibone/spibone.h" ] ||
		die "spibone bus driver missing in $LINUX_DIR/drivers/misc/spibone (run files/spibone/build.sh first)"

	local src="$AES67_DIR/driver/aes67_eth"
	local dst="$LINUX_DIR/drivers/net/ethernet/aes67"
	local eth="$LINUX_DIR/drivers/net/ethernet"

	mkdir -p "$dst"
	for f in "$src"/*.c "$src"/*.h; do
		case "$(basename "$f")" in
			*.mod.c|aes67_regs.h) continue ;; # build artefact / generated below
		esac
		copy_if_changed "$f" "$dst/$(basename "$f")"
	done
	# no longer part of the driver (the bus driver has the userspace ABI), and the
	# client API of the bus driver comes from drivers/misc/spibone (Kbuild -I)
	rm -f "$dst/aes67_uapi.h" "$dst/spibone.h"
	copy_if_changed "$ROOT/files/aes67/Kconfig" "$dst/Kconfig"
	copy_if_changed "$ROOT/files/aes67/Kbuild" "$dst/Kbuild"

	# Register addresses come from the gateware's csr.csv, never hard-coded.
	mkdir -p "$BUILD_DIR"
	python3 "$src/gen_regs.py" "$AES67_CSR" > "$BUILD_DIR/aes67_regs.h"
	copy_if_changed "$BUILD_DIR/aes67_regs.h" "$dst/aes67_regs.h"

	# Hook the driver into the ethernet Kconfig/Makefile (idempotent).
	if ! grep -q 'drivers/net/ethernet/aes67/Kconfig' "$eth/Kconfig"; then
		sed -i 's|^endif # ETHERNET|source "drivers/net/ethernet/aes67/Kconfig"\n\nendif # ETHERNET|' "$eth/Kconfig"
		grep -q 'drivers/net/ethernet/aes67/Kconfig' "$eth/Kconfig" ||
			die "could not hook aes67 into $eth/Kconfig"
	fi
	if ! grep -q 'CONFIG_AES67_ETH' "$eth/Makefile"; then
		echo 'obj-$(CONFIG_AES67_ETH) += aes67/' >> "$eth/Makefile"
	fi
	echo "aes67: kernel driver prepared in $dst"
}

# --------------------------------------------------------------------------
# LinuxPTP
# --------------------------------------------------------------------------
build_linuxptp() {
	[ -f "$LINUXPTP_DIR/makefile" ] ||
		die "LinuxPTP not found in $LINUXPTP_DIR (run gitinitsubmodules.sh or set LINUXPTP_DIR)"

	# LinuxPTP's incdefs.sh probes kernel headers under $KBUILD_OUTPUT/usr/include
	# (falling back to the build host's headers). Point it at the toolchain's
	# own linux headers so feature detection matches what we compile against.
	local hdr incdir
	# (awk reads all input: an early-exiting grep would SIGPIPE gcc under pipefail)
	hdr=$(echo '#include <linux/net_tstamp.h>' |
		"${CROSS_COMPILE}gcc" -E -H -x c - 2>&1 >/dev/null |
		awk '/linux\/net_tstamp\.h$/ && !found { sub(/^\.+ +/, ""); print; found = 1 }')
	[ -f "$hdr" ] || die "toolchain has no linux/net_tstamp.h"
	incdir=$(cd "$(dirname "$hdr")/.." && pwd)
	mkdir -p "$BUILD_DIR/linuxptp-khdr/usr"
	ln -sfn "$incdir" "$BUILD_DIR/linuxptp-khdr/usr/include"

	# -DHAVE_CLOCK_ADJTIME: incdefs.sh misses it when the toolchain's include
	# directory is reached through a symlink (OpenWrt musl toolchain); both
	# musl and glibc provide clock_adjtime().
	make -C "$LINUXPTP_DIR" -j"$(nproc)" \
		CROSS_COMPILE="$CROSS_COMPILE" \
		KBUILD_OUTPUT="$BUILD_DIR/linuxptp-khdr" \
		EXTRA_CFLAGS="$COPTS -DHAVE_CLOCK_ADJTIME" \
		$PTP_BINS
}

# --------------------------------------------------------------------------
# Rust control plane (config_tool)
# --------------------------------------------------------------------------
build_rust() {
	command -v cargo >/dev/null ||
		die "cargo not found - install Rust (https://rustup.rs) and run: rustup target add $RUST_TARGET"
	if command -v rustup >/dev/null && ! rustup target list --installed | grep -qx "$RUST_TARGET"; then
		rustup target add "$RUST_TARGET"
	fi

	local manifest="$AES67_DIR/config_tool/Cargo.toml"
	local locked=""
	[ -f "$AES67_DIR/config_tool/Cargo.lock" ] && locked="--locked"

	# Linker = the same C cross compiler as the rest of OpenX32. The musl
	# target links statically (Rust's bundled musl), so the binaries do not
	# depend on the musl version in /opt/cross. Optimise for size: the
	# binaries end up in the initramfs.
	local linker_var
	linker_var="CARGO_TARGET_$(echo "$RUST_TARGET" | tr 'a-z-' 'A-Z_')_LINKER"
	env "$linker_var=${CROSS_COMPILE}gcc" \
		CARGO_TARGET_DIR="$CARGO_TARGET_DIR" \
		CARGO_PROFILE_RELEASE_OPT_LEVEL=z \
		CARGO_PROFILE_RELEASE_LTO=fat \
		CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1 \
		CARGO_PROFILE_RELEASE_PANIC=abort \
		CARGO_PROFILE_RELEASE_STRIP=symbols \
		cargo build --release $locked \
			--manifest-path "$manifest" \
			--target "$RUST_TARGET" \
			$(for b in $RUST_BINS; do printf -- '--bin %s ' "$b"; done)
}

do_userspace() {
	need_aes67
	mkdir -p "$BUILD_DIR"
	build_linuxptp
	build_rust
}

# --------------------------------------------------------------------------
# Install into the initramfs
# --------------------------------------------------------------------------
do_install() {
	need_aes67
	local fs="$ROOT/initramfs_root"
	mkdir -p "$fs/openx32" "$fs/etc/aes67"

	for b in $RUST_BINS; do
		cp "$CARGO_TARGET_DIR/$RUST_TARGET/release/$b" "$fs/openx32/"
	done
	for b in $PTP_BINS; do
		cp "$LINUXPTP_DIR/$b" "$fs/openx32/"
	done
	# Register map for aes67d/aes67cfg; must match the kernel's aes67_regs.h.
	cp "$AES67_CSR" "$fs/etc/aes67/csr.csv"
	echo "aes67: installed into $fs"
}

case "${1:-}" in
	kernel)    do_kernel ;;
	userspace) do_userspace ;;
	install)   do_install ;;
	*)
		echo "usage: $0 {kernel|userspace|install}" >&2
		exit 2
		;;
esac
