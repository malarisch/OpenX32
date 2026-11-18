#!/bin/bash
OPENX32_DIR="$(cd "$(dirname "$0")" && pwd)"

# general tools to compile linux, busybox, u-Boot and the x32ctrl software
# ========================================================================
echo "This script will setup a Debian-based environment to allow compilation of the necessary components..."
echo "Installing packages..."
sudo apt update
sudo apt install libncurses-dev gawk flex bison openssl libssl-dev dkms libelf-dev libudev-dev libpci-dev libiberty-dev autoconf llvm fakeroot build-essential devscripts gcc-arm-none-eabi binutils-arm-none-eabi gcc-arm-linux-gnueabi g++-arm-linux-gnueabi binutils-arm-linux-gnueabi u-boot-tools bc cpio dropbear-bin python3 curl

# Rust toolchain for the AES67 control plane (aes67d, aes67cfg, aes67web)
# ARMv5TE (i.MX25 / ARM926EJ-S) targets for musl (default) and glibc (--glibc)
if ! command -v rustup >/dev/null; then
	curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
	. "$HOME/.cargo/env"
fi
rustup target add armv5te-unknown-linux-musleabi armv5te-unknown-linux-gnueabi

# extract toolchain to directory /opt/cross
sudo tar -xf toolchains/cross-arm-arm926ej.tar.xz -C /

# download, compile and install libz into /opt/cross
cd /tmp
wget https://github.com/madler/zlib/releases/download/v1.3.2/zlib-1.3.2.tar.gz
tar -xf zlib-1.3.2.tar.gz
rm zlib-1.3.2.tar.gz
cd zlib-1.3.2
export PATH=/opt/cross/bin:$PATH
export CHOST=arm-openwrt-linux-muslgnueabi
export CC=${CHOST}-gcc
export AR=${CHOST}-ar
export RANLIB=${CHOST}-ranlib
# install in the toolchain-folder
./configure --prefix=/opt/cross/arm-openwrt-linux-muslgnueabi --shared
make
sudo make install




# install individual libraries for some tools
# ========================================================================
#echo "Installing libraries for ARM..."
sudo dpkg --add-architecture armel
sudo apt update

# libz required for vnc-server
# libudev required for automount and usb-DMX512-interfaces
sudo apt install zlib1g-dev:armel libz-dev:armel libudev-dev:armel

# libasound2 required for audio-output
#sudo apt install libasound2:armel



# install Python 3 and pyATK to upload code to the i.MX25 via the USB connection
# ==============================================================================
echo "Configuring pyATK..."
sudo apt install -y python3 python3-venv libusb-1.0-0
cd "$OPENX32_DIR"
cp files/usbdev.py software/pyatk/pyatk/channel/
cp files/boot.py software/pyatk/pyatk/
cp files/meminit.txt software/pyatk/bin/
python3 -m venv software/pyatk/pyatk_venv
software/pyatk/pyatk_venv/bin/pip install pyserial pyusb==1.0.0 setuptools
software/pyatk/pyatk_venv/bin/pip install ./software/pyatk

# Python environment (LiteX) to generate the register maps of the FPGA gateware
# (fpga/build.sh litex, called by compile.sh)
# ==============================================================================
fpga/litex_soc/setup_venv.sh
