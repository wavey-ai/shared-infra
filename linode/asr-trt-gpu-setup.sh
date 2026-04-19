#!/bin/bash
set -euo pipefail

if [ $# -ne 1 ]; then
    echo "Usage: $0 <server-ip>"
    exit 1
fi

IP="$1"
SSH_OPTS=(
    -o StrictHostKeyChecking=no
    -o ConnectTimeout=10
)

ONNXRUNTIME_URL="${ONNXRUNTIME_URL:-https://github.com/microsoft/onnxruntime/releases/download/v1.24.4/onnxruntime-linux-x64-gpu-1.24.4.tgz}"
TENSORRT_URL="${TENSORRT_URL:-}"
TRT_SWAP_GB="${TRT_SWAP_GB:-8}"

ssh "${SSH_OPTS[@]}" root@"$IP" \
    ONNXRUNTIME_URL="$ONNXRUNTIME_URL" \
    TENSORRT_URL="$TENSORRT_URL" \
    TRT_SWAP_GB="$TRT_SWAP_GB" \
    'bash -se' <<'EOF'
set -euo pipefail

arch_pkgs=(
  base-devel
  caddy
  cuda
  curl
  git
  jq
  linux-firmware-nvidia
  linux-headers
  nvidia-open-dkms
  nvidia-utils
  rsync
  tar
  unzip
  xz
)

export DEBIAN_FRONTEND=noninteractive

pacman-key --init
pacman-key --populate archlinux
pacman -Sy --noconfirm archlinux-keyring ca-certificates-mozilla

if pacman -Q linux-firmware >/dev/null 2>&1; then
  pacman -Rdd --noconfirm linux-firmware
fi

pacman -Syu --noconfirm --needed "${arch_pkgs[@]}"

if [ "${TRT_SWAP_GB}" != "0" ] && ! swapon --show=NAME | grep -qx /swapfile-trt; then
  if [ ! -f /swapfile-trt ]; then
    fallocate -l "${TRT_SWAP_GB}G" /swapfile-trt
    chmod 600 /swapfile-trt
    mkswap /swapfile-trt >/dev/null
  fi
  swapon /swapfile-trt
fi

install -d -m 755 /opt/src /opt/cuda-12.8-runtime/lib /opt/cuda-12.8-runtime/.staging \
  /opt/onnxruntime-trt /opt/tensorrt /var/lib/asr-api/trt-cache

base=https://developer.download.nvidia.com/compute/cuda/redist
pkgs=(
  cuda_cudart/linux-x86_64/cuda_cudart-linux-x86_64-12.8.57-archive.tar.xz
  libcublas/linux-x86_64/libcublas-linux-x86_64-12.8.3.14-archive.tar.xz
  libcufft/linux-x86_64/libcufft-linux-x86_64-11.3.3.41-archive.tar.xz
  libcurand/linux-x86_64/libcurand-linux-x86_64-10.3.9.55-archive.tar.xz
)

rm -rf /opt/cuda-12.8-runtime/lib/* /opt/cuda-12.8-runtime/.staging/*
for rel in "${pkgs[@]}"; do
  file="/opt/src/$(basename "$rel")"
  if [ ! -s "$file" ]; then
    curl -fL --retry 3 --retry-delay 2 -o "$file" "$base/$rel"
  fi
  work="/opt/cuda-12.8-runtime/.staging/$(basename "$file" .tar.xz)"
  rm -rf "$work"
  mkdir -p "$work"
  tar -xJf "$file" -C "$work"
  while IFS= read -r libdir; do
    cp -a "$libdir"/. /opt/cuda-12.8-runtime/lib/
  done < <(find "$work" -type d \( -name lib -o -name lib64 \))
done

if [ -n "$ONNXRUNTIME_URL" ]; then
  ort_archive="/opt/src/$(basename "$ONNXRUNTIME_URL")"
  if [ ! -s "$ort_archive" ]; then
    curl -fL --retry 3 --retry-delay 2 -o "$ort_archive" "$ONNXRUNTIME_URL"
  fi
  rm -rf /opt/onnxruntime-trt/*
  tar -xzf "$ort_archive" -C /opt/onnxruntime-trt --strip-components=1
fi

if [ -n "$TENSORRT_URL" ]; then
  trt_archive="/opt/src/$(basename "$TENSORRT_URL")"
  if [ ! -s "$trt_archive" ]; then
    curl -fL --retry 3 --retry-delay 2 -o "$trt_archive" "$TENSORRT_URL"
  fi
  rm -rf /opt/tensorrt/*
  tar -xzf "$trt_archive" -C /opt/tensorrt --strip-components=1
fi

cat >/etc/profile.d/asr-trt-runtime.sh <<'PROFILE'
export LD_LIBRARY_PATH=/opt/cuda-12.8-runtime/lib:/opt/tensorrt/targets/x86_64-linux-gnu/lib:/opt/onnxruntime-trt/lib:${LD_LIBRARY_PATH:-}
export ORT_DYLIB_PATH=/opt/onnxruntime-trt/lib/libonnxruntime.so
PROFILE

if [ -f /opt/onnxruntime-trt/lib/libonnxruntime_providers_tensorrt.so ]; then
  LD_LIBRARY_PATH=/opt/cuda-12.8-runtime/lib:/opt/tensorrt/targets/x86_64-linux-gnu/lib:/opt/onnxruntime-trt/lib:/usr/lib \
    ldd /opt/onnxruntime-trt/lib/libonnxruntime_providers_tensorrt.so >/tmp/ort-trt-ldd.txt
fi

nvidia-smi
free -h
swapon --show || true
EOF
