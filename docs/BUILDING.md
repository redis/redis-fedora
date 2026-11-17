# Building

## Toolchain

```bash
sudo dnf install rpm-build rpmdevtools rpmlint mock copr-cli \
                 git cargo rust createrepo_c
sudo usermod -a -G mock "$USER"   # then log out and back in
rpmdev-setuptree
```

Verify with `make check-tools`.

## The sources

`redis.spec` has fourteen Sources. They come from three different places, and
the distinction matters:

### Source0 — upstream's release tarball

`https://download.redis.io/releases/redis-<ver>.tar.gz`. It already contains
every module at its `modules.yaml` ref, so nothing has to be assembled.

### Source1-2 — generated, not downloadable

These do not exist as upstream release artefacts. `scripts/make-sources.sh`
produces them from the module sources inside Source0:

| Source | Produced by |
|---|---|
| `redisjson-vendor-<redis version>.tar.gz` | `cargo vendor` of the RedisJSON workspace |
| `redisearch-vendor-<redis version>.tar.gz` | `cargo vendor` of the RediSearch Rust workspace |

`cargo vendor` needs **network access**, which is why they are generated
ahead of time and shipped inside the SRPM — the buildroot is offline.

```bash
make sources    # regenerates both
```

### Source3-8 — RediSearch's CMake FetchContent dependencies

Real upstream URLs, fetched by `spectool`:

```
cpu_features, eve, robin-map, fmt, spdlog, tomlplusplus
```

```bash
make download
```

### Source9-13 — static files in `sources/`

systemd units, sysusers, logrotate, rpmlintrc.

## Build steps

```bash
make srpm     # source RPM
make mock     # binary RPMs in a clean chroot  (~1h on 2 cores)
make copr     # submit to Copr (all chroots, faster)
```

---

# Offline-build traps

Fedora and Copr buildroots have **no network**. Five upstream behaviours
assume otherwise. Each cost real debugging time; they are documented here so
they are not rediscovered.

## 1. `common.mk` re-clones modules

`modules/common.mk`'s `get_source` target clones a module over the network
unless `modules/<name>/src/.prepared` exists.

**Fix** — none needed in the spec. The release tarball ships the marker for
all four modules. Use that tarball as Source0; a git archive does not have it.

## 2. Cargo wants the crates.io index

RedisJSON and RediSearch build Rust code. With no network, `cargo` fails on
the first dependency. Both get a pre-vendored crate tree plus a
`.cargo/config.toml` pointing at it. Note the two modules expect **different
layouts** — RedisJSON wants `vendor/` containing `vendor/.cargo/config.toml`;
RediSearch wants `mycargo/` with the config at the top level.

## 3. RediSearch pulls *seven* FetchContent dependencies

Six ship as Source3-8 and are wired up with `FETCHCONTENT_SOURCE_DIR_*` plus
`FETCHCONTENT_FULLY_DISCONNECTED=ON`.

**The seventh is Boost**, which is easy to miss — it comes from the system
`boost-devel` via `-DBOOST_DIR=%{_includedir}`. Without it, CMake fails with
`BOOST_DIR is not defined or does not point to a valid directory`.

## 4. `readies` needs pip, not just python3

RedisJSON and RedisTimeSeries build through RedisLabs' `readies` harness. Its
interpreter check ends:

```bash
if [[ $CHECK == 1 ]]; then
    if $MYPY -m pip --version &> /dev/null; then exit 0; fi
    exit 1
fi
```

So it fails unless **`python3 -m pip` works**. The error it prints —
`Cannot find python3 interpreter` — is misleading: Python was installed and
working. Hence `BuildRequires: python3-pip`.

## 5. RediSearch must be built with `%cmake`, not its own `build.sh`

`build.sh` does not propagate Fedora's `%{build_ldflags}`, which carries
`-Wl,--build-id=sha1`. Without a build-id, rpm aborts:

```
error: Missing build-id in .../redisearch.so
error: Generating build-id links failed
```

Exporting `LDFLAGS` into `build.sh` does **not** fix it — the flags never
reach the link. `%cmake` passes linker flags explicitly as `-D` arguments, so
RediSearch is built that way. Core and the other three modules still use
upstream's `make build`.

---

# Other things worth knowing

## `INLINE_LSE_ATOMICS` and ARM64

RediSearch's CMake defaults `INLINE_LSE_ATOMICS` to `ON`, emitting
`-march=armv8-a+lse` — **Armv8.1-a**. Fedora's aarch64 baseline is Armv8.0-a,
so the resulting `.so` can `SIGILL` on Cortex-A72, Graviton1 and Raspberry Pi 4.

Upstream's own bundled build disables it for exactly this reason (see the
`build_env` comment in `modules.yaml`). The spec passes
`-DINLINE_LSE_ATOMICS=OFF`.

## RediSearch's bundled libraries are linked statically

`%cmake` passes `-DBUILD_SHARED_LIBS=ON` by default. RediSearch's bundled
libraries (VectorSimilarity, cpu_features, hiredis, fmt, spdlog) do not name a
library type, so that default turns each into a separate `.so` which
`redisearch.so` needs at load time.

Upstream's build leaves `BUILD_SHARED_LIBS` off and links them into
`redisearch.so`. The spec passes `-DBUILD_SHARED_LIBS=OFF` to match, so the
package ships one file for the module and needs no RPATH handling.

## Module ABI guard

`%prep` compares `REDISMODULE_APIVER_*` in `src/redismodule.h` against the
`redis_modules_abi` macro and fails the build if upstream bumps it. That
catches an ABI change at build time rather than at runtime.

## Build time

RediSearch dominates: roughly 40 minutes of a ~1 hour local build on 2 cores.
Copr is considerably faster and covers all chroots, so prefer `make copr` for
iteration and `make mock` for a final local check.
