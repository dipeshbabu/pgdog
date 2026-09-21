#!/usr/bin/env bash
set -euo pipefail
test "$(uname -m)" = aarch64
test "$(getconf PAGE_SIZE)" = 4096
unset JEMALLOC_SYS_WITH_LG_PAGE
sudo apt-get update
sudo apt-get install -y --no-install-recommends build-essential cmake clang pkg-config libssl-dev mold postgresql-16 postgresql-client-16
sudo pg_createcluster 16 allocatorbench --port=55432 --start
sudo -u postgres psql -p 55432 -v ON_ERROR_STOP=1 -c "CREATE ROLE allocator_bench LOGIN PASSWORD 'allocator_bench';"
sudo -u postgres createdb -p 55432 -O allocator_bench allocator_bench
mkdir -p allocator-results
rustc -Vv > allocator-results/toolchain.txt
sudo -u postgres psql -p 55432 -At -c 'SELECT version()' > allocator-results/postgres.txt
getconf PAGE_SIZE > allocator-results/page-size.txt
git rev-parse HEAD > allocator-results/ci-commit.txt

# Change only the allocator manifests between builds, using the same source path
# and compiler. Clean PgDog itself so each binary is certainly relinked.
git show 9d83dea3c94deb5435643815a1cb19217edf74bf:pgdog/Cargo.toml > pgdog/Cargo.toml
git show 9d83dea3c94deb5435643815a1cb19217edf74bf:Cargo.lock > Cargo.lock
cargo build --locked --release --bin pgdog
cp target/release/pgdog allocator-results/pgdog-0.6
git restore --source=HEAD -- pgdog/Cargo.toml Cargo.lock
cargo clean -p pgdog
cargo build --locked --release --bin pgdog
cp target/release/pgdog allocator-results/pgdog-0.7
python3 .github/ci/allocator-benchmark.py
