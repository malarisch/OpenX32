#!/bin/bash
# LiteX SPIBone bus driver for OpenX32: the owner of the FPGA control bus on SPI3
# CS0 (/dev/spibone0, FPGA configuration, client devices such as the AES67 core).
# The sources come from OpenAudioFPGA (driver/spibone); they are copied into
# drivers/misc/spibone of the kernel tree and built in (CONFIG_SPIBONE=y), because
# the OpenX32 kernel has no module support. Needed by every build, with or
# without AES67.
#
# Usage (called from compile.sh, run from the OpenX32 root or the linux tree):
#   files/spibone/build.sh
#
# Environment:
#   OPENAUDIOFPGA_DIR  OpenAudioFPGA checkout (default: the submodule fpga/;
#                      e.g. ../OpenAudioFPGA to build against a working copy)
#   LINUX_DIR          kernel tree            (default: linux)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LINUX_DIR="${LINUX_DIR:-$ROOT/linux}"

die() {
	echo "spibone: $*" >&2
	exit 1
}

copy_if_changed() {
	if ! cmp -s "$1" "$2"; then
		cp "$1" "$2"
	fi
}

OPENAUDIOFPGA_DIR="${OPENAUDIOFPGA_DIR:-$ROOT/fpga}"

src="$OPENAUDIOFPGA_DIR/driver/spibone"
dst="$LINUX_DIR/drivers/misc/spibone"
misc="$LINUX_DIR/drivers/misc"

[ -f "$src/spibone.c" ] ||
	die "spibone driver not found in $src (git submodule update --init fpga, or set OPENAUDIOFPGA_DIR)"

mkdir -p "$dst"
for f in spibone.c spibone.h spibone_uapi.h; do
	copy_if_changed "$src/$f" "$dst/$f"
done
copy_if_changed "$ROOT/files/spibone/Kconfig" "$dst/Kconfig"
copy_if_changed "$ROOT/files/spibone/Kbuild" "$dst/Kbuild"

# Hook the driver into the misc Kconfig/Makefile (idempotent).
if ! grep -q 'drivers/misc/spibone/Kconfig' "$misc/Kconfig"; then
	sed -i 's|^endmenu|source "drivers/misc/spibone/Kconfig"\n\nendmenu|' "$misc/Kconfig"
	grep -q 'drivers/misc/spibone/Kconfig' "$misc/Kconfig" ||
		die "could not hook spibone into $misc/Kconfig"
fi
if ! grep -q 'CONFIG_SPIBONE' "$misc/Makefile"; then
	echo 'obj-$(CONFIG_SPIBONE) += spibone/' >> "$misc/Makefile"
fi
echo "spibone: bus driver prepared in $dst (from $src)"
