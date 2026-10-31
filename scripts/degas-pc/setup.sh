#!/usr/bin/env bash
#
# One-time setup of a home Ubuntu 22.04/24.04 PC as a GitHub Actions
# runner that builds LineageOS 23.2 for degas.
#
# Usage:
#   bash setup.sh <runner-registration-token>
#
# The token comes from GitHub: repository Settings -> Actions -> Runners ->
# New self-hosted runner (the value after --token). It expires after one hour.

set -euo pipefail

TOKEN="${1:?usage: setup.sh <runner-registration-token>}"
REPO_URL="https://github.com/degasuser/crave_aosp_builder"
SRC_DIR="${SRC_DIR:-$HOME/android/lineage}"
RUNNER_DIR="${RUNNER_DIR:-$HOME/actions-runner}"
MANIFEST_BRANCH="${MANIFEST_BRANCH:-claude/build-errors-1d3dp1}"

echo "==> Installing build dependencies"
sudo apt-get update
sudo apt-get install -y \
    bc bison build-essential ccache curl ethtool flex g++-multilib gcc-multilib \
    git git-lfs gnupg gperf imagemagick jq lib32readline-dev lib32z1-dev \
    libdw-dev libelf-dev libncurses-dev libsdl1.2-dev libssl-dev libxml2 \
    libxml2-utils lz4 lzop pngcrush protobuf-compiler python3-protobuf \
    python-is-python3 rsync schedtool squashfs-tools xsltproc zip zlib1g-dev \
    zram-tools
git lfs install

echo "==> Compressed RAM swap (zram, 16 GB) for the memory-heavy build steps"
printf 'ALGO=zstd\nSIZE=16384\nPRIORITY=100\n' | sudo tee /etc/default/zramswap >/dev/null
sudo systemctl restart zramswap || true

echo "==> repo tool"
mkdir -p "$HOME/bin"
curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo -o "$HOME/bin/repo"
chmod a+x "$HOME/bin/repo"
grep -q 'HOME/bin' "$HOME/.profile" || echo 'export PATH="$HOME/bin:$PATH"' >> "$HOME/.profile"
export PATH="$HOME/bin:$PATH"

git config --global user.name >/dev/null || git config --global user.name "degasuser"
git config --global user.email >/dev/null || \
    git config --global user.email "331573350+degasuser@users.noreply.github.com"

echo "==> LineageOS 23.2 source in $SRC_DIR (shallow, ~120 GB)"
mkdir -p "$SRC_DIR"
cd "$SRC_DIR"
if [ ! -d .repo ]; then
    repo init -u https://github.com/LineageOS/android.git -b lineage-23.2 --git-lfs --depth=1
fi
rm -rf .repo/local_manifests
git clone --depth 1 -b "$MANIFEST_BRANCH" https://github.com/degasuser/local_manifests .repo/local_manifests
repo sync -c -j"$(nproc)" --force-sync --no-clone-bundle --no-tags --optimized-fetch --prune

echo "==> GitHub Actions runner in $RUNNER_DIR"
mkdir -p "$RUNNER_DIR"
cd "$RUNNER_DIR"
if [ ! -f config.sh ]; then
    VER="$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest | jq -r .tag_name | sed 's/^v//')"
    curl -fsSL -o runner.tar.gz \
        "https://github.com/actions/runner/releases/download/v${VER}/actions-runner-linux-x64-${VER}.tar.gz"
    tar xzf runner.tar.gz
    rm runner.tar.gz
fi
./config.sh --unattended --replace --url "$REPO_URL" --token "$TOKEN" \
    --name "degas-pc" --labels "degas-pc" --work "_work"
echo "DEGAS_SRC_DIR=$SRC_DIR" >> .env
sudo ./svc.sh install "$USER"
sudo ./svc.sh start

echo "==> Allow the runner to power the PC off after a build"
echo "$USER ALL=(root) NOPASSWD: /usr/sbin/shutdown" | sudo tee /etc/sudoers.d/degas-shutdown >/dev/null
sudo chmod 440 /etc/sudoers.d/degas-shutdown

echo "==> Wake-on-LAN on the wired interface"
IFACE="$(ip -o link show | awk -F': ' '$2 ~ /^(en|eth)/ {print $2; exit}')"
if [ -n "$IFACE" ]; then
    sudo tee /etc/systemd/system/wol.service >/dev/null <<UNIT
[Unit]
Description=Enable Wake-on-LAN on $IFACE
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/ethtool -s $IFACE wol g

[Install]
WantedBy=multi-user.target
UNIT
    sudo systemctl daemon-reload
    sudo systemctl enable --now wol.service
    echo "Wake-on-LAN enabled on $IFACE, MAC: $(cat /sys/class/net/$IFACE/address)"
else
    echo "No wired interface found; Wake-on-LAN skipped."
fi

echo
echo "Done. Also enable Wake-on-LAN (or 'Power On By PCI-E') in the BIOS."
