#!/usr/bin/env bash
set -euo pipefail
ulimit -c 0
test "$(uname -m)" = aarch64
test "$(getconf PAGE_SIZE)" = 4096
test -n "${RUNNER_TEMP:?}"
smoke_dir=$(mktemp -d "$RUNNER_TEMP/pgdog-arm64-pages.XXXXXX")
echo "Smoke test files: $smoke_dir"

sudo apt-get update
sudo apt-get install -y --no-install-recommends qemu-system-arm busybox-static cpio build-essential cmake clang pkg-config libssl-dev mold

# Build the actual image through its Dockerfile, including BuildKit's TARGETARCH.
docker build --platform linux/arm64 --progress plain -t pgdog-arm64-pages .
docker run --rm --entrypoint /usr/local/bin/pgdog pgdog-arm64-pages --version

# A tiny program with the same global allocator reproduces the old 4K build.
mkdir -p "$smoke_dir/probe/src"
cat > "$smoke_dir/probe/Cargo.toml" <<'TOML'
[package]
name = "pgdog-allocator-baseline"
version = "0.1.0"
edition = "2024"
[dependencies]
tikv-jemallocator = "=0.6.1"
[workspace]
TOML
cat > "$smoke_dir/probe/src/main.rs" <<'RUST'
#[global_allocator]
static ALLOCATOR: tikv_jemallocator::Jemalloc = tikv_jemallocator::Jemalloc;
fn main() {
    let bytes = vec![42u8; 100_000];
    println!("allocator started: {} bytes", bytes.len());
}
RUST
JEMALLOC_SYS_WITH_LG_PAGE=12 CARGO_TARGET_DIR="$smoke_dir/probe-target" \
    cargo build --release --manifest-path "$smoke_dir/probe/Cargo.toml"
"$smoke_dir/probe-target/release/pgdog-allocator-baseline" > /dev/null

# Extract a genuine Ubuntu ARM64 64K-page kernel without installing/rebooting it.
kernel_package=$(apt-cache depends linux-image-generic-64k | sed -n 's/^ *Depends: \(linux-image-.*-generic-64k\)$/\1/p' | head -1)
test -n "$kernel_package"
mkdir -p "$smoke_dir/kernel"
(cd "$smoke_dir/kernel" && apt-get download "$kernel_package")
for package in "$smoke_dir/kernel"/*.deb; do
    dpkg-deb -x "$package" "$smoke_dir/kernel/root"
done
kernel=$(find "$smoke_dir/kernel/root/boot" -name 'vmlinuz-*' -print -quit)
test -f "$kernel"

guest="$smoke_dir/guest"
mkdir -p "$guest/bin" "$guest/dev" "$guest/proc" "$guest/sys" "$guest/tmp"
sudo mknod -m 600 "$guest/dev/console" c 5 1
sudo mknod -m 666 "$guest/dev/null" c 1 3
cp /bin/busybox "$guest/bin/busybox"
cp "$smoke_dir/probe-target/release/pgdog-allocator-baseline" "$guest/bin/allocator-baseline"
container=$(docker create pgdog-arm64-pages)
trap 'docker rm -f "$container" >/dev/null' EXIT
docker cp "$container:/usr/local/bin/pgdog" "$guest/bin/pgdog"
docker run --rm --entrypoint /usr/bin/ldd pgdog-arm64-pages /usr/local/bin/pgdog > "$smoke_dir/ldd.txt"
awk '{for (i=1;i<=NF;i++) if ($i ~ /^\//) print $i}' "$smoke_dir/ldd.txt" > "$smoke_dir/libraries.txt"
echo /lib/ld-linux-aarch64.so.1 >> "$smoke_dir/libraries.txt"
sort -u "$smoke_dir/libraries.txt" -o "$smoke_dir/libraries.txt"
while IFS= read -r library; do
    mkdir -p "$guest$(dirname "$library")"
    docker cp -L "$container:$library" "$guest$library"
done < "$smoke_dir/libraries.txt"

cat > "$guest/init" <<'INIT'
#!/bin/busybox sh
/bin/busybox mount -t proc proc /proc
/bin/busybox mount -t sysfs sysfs /sys
page_kb=$(/bin/busybox awk '/KernelPageSize:/ {print $2; exit}' /proc/self/smaps)
echo "Guest kernel page size: ${page_kb} kB"
if [ "$page_kb" != 64 ]; then
    echo PGDOG_PAGE_TEST_FAILED
    /bin/busybox poweroff -f
fi
if /bin/allocator-baseline > /tmp/baseline.log 2>&1; then
    echo "The old allocator unexpectedly accepted 64K pages"
    echo PGDOG_PAGE_TEST_FAILED
    /bin/busybox poweroff -f
fi
/bin/busybox cat /tmp/baseline.log
if ! /bin/busybox grep -q 'Unsupported system page size' /tmp/baseline.log; then
    echo PGDOG_PAGE_TEST_FAILED
    /bin/busybox poweroff -f
fi
if /bin/pgdog --version; then
    echo PGDOG_ARM64_64K_OK
else
    echo PGDOG_PAGE_TEST_FAILED
fi
/bin/busybox poweroff -f
INIT
chmod +x "$guest/init"
(cd "$guest" && find . -print0 | cpio --null -o --format=newc | gzip -1) > "$smoke_dir/initramfs.gz"
timeout 180 qemu-system-aarch64 -machine virt -cpu max -m 2048 -nographic -no-reboot -nic none \
    -kernel "$kernel" -initrd "$smoke_dir/initramfs.gz" \
    -append 'console=ttyAMA0 rdinit=/init panic=-1 loglevel=3' | tee "$smoke_dir/qemu.log"
grep -q PGDOG_ARM64_64K_OK "$smoke_dir/qemu.log"
! grep -q PGDOG_PAGE_TEST_FAILED "$smoke_dir/qemu.log"
