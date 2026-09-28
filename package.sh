#!/usr/bin/env bash
set -euo pipefail

UPSTREAM_REPO="conda-forge/miniforge"
TAG="${1:?upstream tag is required}"
UPSTREAM_VERSION="${2:?upstream version is required}"
VERSION="${3:?Debian version is required}"
ARCH="${4:?Debian architecture is required}"
UPSTREAM_ARCH="${5:?upstream architecture is required}"
PACKAGE="$(awk '/^Package:/ { print $2; exit }' debian/control)"
PREFIX="/opt/miniforge3"

case "${ARCH}:${UPSTREAM_ARCH}" in
  amd64:x86_64|arm64:aarch64) ;;
  *)
    echo "unsupported architecture mapping: ${ARCH}:${UPSTREAM_ARCH}" >&2
    exit 2
    ;;
esac

write_control() {
  local target="$1"
  awk -v version="${VERSION}" -v arch="${ARCH}" '
    /^Package:/ {
      print
      print "Version: " version
      print "Architecture: " arch
      next
    }
    { print }
  ' debian/control > "${target}"
}

rm -rf work dist
mkdir -p work dist

asset="Miniforge3-${UPSTREAM_VERSION}-Linux-${UPSTREAM_ARCH}.sh"
checksum_asset="${asset}.sha256"
installer="$(pwd)/work/${asset}"
package_root="$(pwd)/work/pkg-${ARCH}"

gh release download "${TAG}" \
  --repo "${UPSTREAM_REPO}" \
  --pattern "${asset}" \
  --pattern "${checksum_asset}" \
  --dir work \
  --clobber

(
  cd work
  sha256sum --check "${checksum_asset}"
)

cleanup_prefix() {
  sudo rm -rf "${PREFIX}"
}
trap cleanup_prefix EXIT

if [[ -e "${PREFIX}" ]]; then
  echo "refusing to overwrite existing ${PREFIX} on the build runner" >&2
  exit 1
fi

# Miniforge contains prefix-sensitive files, so install it at the exact final
# path first. Packaging into a temporary prefix would leave build paths inside
# the resulting environment.
sudo bash "${installer}" -b -p "${PREFIX}"

test -x "${PREFIX}/bin/conda"
test -x "${PREFIX}/bin/mamba"
test -x "${PREFIX}/bin/python"
test -x "${PREFIX}/condabin/conda"

"${PREFIX}/bin/conda" --version
"${PREFIX}/bin/mamba" --version

# Keep the system-managed base environment predictable. Shell initialization
# remains an explicit per-user choice, and conda-forge keeps strict priority.
sudo "${PREFIX}/bin/conda" config --file "${PREFIX}/.condarc" --set auto_activate_base false

# The upstream constructor creates a permissive prefix. A dpkg-managed base
# environment must not be writable by ordinary users, otherwise conda and dpkg
# could both mutate the same files. Keep root ownership and strip group/other
# write bits while preserving executable bits.
sudo chmod -R go-w "${PREFIX}"
sudo chmod 0644 "${PREFIX}/.condarc"

mkdir -p \
  "${package_root}/DEBIAN" \
  "${package_root}/opt" \
  "${package_root}/usr/bin" \
  "${package_root}/usr/share/doc/${PACKAGE}"

sudo cp -a "${PREFIX}" "${package_root}/opt/miniforge3"
ln -s /opt/miniforge3/bin/conda "${package_root}/usr/bin/conda"
ln -s /opt/miniforge3/bin/mamba "${package_root}/usr/bin/mamba"

cat > "${package_root}/usr/share/doc/${PACKAGE}/README.Debian" <<'EOF'
Miniforge3 for Debian
=====================

The base environment under /opt/miniforge3 is owned by dpkg and should be
treated as system-managed. Do not use `conda update -n base` or install
additional packages into the base environment as an unprivileged user.

Create named or prefix environments instead, for example:

    conda create -n research python=3.13

Shell initialization is deliberately not performed by the Debian package.
Users who want activation helpers can run `conda init` themselves.
EOF

cat > "${package_root}/usr/share/doc/${PACKAGE}/copyright" <<'EOF'
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: Miniforge
Source: https://github.com/conda-forge/miniforge

Files: *
Copyright: 2019-2022 conda-forge
License: BSD-3-Clause
 Miniforge installer code is distributed under the BSD 3-Clause License.
 Binary packages bundled in Miniforge have their own licenses; their license
 texts are shipped inside the Miniforge package metadata under /opt/miniforge3.
EOF

write_control "${package_root}/DEBIAN/control"

dpkg-deb --build --root-owner-group \
  "${package_root}" \
  "dist/${PACKAGE}_${VERSION}_${ARCH}.deb"

deb="dist/${PACKAGE}_${VERSION}_${ARCH}.deb"
dpkg-deb --info "${deb}" >/dev/null

contents="$(dpkg-deb --contents "${deb}")"
grep -q './opt/miniforge3/bin/conda' <<<"${contents}"
grep -q './opt/miniforge3/bin/mamba' <<<"${contents}"
grep -q './opt/miniforge3/bin/python' <<<"${contents}"
grep -q './usr/bin/conda -> /opt/miniforge3/bin/conda' <<<"${contents}"
grep -q './usr/bin/mamba -> /opt/miniforge3/bin/mamba' <<<"${contents}"

# Never expose a system-wide python command from this package.
if grep -q './usr/bin/python' <<<"${contents}"; then
  echo "unexpected /usr/bin/python in package" >&2
  exit 1
fi
