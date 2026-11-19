# Release automation

This repo is driven by
[redis-oss-release-automation](https://github.com/redis-developer/redis-oss-release-automation)
in the same way as `redis-rpm`, `redis-debian` and `redis-snap`. The automation
dispatches two workflows and reads one artifact from each.

| Workflow | What it does | Artifact |
|---|---|---|
| `release_build_and_test.yml` | Creates the version branch, sets `Version:` in `redis.spec`, builds the SRPM, rebuilds it with mock in every chroot, runs rpmlint and the smoke tests | `release_handle` |
| `release_publish.yml` | Submits that same SRPM to Copr, waits, checks every chroot, smoke-tests the packages from Copr, then merges and tags a public release | `release_info` |

`build.yml` runs the same build and tests on pull requests and pushes.
All three call `build-n-test.yml`.

## Where the builds run

No dedicated machine is needed. The jobs run on GitHub-hosted runners inside
the `registry.fedoraproject.org/fedora` container image.

- **mock** runs in that container with `--privileged`, which it needs to set up
  a chroot, and with `--isolation=simple`, because the container has no systemd
  for `systemd-nspawn`. mock will not build as root, so the job adds a user in
  the `mock` group.
- **aarch64** builds use the `ubuntu-24.04-arm` runner.
- **Copr** builds run on Fedora's own builders. The workflow only submits the
  SRPM and waits.

The chroots and runners are listed in [`.github/.env.json`](../.github/.env.json).
Set `build` or `test` to `false` to drop a chroot from the mock builds or from
the Copr smoke tests.

## Branches

The automation uses the same branch model as the other package repos.

| Branch | Purpose |
|---|---|
| `unstable` | development |
| `release/8.12` | one per minor release line |
| `8.12.0`, `8.12-rc3` | one per release tag, created by the build workflow from the release branch |

A public release merges its version branch back into the release branch and
tags the merge `v<tag>`.

**The first `release/<major>.<minor>` branch has to be created by hand** from
`unstable`. After that the automation creates each new release branch from the
previous one.

## Versions

The release tag is written to `Version:` in `redis.spec`, which is the only
place the version is recorded. A pre-release tag such as `8.12-rc3` becomes
`8.12~rc3`, so that it sorts before `8.12`. `Release:` is reset to 1 and the
newest changelog entry is set to the new version.

The vendored crate tarballs are not committed. The build workflow regenerates
them from the release tarball with `make sources`.

What the automation cannot do is described in
[MAINTENANCE.md](MAINTENANCE.md): if a release moves RediSearch's FetchContent
pins or the bundled library versions, the spec needs a manual change on the
release branch. A stale pin fails the mock build, so it cannot be published by
mistake. There is no `unstable` build, because there is no release tarball to
package.

## Release types

| `release_type` | Copr project |
|---|---|
| `public` | repository variable `COPR_PROJECT`, default `@redis/redis` |
| `internal` | repository variable `COPR_PROJECT_STAGING`. The publish fails if it is not set |

## Secrets and variables

| Name | Kind | Required | Contents |
|---|---|---|---|
| `COPR_CONFIG` | secret | yes | A `~/.config/copr` file from <https://copr.fedorainfracloud.org/api/>, for an account that may build in the project. Copr tokens expire after 180 days |
| `COPR_CONFIG_STAGING` | secret | no | The same for the staging project. Falls back to `COPR_CONFIG` |
| `COPR_PROJECT` | variable | no | Copr project for public releases |
| `COPR_PROJECT_STAGING` | variable | for internal releases | Copr project for internal releases |
| `SLACK_WEB_HOOK_URL` | secret | no | Release notifications |

## Running a release by hand

```bash
gh workflow run release_build_and_test.yml \
  -f release_tag=8.12.0 -f release_type=internal

# when it has finished, take release_handle/result.json from the run
gh workflow run release_publish.yml \
  -f release_tag=8.12.0 -f release_type=internal \
  -f release_handle='{"release_tag":"8.12.0","run_id":123456789,"release_type":"internal"}'
```
