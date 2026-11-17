# Notes for coding agents

Read this before changing anything here. Most of it is knowledge that is
expensive to rediscover, and several points are counter-intuitive enough that
a reasonable-looking change will silently break the build.

## What this repo is

One RPM spec that builds Redis **and every module upstream bundles with it**
from a single source, producing these packages:

| Package | Contents |
|---|---|
| `redis-core` | plain server; vector sets compiled in; **no modules** |
| `redis-devel` | `redismodule.h` + RPM macros |
| `redisbloom`, `redisearch`, `redisjson`, `redistimeseries` | one module each: the `.so` and its `loadmodule` stub |
| `redis` | no files; requires `redis-core` and the four module packages |

It replaced five separate packaging repos. The modules are subpackages of
this one spec. Do not move them back into separate source packages without
reading `docs/DESIGN.md` — that split caused unsatisfiable dependencies,
blocked co-installation, and two conflicting versioning schemes.

## Ground rules

**Never claim something works because it built.** A package can build, install
and lint cleanly while shipping a `.so` Redis refuses to load. The only proof
is `scripts/smoke-test.sh`, which starts a server and issues real commands.
If you have not run it, say so explicitly rather than implying verification.

**`@redis/redis` on Copr is a shared team repo.** Builds published there are
outward-facing. Do not submit unverified work, and never delete package
entries without explicit confirmation — deletion removes build history and
RPMs irreversibly.

**Do not guess at causes.** Every failure documented here was diagnosed by
reading the actual upstream source, not inferred from the error message. At
least one error message is actively misleading (see pip, below).

## Commands

```bash
make help          # all targets
make check-tools   # verify toolchain first
make sources       # regenerate generated tarballs (needs network, slow)
make srpm
make mock          # local, one chroot, ~1h on 2 cores
make copr          # all 8 chroots, faster
make smoke         # install from Copr and assert at runtime
make lint
```

## Things that will trip you up

### 1. Editing `Version:` is not a version bump

Two Sources are **generated**, not downloadable: the `cargo vendor` trees for
RedisJSON and RediSearch. They must be regenerated with `make sources` for
every version. Source0 is upstream's release tarball, which already contains
the modules. Follow `docs/MAINTENANCE.md`.

Also: module versions come from upstream's `modules/modules.yaml`, not from
you, and they do **not** all match the core tag.

### 2. Do not add `rust-*-devel` BuildRequires

Rust crates come from the vendored tarballs. The old split specs listed ~90
`rust-*-devel` packages; they were decorative, and one of them
(`rust-lazycell-devel`) was retired in Fedora 45+ and broke the build on four
chroots. Vendoring is the mechanism; system crate packages are not.

### 3. Do not build RediSearch with its own `build.sh`

`build.sh` does not propagate `%{build_ldflags}`, so `-Wl,--build-id=sha1`
never reaches the linker and rpm aborts with `Missing build-id`. Exporting
`LDFLAGS` does not fix it. Use `%cmake`, which passes linker flags as explicit
`-D` arguments. Core and the other three modules do use upstream's
`make build` — that part is fine.

### 4. `Cannot find python3 interpreter` means pip is missing

RedisJSON and RedisTimeSeries build through RedisLabs' `readies`. Its check is:

```bash
if $MYPY -m pip --version &> /dev/null; then exit 0; fi
exit 1
```

Python was installed and working when this error appeared. The fix is
`BuildRequires: python3-pip`. Do not chase the interpreter.

### 5. RediSearch has *seven* FetchContent dependencies, not six

Six ship as Sources. **The seventh is Boost**, from system `boost-devel` via
`-DBOOST_DIR`. Miss it and CMake fails with `BOOST_DIR is not defined`.

Re-check all pins on every bump — 8.10.0 moved fmt 11.2.0 → 12.1.0, and a
stale pin fails at configure time after most of the build has already run.

### 6. Module sources re-clone themselves unless stopped

`modules/common.mk` clones a module over the network unless `src/.prepared`
exists. The release tarball ships that marker for all four modules, so the
spec does nothing about it. A tarball made any other way (a git archive, a
hand-rolled snapshot) lacks the marker and breaks the offline build.

### 7. Do not declare `%dir` for redis-owned directories

`redis-core` owns `/etc/redis/modules.conf.d` (`0750 redis:root`) and
`/usr/lib64/redis/modules`. A subpackage re-declaring them with different
permissions produces a **file conflict that blocks installation**. The module
packages place files into them and own no directories.

### 8. Keep `-DBUILD_SHARED_LIBS=OFF` on the RediSearch build

`%cmake` passes `-DBUILD_SHARED_LIBS=ON` by default. RediSearch's bundled
libraries (VectorSimilarity, cpu_features, hiredis, fmt, spdlog) then build as
separate `.so` files that `redisearch.so` needs at load time, and the package
has to ship them and fix up RPATHs. Upstream links them statically; the spec
does the same, so the module directory holds only the four modules.

### 9. Local mock tests one chroot; that is not enough

Copr builds eight (F43/44/45/rawhide × aarch64/x86_64). A real failure passed
F43 and F44 while failing F45 and rawhide on both architectures. Before
claiming a build is good, check per-chroot results, not just the top-level
status.

### 10. `/tmp` is a small tmpfs here

Install roots do not fit. `smoke-test.sh` uses `$HOME/.cache/redis-smoke`
deliberately. An out-of-space failure surfaces as a confusing dependency
error.

### 11. `-DINLINE_LSE_ATOMICS=OFF` is deliberate

The default emits Armv8.1-a LSE instructions that `SIGILL` on baseline
Armv8.0-a aarch64 (Cortex-A72, Graviton1, RPi4). Upstream's bundled build
disables it for the same reason. Do not remove it for a performance win.

### 12. Vector sets are not a module

Upstream compiles them into the server (`-DINCLUDE_VEC_SETS=1`). They show
up in `MODULE LIST` as `vectorset` with no package providing them. Nothing to
package; do not try.

## Verifying a change

Minimum before reporting success:

```bash
make lint          # must be 0 errors, 0 warnings
make srpm
make copr          # then check ALL chroots, not just overall status
make smoke         # runtime assertions
```

`make smoke` asserts that a plain `redis-core` install **rejects** `JSON.SET`,
`BF.ADD`, `TS.ADD` and `FT.CREATE`. Those rejections are the test passing, not
failing — they prove nothing leaked in through a weak dependency. That bug was
real: old per-module RPMs carried `Supplements: redis`, back when `redis` was
the plain server, so installing it silently pulled in four unwanted packages.
Never add `Supplements:` or `Recommends:` on `redis-core` to a module package.

It also installs `redisjson` on its own and asserts that only RedisJSON loads.

## Reporting

State what you actually verified and what you did not. "Built successfully"
and "modules load and work" are separate claims; do not let one imply the
other. If a step was skipped or a test not run, say which.
