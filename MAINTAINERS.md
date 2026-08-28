# Maintainers

## Current maintenance

**TO BE CONFIRMED** — this section records what is observable, not an agreed
arrangement. Fill it in.

| Area | Owner |
|---|---|
| `redis.spec`, build pipeline | _unassigned_ |
| Copr project `@redis/redis` | FAS group `redis` (https://accounts.fedoraproject.org/group/redis/) |
| Version bumps / release | _unassigned_ |
| This repo's hosting location | _undecided — currently local only_ |

Builds are currently submitted to Copr as FAS user `angelyanev`, via a
personal API token. If this becomes shared maintenance, that is worth
revisiting: token-based Copr auth is per-user and expires every 180 days.
Kerberos (`fkinit` + `gssapi = True` in `~/.config/copr`) avoids the long-lived
secret.

## Open decisions

These need people, not code:

1. **Where this repo lives.** It is currently a local directory owned by no
   GitHub account. Consolidating five repos across three owners into one means
   agreeing on a home — a shared org, or one owner's account.

2. **What happens to the five predecessor repos.** They are superseded but
   still exist, at their pre-8.10 state (the 8.10 fixes were committed locally
   and never pushed). Options: archive them read-only with a pointer here, or
   leave them. Deleting them would discard history that this spec is derived
   from; archiving is the safer default.

3. **Who reviews changes.** With one spec producing all packages, a bad change
   now breaks Redis *and* every module at once. That argues for review on
   spec changes in a way five independent repos did not.

4. **Release cadence.** Module versions are pinned by upstream's
   `modules/modules.yaml` per Redis release, so bumps follow upstream Redis.
   Whether to track every patch release is a policy call.

## How to take over

Read, in order:

1. [`AGENTS.md`](AGENTS.md) — the non-obvious constraints, and the failure
   modes that cost the most time
2. [`docs/DESIGN.md`](docs/DESIGN.md) — why the packaging is shaped this way
3. [`docs/MAINTENANCE.md`](docs/MAINTENANCE.md) — the bump procedure

Then verify you can reproduce a build end to end:

```bash
make check-tools
make sources && make srpm && make lint
make copr        # needs Copr access to @redis/redis
make smoke
```

If `make copr` is refused, FAS membership in the `redis` group is not by
itself enough — Copr permissions on the group project are granted separately
by a Copr admin of that group.
