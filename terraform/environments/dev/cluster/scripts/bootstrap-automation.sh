#!/bin/bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

apt-get -o Acquire::Retries=3 update
apt-get -o Acquire::Retries=3 install -y ca-certificates curl unzip python3-venv

install_dir="$(mktemp -d)"
trap 'rm -rf -- "$install_dir"' EXIT

if ! command -v aws >/dev/null 2>&1; then
  curl -fsSL --retry 3 \
    https://awscli.amazonaws.com/v2/install.sh \
    -o "$install_dir/install-aws-cli.sh"
  bash "$install_dir/install-aws-cli.sh" --system
fi

if ! command -v session-manager-plugin >/dev/null 2>&1; then
  curl -fsSL --retry 3 \
    https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb \
    -o "$install_dir/session-manager-plugin.deb"
  dpkg -i "$install_dir/session-manager-plugin.deb"
fi

venv_dir="/opt/blogapp-ops/.venv"
if [ ! -x "$venv_dir/bin/python" ]; then
  python3 -m venv "$venv_dir"
fi

aws --version
session-manager-plugin --version
"$venv_dir/bin/python" --version