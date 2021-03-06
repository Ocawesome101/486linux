#!/bin/bash
# Set up a 486 Linux image
# Procedure:
# 1. Download source files
# 2. Build kernel
# 3. Build musl-cross-make
# 4. Build busybox
# 5. Assemble image

set -e

confbase=$PWD

# colors used
red="\e[91m"
green="\e[92m"
yellow="\e[93m"
blue="\e[94m"
white="\e[97m"
res="\e[39;49m"

LINUX_VERSION=${LINUX_VERSION:-"5.14.8"}
BUSYBOX_VERSION=${BUSYBOX_VERSION:-"1.35.0"}

basedir=${BASE_DIR:-"$HOME/.486linux"}

kernel_dirname="linux-$LINUX_VERSION"
kernel_tarfile="$kernel_dirname.tar.xz"
kernel_url="https://mirrors.edge.kernel.org/pub/linux/kernel/v5.x/$kernel_tarfile"

busybox_dirname="busybox-$BUSYBOX_VERSION"
busybox_tarfile="$busybox_dirname.tar.bz2"
busybox_url="https://busybox.net/downloads/$busybox_tarfile"

muslcrossmake="https://github.com/richfelker/musl-cross-make"

printf \
  "$yellow==>$white$green FourEightySix Linux Setup Script $yellow<==$res\n"

check () {
  printf "$blue=>$white Checking required utilities... \n"
  oargn="$#"
  while [ "$#" -gt 0 ]; do
    printf "  $blue-$white Checking for$yellow $1$white ....\t"
    local found=$(command -v "$1")
    if ! [ "$found" ]; then
      printf "${red}not found$res\n"
      printf "${red}Could not find a required utility$res\n"
      exit 1
    fi
    export $1=$found
    printf "${green}found$white: $yellow$found$res\n"
    shift
  done
  # mildly cursed but it does work
  oargn=$(($oargn+1))
  printf "\e[${oargn}A$blue=>$white Checking required utilities...$green done$res\e[${oargn}B\e[G"
}

check syslinux gcc make curl sfdisk bash git patch tar unxz sudo \
  strip dd mkfs partprobe

mkdir -p $basedir
cd $basedir

printf "$blue=>$white Making sure you have the source code$res\n"

if ! [ -e "$basedir/$kernel_tarfile" ]; then
  printf "  $blue-$white Downloading source code:$yellow Linux$res\n"
  $curl --progress-bar "$kernel_url" > "$basedir/$kernel_tarfile"
fi

if ! [ -e "$basedir/$kernel_dirname" ]; then
  printf "  $blue-$white Extracting source code:$yellow Linux$res\n"
  $tar Jxf "$kernel_tarfile"
fi

if ! [ -e "$basedir/$busybox_tarfile" ]; then
  printf "  $blue-$white Downloading source code:$yellow BusyBox$res\n"
  $curl --progress-bar "$busybox_url" > "$basedir/$busybox_tarfile"
fi

if ! [ -e "$basedir/$busybox_dirname" ]; then
  printf "  $blue-$white Extracting source code:$yellow BusyBox$res\n"
  $tar jxf "$busybox_tarfile"
fi

if ! [ -d "$basedir/muslcrossmake" ]; then
  printf "$blue=>$white Downloading source code:$yellow musl-cross-make$res\n"
  $git clone "$muslcrossmake" "$basedir/muslcrossmake"
fi

printf "$blue=>$white Copying configuration files\n"
cp "$confbase/linux-config" "$basedir/$kernel_dirname/.config"
cp "$confbase/busybox-config" "$basedir/$busybox_dirname/.config"
cp "$confbase/musl-cross-make-config" "$basedir/muslcrossmake/config.mak"

if ! [ -e "$basedir/$kernel_dirname/arch/x86/boot/bzImage" ]; then
  printf "$blue=>$white Compiling$yellow Linux$res\n"
  cd "$basedir/$kernel_dirname"
  $make -j$(nproc)
fi

if ! [ $(command -v i486-linux-musl-gcc) ]; then
  printf "$blue=>$white Compiling$yellow musl-cross-make$res\n"
  cd "$basedir/muslcrossmake"
  $make
  printf "$blue=>$white Installing$yellow musl-cross-make$res\n"
  $sudo $make install
fi

if ! [ $(echo $PATH | grep /usr/local/bin) ]; then
  printf "$blue=>$white Adding$yellow /usr/local/bin$white to your$green PATH$res\n"
  export PATH="$PATH:/usr/local/bin"
fi

if ! [ -e "$basedir/$busybox_dirname/busybox" ]; then
  printf "$blue=>$white Compiling$yellow BusyBox$res\n"
  cd "$basedir/$busybox_dirname"
  printf "$blue=>$white Patching$yellow include/libbb.h$white\n"
  patch -R include/libbb.h <"$confbase/libbb.h.patch"
  $make
fi

printf "$blue=>$white Assembling final image\n"
cd "$basedir"
$dd if=/dev/zero of=486linux.img bs=1M count=128 conv=notrunc,sync oflag=direct

printf "  $blue-$white Setting up$yellow boot$white partition$res\n"
device="$($sudo losetup -f)"
cat $confbase/sfdisk-layout | $sfdisk "$basedir/486linux.img"
$sudo losetup -P $device 486linux.img
$sudo $mkfs -t fat -F 12 ${device}p1
$sudo $mkfs -t ext2 ${device}p2
$sudo syslinux -i ${device}p1
$sudo sync
$sudo $dd if=/usr/lib/syslinux/bios/mbr.bin of=${device} bs=440 count=1 \
  conv=notrunc
$sudo mount ${device}p1 /mnt
$sudo cp $confbase/syslinux.cfg /mnt/
$sudo cp $basedir/$kernel_dirname/arch/x86/boot/bzImage /mnt/linux
$sudo umount /mnt

printf "  $blue-$white Setting up$yellow root$white partition$res\n"
$sudo mount ${device}p2 /mnt
$sudo mkdir /mnt/{bin,dev,proc,sys,root,etc} /mnt/etc/init.d
$sudo cp $basedir/$busybox_dirname/busybox /mnt/bin/busybox
cd /mnt/bin
$sudo ./busybox --install /mnt/bin
cd -
$sudo ln -s /mnt/bin /mnt/sbin

$sudo cp $confbase/inittab /mnt/etc/inittab
$sudo cp $confbase/initrc /mnt/etc/init.d/rc
$sudo cp $confbase/{passwd,group,welcome} /mnt/etc/

$sudo umount /mnt
sleep 0.5
$sudo losetup -d $device

printf "$blue=>$white The finished image is available at $yellow$basedir/486linux.img$res\n"
