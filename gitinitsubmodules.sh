#!/bin/bash

echo "Preparing checkout of u-boot v2020.10 without history..."
git clone --depth 1 --single-branch --branch v2020.10 https://github.com/u-boot/u-boot.git

echo "Preparing checkout of linux v6.18 LTS without history..."
rm -rf linux
mkdir -p linux
git clone --depth 1 --single-branch --branch v6.18.25 https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git
cd linux
patch -p1 < ../files/kernel_patches/901-debloat_sock_diag.patch
patch -p1 < ../files/kernel_patches/902-debloat_proc.patch
patch -p1 < ../files/kernel_patches/904-debloat_dma_buf.patch
cd ..

git clone --depth 1 --single-branch https://git.busybox.net/busybox software/busybox
git clone --depth 1 --single-branch https://github.com/mkj/dropbear.git software/dropbear
git clone --depth 1 --single-branch https://github.com/ponty/framebuffer-vncserver.git software/framebuffer-vncserver
git clone --depth 1 --single-branch https://github.com/LibVNC/libvncserver.git software/libvncserver
git clone --depth 1 --single-branch https://github.com/OpenLightingProject/libartnet.git software/libartnet

git clone -b development --depth 1 --single-branch https://github.com/malarisch/OpenMixerControl.git software/omc

# pyATK: upload to the i.MX25 via USB serial download (usb_boot.sh); set up by setup.sh
rm -rf software/pyatk
git clone https://github.com/hbock/pyatk.git software/pyatk
git -C software/pyatk checkout bd124dbbc2efac94e5b69caffe50e31fee402b78

# OpenAudioFPGA (submodule fpga/): FPGA gateware and the spibone kernel driver
# (FPGA control bus, files/spibone/build.sh)
git submodule update --init fpga

# AES67 (submodule of OpenAudioFPGA): kernel driver + Rust control plane (aes67d/aes67cfg/aes67web)
git -C fpga submodule update --init ext/AES67

# LinuxPTP (ptp4l)
git clone --depth 1 --single-branch --branch v4.4 https://github.com/richardcochran/linuxptp.git software/linuxptp

echo "Done."
