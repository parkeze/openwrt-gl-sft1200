#!/usr/bin/env bash
#
# Build an OpenWrt release's ImageBuilder for a device on a source-only target,
# with a newer kernel than the release has for it.
#
#   ./build.sh <openwrt-version> <target> <subtarget> <out-dir>
#   ./build.sh 25.12.6 siflower sf19a2890 out
#
# The device repos made from openwrt-device-template add a device to a target
# the release builds, and take every kmod from downloads.openwrt.org. That does
# not work here, for two reasons:
#
#   * siflower/sf19a2890 is source-only. The release publishes no ImageBuilder,
#     no config.buildinfo and no kmods for it, only the userland feeds for its
#     architecture (mipsel_24kc_24kf).
#   * The GL-SFT1200's switch, a MaxLinear GSW150, needs the lantiq_gswip
#     GSW1xx series from Linux 7.x, backported to OpenWrt main's 6.18 by the
#     GL-SFT1200 upstream work. The release's siflower target is 6.12.
#
# So the tree is the release tag, with the kernel side (target/linux/siflower,
# the generic 6.18 patches and config, and the kernel packages) grafted from
# the pinned commits in devices/<board>/graft. Userland is the release's
# exactly: the ImageBuilder installs it from the release's feeds, so a
# ParkezeOS image for this board runs the same ucode, netifd and fw4 as every
# other. The kernel and every kmod are built here and carried in the
# ImageBuilder's own packages/, since nothing upstream has them.
#
# Every devices/<board>/ holds the graft, and optionally a DTS and a patch
# against the grafted tree for anything the grafted target does not have. The
# directory's name is the device's name in the image recipe.
#
# Linux, on a case-sensitive filesystem.

set -euo pipefail

VERSION="${1:?usage: build.sh <openwrt-version> <target> <subtarget> <out-dir>}"
TARGET="${2:?}" SUBTARGET="${3:?}"
OUT="$(mkdir -p "${4:?}" && cd "$4" && pwd)"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${OPENWRT_SRC:-${ROOT}/.build/openwrt}"
GRAFTS="${ROOT}/.build/grafts"
REPO="https://downloads.openwrt.org/releases/${VERSION}"

log() { printf '\033[36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[31merror\033[0m %s\n' "$*" >&2; exit 1; }

# OpenWrt's configure scripts refuse root without this.
[ "$(id -u)" = 0 ] && export FORCE_UNSAFE_CONFIGURE=1

if [ ! -d "${SRC}/.git" ]; then
  log "Cloning OpenWrt v${VERSION}"
  # A cache-restored dl/ recreates ${SRC} without a .git, so clone beside it.
  rm -rf "${SRC}.tmp"
  git clone --depth 1 --branch "v${VERSION}" https://github.com/openwrt/openwrt.git "${SRC}.tmp"
  [ -d "${SRC}/dl" ] && mv "${SRC}/dl" "${SRC}.tmp/dl"
  rm -rf "${SRC}"
  mv "${SRC}.tmp" "${SRC}"
fi
cd "${SRC}"
[ "$(git describe --tags --exact-match 2>/dev/null)" = "v${VERSION}" ] \
  || die "${SRC} is not a checkout of v${VERSION}"

# Back to the pristine tag, keeping dl/, the feeds and the build dirs.
git checkout -q -- .
git clean -fdq -e /package/feeds -- target package

# One sparse, shallow checkout per pinned commit, of only the paths named.
graft() {
  local url="$1" commit="$2"; shift 2
  local dir="${GRAFTS}/${commit}"
  if [ ! -d "${dir}/.git" ]; then
    rm -rf "${dir}"; mkdir -p "${dir}"
    git -C "${dir}" init -q
    git -C "${dir}" remote add origin "${url}"
    git -C "${dir}" sparse-checkout set --no-cone "${@/#//}"
    git -C "${dir}" fetch -q --depth 1 --filter=blob:none origin "${commit}"
    git -C "${dir}" checkout -q FETCH_HEAD
  fi
  local path
  for path in "$@"; do
    [ -e "${dir}/${path}" ] || die "${path} is not in ${url} at ${commit}"
    rm -rf "${path}"
    mkdir -p "$(dirname "${path}")"
    cp -R "${dir}/${path}" "${path}"
  done
}

