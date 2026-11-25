# Design: why one SRPM with subpackages

## The problem

Redis and its modules were packaged as **five separate SRPMs**, in five git
repos owned by three different people:

```
redis-rpm            -> redis, redis-devel
redisbloom-rpm       -> redisbloom
redisearch-rpm       -> redisearch
redisjson-rpm        -> redisjson
redistimeseries-rpm  -> redistimeseries
```

Each built independently. That independence caused real, observed breakage:

| Problem found | Consequence |
|---|---|
| `redisearch` and `redisjson` used `Version: 1.0.0` while the rest tracked upstream | two incompatible versioning conventions in one repo |
| `redistimeseries` had `Requires: redis = %{version}` | **unsatisfiable** — module 8.10.0 vs core 8.10.1 |
| `redisbloom` and `redisjson` had no runtime dependency on redis at all | a module `.so` installable with no server to load it |
| `redisjson` and `redisearch` both declared `%dir /etc/redis/modules`, which `redis` already owned with different permissions | **blocked co-installation** — the dnf transaction failed outright |
| `redisjson`'s `Source0` pointed at a GitHub repo that does not exist | unbuildable from the spec alone |

None of these are possible with a single spec.

## Why the split was never buying anything

Upstream pins each module to an exact ref in `modules/modules.yaml`, **per core
release**. Redis 8.10.1 ships redisbloom `v8.10.1` and the other three at
`v8.10.0`; that exact combination is what upstream tests. You cannot ship
redisjson 8.11 against redis 8.10 anyway, so an independent release cadence
per module has nothing to offer.

## What was rejected, and why

Three shapes were considered.

### A. Keep five SRPMs, add a `redis-full` metapackage

A 6.7 KB package containing no files, listing the five as dependencies.
Works, and it shipped — but it only papers over the split. Every problem in
the table above remains, and there are still five things to bump.

### B. One monolithic package containing everything

A single `redis-full` RPM with the server and all modules inside, carrying
`Conflicts:` against the five split packages.

Rejected. It shipped the same paths as the existing packages, so it could
never be co-installed with them, and users could not mix. It also failed four
build attempts on packaging mechanics (see BUILDING.md) before being
abandoned. A monolith gives up granularity without buying consistency that
option C does not already provide.

### C. One SRPM, several subpackages  ← chosen

One source, one build, several ordinary RPMs. Single source of truth from
`modules.yaml`, no `Conflicts:` hackery, packages stay co-installable and
individually removable.

## The final grouping

`redis` is the server, with one subpackage per module:

```
redis.spec
  |-- redis             server, cli, sentinel, vector sets;
  |                     recommends the four modules
  |-- redis-devel       redismodule.h + RPM macros
  |-- redisbloom        \
  |-- redisearch         | one module each: the .so and its loadmodule stub;
  |-- redisjson          | each requires redis
  `-- redistimeseries   /
```

This is the structure of `valkey` and `valkey-rdma` in Fedora: the main
package is the server and a module is a subpackage that requires it.

Each module package adds its own file to `/etc/redis/modules.conf.d`, the
directory agreed for all distributions. Removing one module package disables
that module and leaves the server and the other modules alone.

Each module package has its own `License:` tag and `bundled()` Provides, so
they describe what that one `.so` contains.

### Why the modules are weak dependencies

`dnf install redis` gives the behaviour most people expect from "install
Redis": a working server with the modules upstream ships. `redis` has
`Recommends:` on each module package, so dnf installs them by default.

Because they are weak, a module can be removed without removing the server,
and `--setopt=install_weak_deps=False` gives a plain server. Two consequences:

- `dnf install redisjson` on a clean system also installs the other three
  modules, because `redis` is installed with it and recommends them. Use
  `--setopt=install_weak_deps=False` to get one module only.
- An upgrade does not add a module that was removed or never installed.

`Recommends:` on `redis` was chosen over `Supplements: redis` on the modules.
`valkey-compat-redis` also provides `redis`, and `Supplements:` would match it.

## How modules activate

`redis-conf.patch` adds one line to `redis.conf`:

```
include /etc/redis/modules.conf.d/*.conf
```

The same patch removes the four `loadmodule ./modules/...` lines that the
release tarball's `redis.conf` carries. They point into the source tree, and
Redis aborts at startup when a `loadmodule` target is missing. If upstream
changes that block, the patch stops applying and the build fails in `%prep`.

Each module package drops its stub into that directory:

```
/etc/redis/modules.conf.d/redisbloom.conf   -> loadmodule /usr/lib64/redis/modules/redisbloom.so
/etc/redis/modules.conf.d/search.conf       -> loadmodule /usr/lib64/redis/modules/redisearch.so
/etc/redis/modules.conf.d/redisjson.conf    -> loadmodule /usr/lib64/redis/modules/rejson.so
/etc/redis/modules.conf.d/timeseries.conf   -> loadmodule /usr/lib64/redis/modules/redistimeseries.so
```

So installing the package is what enables the modules — no config editing.

The same patch sets `config-rewrite-source-aware yes`. With it, `CONFIG
REWRITE` leaves settings that come from the included files out of
`redis.conf`. Without it, a rewrite copies the `loadmodule` lines into
`redis.conf`. The option exists from Redis 8.12.
A `redis` install without the module packages leaves that directory empty and the glob
matches nothing, which Redis handles fine (verified).

## Vector sets are not a module

Upstream compiles them into the server binary — `src/Makefile` builds
`hnsw.o`, `vset.o` and `vset_config.o` under `-DINCLUDE_VEC_SETS=1`. They
appear in `MODULE LIST` as `vectorset` with no package providing them, and
`VADD`/`VSIM` work on `redis` with no module package installed. Nothing to package.

## The cost of this design

Being honest about the trade-off:

- **No independent module rebuilds.** A RedisJSON-only fix means rebuilding
  everything, including RediSearch's ~40 minutes.
- **Failure coupling.** If one module fails to compile, *nothing* ships. This
  is not theoretical: during development, core and RedisBloom built fine while
  RedisJSON and RedisTimeSeries failed, and the whole build produced zero
  packages.
- **Version inflation.** Every module package carries the core version, even
  when the module's own upstream version differs (RedisJSON is 8.10.0 inside
  Redis 8.10.3). The actual upstream refs are in `modules/modules.yaml`
  inside the release tarball. The spec does not repeat them.

If independent module hotfixes ever become necessary, the old per-module specs
remain in git history and a single-module spec can be revived.
