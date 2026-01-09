#!/usr/bin/env bash
set -xve

KSU_VARIANT=${KSU_VARIANT:-"ksu"}
ENABLE_SUSFS=${ENABLE_SUSFS:-"yes"}

ANDROID_VERSION=${ANDROID_VERSION:-"android14"}
KERNEL_VERSION=${KERNEL_VERSION:-"6.1"}
CPUD=${CPUD:-"pineapple"}

if [ ! -f "kernel_platform/common/Makefile" ]; then
  echo "Kernel source not found!"
  exit 1
fi

function write_github_output() {
  local key=$1
  local value=$2
  if [ -f "$GITHUB_OUTPUT" ]; then
    echo "${key}=${value}" >> $GITHUB_OUTPUT
  fi
}

function write_gki_config() {
  (
    cd kernel_platform/common
    for config in $@; do
      echo "CONFIG_${config}" >> ./arch/arm64/configs/gki_defconfig
    done
  )
}

function setup_kernelsu() {
  local ksu_repo=${1:-"tiann/KernelSU"}
  local ksu_branch=${2:-"main"}
  local version_offset=${3:-30000}
  local version_branch=${4:-"HEAD"}
  (
    cd kernel_platform
    git clone https://github.com/${ksu_repo}.git ./KernelSU
    ./KernelSU/kernel/setup.sh "${ksu_branch}"
    (
      cd KernelSU
      ksu_version=$(expr $(/usr/bin/git rev-list --count "${version_branch}") "+" ${version_offset})
      sed -i "s/DKSU_VERSION=[^[:space:]]\+/DKSU_VERSION=${ksu_version}/" kernel/Kbuild
      grep "KSU_VERSION=${ksu_version}" kernel/Kbuild
      write_github_output "ksu_version" "${ksu_version}"
    )
  )
  write_gki_config KSU=y
}

function setup_susfs() {
  local patch_ksu=${1:-"yes"}
  git clone https://gitlab.com/simonpunk/susfs4ksu.git -b gki-${ANDROID_VERSION}-${KERNEL_VERSION} --depth 1
  write_github_output "susfs_version" $(cat susfs4ksu/ksu_module_susfs/module.prop | sed -n '/version=/ {s/.*=//; p}')
  if [ "${patch_ksu}" == "yes" ]; then
    (
      cd kernel_platform/KernelSU
      patch -p1 --fuzz=3 < ../../susfs4ksu/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch || true
    )
  fi
  (
    cd kernel_platform/common
    patch -p1 --fuzz=3 < ../../susfs4ksu/kernel_patches/50_add_susfs_in_gki-${ANDROID_VERSION}-${KERNEL_VERSION}.patch || true
    cp -rv ../../susfs4ksu/kernel_patches/fs/* ./fs/
    cp -rv ../../susfs4ksu/kernel_patches/include/linux/* ./include/linux/
  )
  write_gki_config \
    KSU_SUSFS=y \
    KSU_SUSFS_SUS_SU=n \
    KSU_SUSFS_SUS_MAP=y \
    KSU_SUSFS_SUS_PATH=y \
    KSU_SUSFS_SUS_MOUNT=y \
    KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT=y \
    KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT=y \
    KSU_SUSFS_SUS_KSTAT=y \
    KSU_SUSFS_TRY_UMOUNT=y \
    KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT=y \
    KSU_SUSFS_SPOOF_UNAME=y \
    KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y \
    KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y \
    KSU_SUSFS_OPEN_REDIRECT=y
}

# Initialize repo and sync
rm -vf kernel_platform/common/android/abi_gki_protected_exports_* || echo "No protected exports!"
rm -vf kernel_platform/msm-kernel/android/abi_gki_protected_exports_* || echo "No protected exports!"
sed -i 's/ -dirty//g' kernel_platform/build/kernel/kleaf/workspace_status_stamp.py

case "$KSU_VARIANT" in
  "ksu")
    setup_kernelsu "tiann/KernelSU"
    ;;
  "mksu")
    setup_kernelsu "5ec1cff/KernelSU"
    ;;
  "sukisu")
    setup_kernelsu "SukiSU-Ultra/SukiSU-Ultra" builtin 37185 main # 40000 - 2815
    ;;
  *)
    echo "Unknown KSU_VARIANT: ${KSU_VARIANT}"
    exit 1
    ;;
esac

if [ "${ENABLE_SUSFS}" == "yes" ]; then
  if [ "${KSU_VARIANT}" == "sukisu" ]; then
    setup_susfs "no"
  else
    setup_susfs
  fi
fi

# Set up extra patches for OnePlus devices
git clone https://github.com/WildKernels/kernel_patches.git --depth 1
(
  cd kernel_patches
  curl -LSs https://github.com/WildKernels/kernel_patches/pull/4.patch | git apply --ignore-whitespace --reject || true
)
(
  cd kernel_platform/common
  patch -p1 --forward < ../../kernel_patches/oneplus/001-lz4.patch || true
  patch -p1 --forward < ../../kernel_patches/oneplus/002-zstd.patch || true
  patch -p1 --forward < ../../kernel_patches/69_hide_stuff.patch
)

# Add BBR Config
write_gki_config TCP_CONG_ADVANCED=y TCP_CONG_BBR=y NET_SCH_FQ=y TCP_CONG_BIC=n TCP_CONG_WESTWOOD=n TCP_CONG_HTCP=n
# Remove check_defconfig
sed -i 's/check_defconfig//' ./kernel_platform/common/build.config.gki

# Build kernel
./kernel_platform/build_with_bazel.py -t "${CPUD}" gki

# Make AnyKernel3
mkdir -p AnyKernel3
curl -LSs https://github.com/Kernel-SU/AnyKernel3/archive/refs/heads/master.tar.gz | tar -zxvC AnyKernel3 --strip-components=1
cp "kernel_platform/out/msm-kernel-${CPUD}-gki/dist/Image" ./AnyKernel3/Image
write_github_output "kernel_version" $(strings ./AnyKernel3/Image | sed -n 's/.*Linux version \([^ ]*\).*/\1/p' | uniq)
