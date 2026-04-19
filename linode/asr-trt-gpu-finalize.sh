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

ssh "${SSH_OPTS[@]}" root@"$IP" 'bash -se' <<'EOF'
set -euo pipefail

IMAGE_LIMIT_GB="${IMAGE_LIMIT_GB:-5.4}"

runtime_libs=(
  libnvinfer.so
  libnvinfer.so.10
  libnvinfer.so.10.9.0
  libnvinfer_builder_resource.so
  libnvinfer_builder_resource.so.10
  libnvinfer_builder_resource.so.10.9.0
  libnvinfer_plugin.so
  libnvinfer_plugin.so.10
  libnvinfer_plugin.so.10.9.0
  libnvinfer_dispatch.so
  libnvinfer_dispatch.so.10
  libnvinfer_dispatch.so.10.9.0
  libnvinfer_vc_plugin.so
  libnvinfer_vc_plugin.so.10
  libnvinfer_vc_plugin.so.10.9.0
  libnvonnxparser.so
  libnvonnxparser.so.10
  libnvonnxparser.so.10.9.0
)

echo "Stopping host-specific services..."
systemctl disable --now asr-api-cohere-test.service >/dev/null 2>&1 || true
systemctl disable --now caddy.service >/dev/null 2>&1 || true

echo "Removing app state and build artifacts..."
rm -rf \
  /opt/wavey \
  /opt/src \
  /root/.cargo \
  /root/.rustup \
  /root/.cache \
  /var/lib/asr-api \
  /etc/asr-api \
  /etc/caddy/conf.d/* \
  /etc/systemd/system/asr-api-cohere-test.service \
  /etc/systemd/system/asr-api-cohere-test.service.bak

echo "Removing temporary swap..."
swapoff /swapfile-trt >/dev/null 2>&1 || true
rm -f /swapfile-trt

echo "Trimming TensorRT to runtime-only shared libraries..."
if [ -d /opt/tensorrt/targets/x86_64-linux-gnu/lib ]; then
  workdir=/opt/tensorrt-runtime-pruned
  rm -rf "$workdir"
  mkdir -p "$workdir/targets/x86_64-linux-gnu/lib"
  for name in "${runtime_libs[@]}"; do
    if [ -e "/opt/tensorrt/targets/x86_64-linux-gnu/lib/$name" ]; then
      cp -a "/opt/tensorrt/targets/x86_64-linux-gnu/lib/$name" \
        "$workdir/targets/x86_64-linux-gnu/lib/"
    fi
  done
  rm -rf /opt/tensorrt
  mv "$workdir" /opt/tensorrt
fi

echo "Cleaning pacman cache and journals..."
pacman -Scc --noconfirm >/dev/null
journalctl --rotate >/dev/null 2>&1 || true
journalctl --vacuum-time=1d >/dev/null 2>&1 || true

echo "Validating TensorRT provider linkage..."
LD_LIBRARY_PATH=/opt/cuda-12.8-runtime/lib:/opt/tensorrt/targets/x86_64-linux-gnu/lib:/opt/onnxruntime-trt/lib:/usr/lib \
  ldd /opt/onnxruntime-trt/lib/libonnxruntime_providers_tensorrt.so >/tmp/ort-trt-ldd.txt

used_bytes="$(df --output=used -B1 / | tail -n1 | tr -d ' ')"
used_gb="$(awk -v bytes="$used_bytes" 'BEGIN { printf "%.2f", bytes / 1024 / 1024 / 1024 }')"

echo
echo "Remaining footprint:"
du -sh /opt/cuda-12.8-runtime/lib /opt/tensorrt /opt/onnxruntime-trt /usr /var /root 2>/dev/null || true
df -h /
echo

awk -v used="$used_gb" -v limit="$IMAGE_LIMIT_GB" 'BEGIN {
  if (used <= limit) {
    printf "Used disk %.2f GiB is within the default custom-image target of %.1f GiB.\n", used, limit
  } else {
    printf "Used disk %.2f GiB exceeds the default custom-image target of %.1f GiB.\n", used, limit
    printf "Capture will likely require a higher Linode custom-image size limit or a two-stage bootstrap.\n"
  }
}'
EOF
