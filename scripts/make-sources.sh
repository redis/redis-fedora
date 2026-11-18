#!/bin/bash
# make-sources.sh -- regenerate the two vendored-crate Sources for redis.spec.
#
#   Source1  redisjson-vendor-<ver>.tar.gz   `cargo vendor` of RedisJSON
#   Source2  redisearch-vendor-<ver>.tar.gz  `cargo vendor` of RediSearch
#
# The build has no network access, so the crates ship inside the SRPM. They
# are vendored from the module sources in upstream's release tarball
# (Source0), which this script downloads if it is not already present.
#
# Sources 3-8 (RediSearch's CMake FetchContent deps) are fetched with spectool
# by the Makefile's `download` target.
#
# Usage:  scripts/make-sources.sh [<redis-version>]
#         defaults to the Version: in redis.spec

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
SPEC="$REPO_ROOT/redis.spec"
OUTDIR="${OUTDIR:-$(rpm --eval %{_sourcedir})}"
WORK="${WORK:-$HOME/.cache/redis-sources}"

TAG="${1:-$(awk '/^Version:/{print $2; exit}' "$SPEC")}"
# The vendor tarballs are named after the Redis version: the crates come from
# the module sources inside that release tarball.
# A pre-release is 8.12~rc3 in the spec and 8.12-rc3 upstream.
TAG="${TAG//\~/-}"
JSON_VER="$TAG"
SEARCH_VER="$TAG"

echo "==> redis tag       : $TAG"
echo "==> output          : $OUTDIR"
mkdir -p "$OUTDIR" "$WORK"

# ---------------------------------------------------------------------------
# Source0 -- upstream's release tarball: Redis plus each module at the ref
# pinned in modules/modules.yaml. The crates are vendored from this exact
# tree, so they cannot drift from what the build compiles.
# ---------------------------------------------------------------------------
TARBALL="$OUTDIR/redis-$TAG.tar.gz"
if [ ! -f "$TARBALL" ]; then
    echo "==> downloading redis-$TAG.tar.gz"
    curl -fsSL -o "$TARBALL" "https://download.redis.io/releases/redis-$TAG.tar.gz"
fi
CLONE="$WORK/redis-$TAG"
rm -rf "$CLONE"
tar xzf "$TARBALL" -C "$WORK"

# ---------------------------------------------------------------------------
# Source1 -- RedisJSON vendored crates.
# The spec expects a `vendor/` directory that also contains
# vendor/.cargo/config.toml, which plain `cargo vendor` does not write.
# ---------------------------------------------------------------------------
echo "==> cargo vendor: redisjson"
JDIR="$WORK/redisjson-$JSON_VER"
rm -rf "$JDIR" && cp -a "$CLONE/modules/redisjson/src" "$JDIR"
( cd "$JDIR"
  rm -rf vendor .cargo
  cargo vendor vendor > "$WORK/json-vendor-config.txt"
  mkdir -p vendor/.cargo
  sed -n '/^\[source/,$p' "$WORK/json-vendor-config.txt" > vendor/.cargo/config.toml
  tar czf "$OUTDIR/redisjson-vendor-$JSON_VER.tar.gz" vendor )

# ---------------------------------------------------------------------------
# Source2 -- RediSearch vendored crates.
# Layout differs from RedisJSON: crates go in mycargo/ with the cargo config
# at the top level, plus a licence manifest shipped as %license.
# ---------------------------------------------------------------------------
echo "==> cargo vendor: redisearch"
SDIR="$WORK/redisearch-$SEARCH_VER"
rm -rf "$SDIR" && cp -a "$CLONE/modules/redisearch/src" "$SDIR"
( cd "$SDIR"
  rm -rf mycargo .cargo
  cargo vendor --manifest-path src/redisearch_rs/Cargo.toml mycargo \
      > "$WORK/rs-vendor-config.txt"

  # The `nix` crate ships a GPL-2.0 kernel-module test fixture that is never
  # compiled into redisearch.so. Drop it so licence scanners stay quiet, and
  # fix the checksum manifest so the offline cargo build still verifies.
  NIX=mycargo/nix
  if [ -f "$NIX/test/test_kmod/hello_mod/hello.c" ] && [ -f "$NIX/.cargo-checksum.json" ]; then
      rm -f "$NIX/test/test_kmod/hello_mod/hello.c"
      python3 - "$NIX/.cargo-checksum.json" <<'PYEOF'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1]); d = json.loads(p.read_text())
d["files"].pop("test/test_kmod/hello_mod/hello.c", None)
p.write_text(json.dumps(d))
PYEOF
  fi

  mkdir -p .cargo
  sed -n '/^\[source/,$p' "$WORK/rs-vendor-config.txt" > .cargo/config.toml
  ( cd src/redisearch_rs && cargo tree --workspace --offline --edges=normal \
        --no-dedupe --prefix=none --format '{p} | {l}' 2>/dev/null \
      | grep -v '(/' | grep -v '| $' | sort -u > ../../rust-vendor-licenses.txt ) \
      || echo "# vendor licence manifest unavailable" > rust-vendor-licenses.txt
  tar czf "$OUTDIR/redisearch-vendor-$SEARCH_VER.tar.gz" \
      mycargo .cargo/config.toml rust-vendor-licenses.txt )

echo
echo "==> generated:"
ls -lh "$OUTDIR/redisjson-vendor-$JSON_VER.tar.gz" \
       "$OUTDIR/redisearch-vendor-$SEARCH_VER.tar.gz" | awk '{print "    " $5 "  " $9}'
