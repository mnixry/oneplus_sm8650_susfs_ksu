#!/usr/bin/env bash
set -xve

ANDROID_VERSION=${ANDROID_VERSION:-"android14"}
KERNEL_VERSION=${KERNEL_VERSION:-"6.1"}
CPUD=${CPUD:-"pineapple"}

function write_github_output() {
  local key=$1
  local value=$2
  if [ -f "$GITHUB_OUTPUT" ]; then
    echo "${key}=${value}" >> $GITHUB_OUTPUT
  fi
}

# Initialize repo and sync
rm -vf kernel_platform/common/android/abi_gki_protected_exports_* || echo "No protected exports!"
rm -vf kernel_platform/msm-kernel/android/abi_gki_protected_exports_* || echo "No protected exports!"
sed -i 's/ -dirty//g' kernel_platform/build/kernel/kleaf/workspace_status_stamp.py

# Set up MKSU
(
  cd kernel_platform
  bash <(curl -LSs https://github.com/tiann/KernelSU/raw/refs/heads/main/kernel/setup.sh)
  (
    cd KernelSU
    ksu_version=$(expr $(/usr/bin/git rev-list --count HEAD) "+" 10200)
    sed -i "s/DKSU_VERSION=16/DKSU_VERSION=${ksu_version}/" kernel/Makefile
    write_github_output "ksu_version" "${ksu_version}"
  )
)

# Set up SuSFS
git clone https://gitlab.com/simonpunk/susfs4ksu.git -b gki-${ANDROID_VERSION}-${KERNEL_VERSION} --depth 1
write_github_output "susfs_version" $(cat susfs4ksu/ksu_module_susfs/module.prop | sed -n '/version=/ {s/.*=//; p}')
(
  cd kernel_platform/KernelSU
  patch -p1 --forward < ../../susfs4ksu/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch || true
)
(
  cd kernel_platform/common
  patch -p1 --forward < ../../susfs4ksu/kernel_patches/50_add_susfs_in_gki-${ANDROID_VERSION}-${KERNEL_VERSION}.patch || true
  cp -rv ../../susfs4ksu/kernel_patches/fs/* ./fs/
  cp -rv ../../susfs4ksu/kernel_patches/include/linux/* ./include/linux/
)

# Set up extra patches for OnePlus devices
git clone https://github.com/TanakaLun/kernel_patches4mksu --depth 1
(
  cd kernel_platform/common
  patch -p1 --forward < ../../kernel_patches4mksu/oneplus/001-lz4.patch || true
  patch -p1 --forward < ../../kernel_patches4mksu/oneplus/002-zstd.patch || true
  patch -p1 --forward < ../../kernel_patches4mksu/69_hide_stuff.patch
)

# Build kernel
./kernel_platform/build_with_bazel.py -t "${CPUD}" gki

# Make AnyKernel3
git clone https://github.com/Kernel-SU/AnyKernel3 --depth=1
rm -rf ./AnyKernel3/.git
cp "kernel_platform/out/msm-kernel-${CPUD}-gki/dist/Image" ./AnyKernel3/

write_github_output "kernel_version" $(strings ./AnyKernel3/Image | sed -n 's/.*Linux version \([^ ]*\).*/\1/p' | uniq)