devices=""
for dir in "${ROOT}"/devices/*/; do
  device="$(basename "${dir}")"
  log "Applying ${device}"
  while read -r url commit paths; do
    case "${url}" in ''|'#'*) continue ;; esac
    log "  grafting ${paths} from ${url} at ${commit:0:9}"
    # shellcheck disable=SC2086
    graft "${url}" "${commit}" ${paths}
  done < "${dir}graft"
  ls "${dir}"*.dts* >/dev/null 2>&1 && cp "${dir}"*.dts* "target/linux/${TARGET}/dts/"
  [ -f "${dir}openwrt.patch" ] && git apply "${dir}openwrt.patch"
  devices="${devices} ${device}"
done
[ -n "${devices// }" ] || die "no devices found"

log "Installing the release's feeds"
# Any published target's feeds.buildinfo names the same feed commits; this
# target publishes none of its own.
curl -fsSL -o feeds.conf "${REPO}/targets/ramips/mt76x8/feeds.buildinfo"
./scripts/feeds update -a >/dev/null
./scripts/feeds install -a >/dev/null

log "Configuring"
{
  echo "CONFIG_TARGET_${TARGET}=y"
  echo "CONFIG_TARGET_${TARGET}_${SUBTARGET}=y"
  echo "CONFIG_TARGET_MULTI_PROFILE=y"
  echo "# CONFIG_TARGET_ALL_PROFILES is not set"
  for d in ${devices}; do
    echo "CONFIG_TARGET_DEVICE_${TARGET}_${SUBTARGET}_DEVICE_${d}=y"
  done
  # Every kmod and every package built per target (dropbear among them), as
  # the release's buildbot builds them, since the ImageBuilder is their only
  # source: a target's packages are published with its kmods, and this
  # target publishes neither.
  echo "CONFIG_ALL_KMODS=y"
  echo "CONFIG_ALL_NONSHARED=y"
  # The release's version and repository, so the ImageBuilder installs the
  # release's userland and an image says which release it is.
  echo "CONFIG_VERSIONOPT=y"
  echo "CONFIG_VERSION_DIST=\"OpenWrt\""
  echo "CONFIG_VERSION_NUMBER=\"${VERSION}\""
  echo "CONFIG_VERSION_REPO=\"${REPO}\""
  echo "CONFIG_IB=y"
  echo "# CONFIG_IB_STANDALONE is not set"
  echo "# CONFIG_SDK is not set"
  echo "# CONFIG_MAKE_TOOLCHAIN is not set"
  # No BPF toolchain: it is LLVM, built from source for hours, and nothing
  # this ImageBuilder installs needs it. The choice is only offered with
  # DEVEL; without it the setting is dropped and LLVM is built anyway.
  echo "CONFIG_DEVEL=y"
  echo "CONFIG_BPF_TOOLCHAIN_NONE=y"
  # A RAM-only image, for a first boot from the bootloader that writes nothing.
  echo "CONFIG_TARGET_ROOTFS_INITRAMFS=y"
} > .config
make defconfig >/dev/null

for d in ${devices}; do
  grep -qx "CONFIG_TARGET_DEVICE_${TARGET}_${SUBTARGET}_DEVICE_${d}=y" .config \
    || die "device ${d} did not survive defconfig; is its recipe in the patch valid?"
done
grep -q '^CONFIG_LINUX_6_18=y' .config || die "the graft did not make this a 6.18 target"

log "Building the toolchain and the kernel"
make download -j8 >/dev/null
make -j"$(nproc)" tools/install toolchain/install
# Verbose and single-threaded on failure, or the log says only "target/linux
# failed to build".
make -j"$(nproc)" target/linux/compile || make -j1 V=s target/linux/compile

log "Building the kmods and the images"
# A kmod that fails to build costs nothing unless an image needs it, and then
# `make image` says which.
make -j"$(nproc)" IGNORE_ERRORS=m || make -j1 V=s IGNORE_ERRORS=m

bin="bin/targets/${TARGET}/${SUBTARGET}"

# The ImageBuilder ships with the kernel, libc and base-files in packages/,
# and a repositories file naming this target's packages and kmods on
# downloads.openwrt.org, which do not exist. Every package built for the
# target goes into packages/, and those two lines go.
ib="$(ls "${bin}"/openwrt-imagebuilder-*.tar.zst)"
ibname="$(basename "${ib}" .tar.zst)"
stage="$(mktemp -d)"
log "Adding the target's packages and kmods to the ImageBuilder"
tar --use-compress-program=unzstd -xf "${ib}" -C "${stage}"
cp "${bin}"/packages/*.apk "${stage}/${ibname}/packages/"
sed -i "\|/targets/${TARGET}/${SUBTARGET}/|d" "${stage}/${ibname}/repositories"
( cd "${stage}" && tar -cf - "${ibname}" ) | zstd -qf -T0 -19 -o "${ib}"
rm -rf "${stage}"
log "$(ls "${bin}"/packages/*.apk | wc -l) packages added"

cp "${bin}"/openwrt-imagebuilder-*.tar.zst "${bin}"/*-initramfs-kernel.bin \
   "${bin}"/*-squashfs-sysupgrade.bin "${bin}"/*-squashfs-factory.img "${OUT}/"
( cd "${OUT}" && sha256sum -b -- *.tar.zst *.bin *.img > sha256sums )
log "Artifacts in ${OUT}:"
cat "${OUT}/sha256sums"
