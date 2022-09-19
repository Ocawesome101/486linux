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

if [ "$#" = 0 ] || ! [ -e "$1" ]; then
  printf "usage: $(basename $0) DEVICE\n" 1>&2
  exit 1
fi

printf "$red=>$yellow REALLY erase $green$1$yellow? This operation cannot be undone!$white "

while true; do
  printf "[y/N]: "
  read;
  case "$REPLY" in
    [yY])
      break
      ;;
    [nN])
      exit 0
      ;;
    "")
      exit 0
      ;;
  esac
done

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
    export $(echo $1 | sed 's/-/_/g')=$found
    printf "${green}found$white: $yellow$found$res\n"
    shift
  done
  # mildly cursed but it does work
  oargn=$(($oargn+1))
  printf "\e[${oargn}A$blue=>$white Checking required utilities...$green done$res\e[${oargn}B\e[G"
}

check syslinux gcc-11 make curl sfdisk bash git patch tar unxz sudo \
  strip dd mkfs partprobe

gcc=${gcc_11}

mkdir -p $basedir
cd $basedir

printf "$blue=>$white Making sure you have the source code$res\n"

if ! [ -e "$basedir/$kernel_tarfile" ]; then
  printf "  $blue-$white Downloading source code:$yellow Linux$res\n"
  $curl --progress-bar "$kernel_url" > "$basedir/$kernel_tarfile"
else
  printf "  $blue-$white Source tarball present:$yellow Linux$res\n"
fi

if ! [ -e "$basedir/$kernel_dirname" ]; then
  printf "  $blue-$white Extracting source code:$yellow Linux$res\n"
  $tar Jxf "$kernel_tarfile"
fi

if ! [ -e "$basedir/$busybox_tarfile" ]; then
  printf "  $blue-$white Downloading source code:$yellow BusyBox$res\n"
  $curl --progress-bar "$busybox_url" > "$basedir/$busybox_tarfile"
else
  printf "  $blue-$white Source tarball present:$yellow BusyBox$res\n"
fi

if ! [ -e "$basedir/$busybox_dirname" ]; then
  printf "  $blue-$white Extracting source code:$yellow BusyBox$res\n"
  $tar jxf "$busybox_tarfile"
fi

if ! [ -d "$basedir/muslcrossmake" ]; then
  printf "$blue=>$white Downloading source code:$yellow musl-cross-make$res\n"
  $git clone "$muslcrossmake" "$basedir/muslcrossmake"
  cd "$basedir/muslcrossmake"
  $git checkout 0f22991b8d47837ef8dd60a0c43cf40fcf76217a
  cd -
else
  printf "  $blue-$white Source repository present:$yellow Linux$res\n"
fi

printf "$blue=>$white Copying configuration files\n"
cp "$confbase/linux-config" "$basedir/$kernel_dirname/.config"
cp "$confbase/busybox-config" "$basedir/$busybox_dirname/.config"
cp "$confbase/musl-cross-make-config" "$basedir/muslcrossmake/config.mak"

if ! [ -e "$basedir/$kernel_dirname/arch/x86/boot/bzImage" ]; then
  printf "$blue=>$white Compiling$yellow Linux$res\n"
  cd "$basedir/$kernel_dirname"
  $make -j$(nproc)
else
  printf "  $blue-$white Skipping build:$yellow Linux$res\n"
fi

if ! [ $(echo $PATH | grep /usr/local/bin) ]; then
  printf "$blue=>$white Adding$yellow /usr/local/bin$white to your$green PATH$res\n"
  export PATH="$PATH:/usr/local/bin"
fi

if ! [ $(command -v i486-linux-musl-gcc) ]; then
  printf "$blue=>$white Compiling$yellow musl-cross-make$res\n"
  cd "$basedir/muslcrossmake"
  $make
  printf "$blue=>$white Installing$yellow musl-cross-make$res\n"
  $sudo $make install
else
  printf "  $blue-$yellow i486-linux-musl-gcc$white found - Skipping build:$yellow musl-cross-make$res\n"
fi

if ! [ -e "$basedir/$busybox_dirname/busybox" ]; then
  printf "$blue=>$white Compiling$yellow BusyBox$res\n"
  cd "$basedir/$busybox_dirname"
  printf "$blue=>$white Patching$yellow include/libbb.h$white\n"
  patch -R include/libbb.h <"$confbase/libbb.h.patch"
  $make
else
  printf "  $blue-$white Skipping build:$yellow BusyBox$res\n"
fi

printf "$blue=>$white Assembling final image\n"
cd "$basedir"
device="$1"
printf "  $blue-$red ERASING$yellow $device$red PERMANENTLY IN 5 SECONDS$res\n"
sleep 5
$sudo $dd if=/dev/zero of="$device" bs=1M count=128 conv=notrunc,sync oflag=direct status=progress

printf "  $blue-$white Setting up$yellow boot$white partition$res\n"
cat $confbase/sfdisk-layout | $sudo $sfdisk $device

partprefix=""
if [ -e "${device}p1" ]; then
  partprefix="p"
fi

$sudo $mkfs -t fat -F 12 ${device}${partprefix}1
$sudo $mkfs -t ext2 ${device}${partprefix}2
$sudo syslinux -i ${device}${partprefix}1
$sudo sync
$sudo $dd if=/usr/lib/syslinux/bios/mbr.bin of=${device} bs=440 count=1 \
  conv=notrunc
$sudo mount ${device}${partprefix}1 /mnt
$sudo cp $confbase/syslinux.cfg /mnt/
$sudo cp $basedir/$kernel_dirname/arch/x86/boot/bzImage /mnt/linux
$sudo umount /mnt

printf "  $blue-$white Setting up$yellow root$white partition$res\n"
$sudo mount ${device}${partprefix}2 /mnt
$sudo mkdir /mnt/{bin,dev,proc,sys,root,etc} /mnt/etc/init.d
$sudo cp $basedir/$busybox_dirname/busybox /mnt/bin/busybox
$sudo mknod /mnt/dev/tty1 c 4 1
$sudo mknod /mnt/dev/console c 5 1
$sudo mknod /mnt/dev/null c 1 3
cd /mnt/bin
$sudo ./busybox --install /mnt/bin
cd -
$sudo ln -s /mnt/bin /mnt/sbin

$sudo cp $confbase/inittab /mnt/etc/inittab
$sudo cp $confbase/initrc /mnt/etc/init.d/rc
$sudo cp $confbase/{passwd,group,welcome} /mnt/etc/

$sudo umount /mnt

printf "$blue=>$white Setup of $yellow$device$white complete.$res\n"
