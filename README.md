# rossmoney_me_live-to-dev-sync

Nightly refresh of the dev databases from the newest production MongoDB dump,
with a media mirror and the dev admin kept in place.

This container replaces the old root-crontab job. It runs its own `cron` and
talks to each target over the network; it never shells into a database
container. The reference behaviour is kept in
[`legacy/rosso-dev-sync.sh`](legacy/rosso-dev-sync.sh).

## Targets

`SYNC_TARGETS` is a space-separated list of target names. The default is
`local atlas`:

| Target | Database | Media mirror | CMS media backfill |
| --- | --- | --- | --- |
| `local` | `rossmoney_dev`, the screenshot service's database | yes, into `/media` | only when `LOCAL_CMS_URL` is set |
| `atlas` | `rossmoney_me_dev`, the Atlas dev site's database | no | only when `ATLAS_CMS_URL` is set |

Each target reads `<NAME>_MONGODB_URI`, `<NAME>_TARGET_DB`, optionally
`<NAME>_STAGING_DB` (legacy cleanup only), optionally `<NAME>_MEDIA_DIR`, and
optionally `<NAME>_CMS_URL`, where `<NAME>` is the uppercased target name. For
example, `local` uses `LOCAL_MONGODB_URI` and `atlas` uses
`ATLAS_MONGODB_URI`.

Staging happens inside the target database: each collection is imported as
`__staging_<collection>` and renamed into place within that same database.
Atlas rejects `renameCollection` across databases, so the two targets use the
same mechanism. `<NAME>_STAGING_DB` is legacy: if set, the old separate staging
database is dropped at target start if it exists, but it is not used for the
swap.

With no `ATLAS_*` variables set, the default run refreshes only `local` and
still succeeds. A target named explicitly in `SYNC_TARGETS` is required, so
`SYNC_TARGETS=atlas` without `ATLAS_MONGODB_URI` fails.

## What a run does

1. Lists `s3://$S3_BUCKET` and picks the newest
   `adb-rossmoney_YYYYMMDD_HHMMSS.tar.gz`.
2. Downloads and extracts it once, rejecting unsafe collection names and
   non-array EJSON files.
3. For each target, in `SYNC_TARGETS` order:
   - drops any leftover `__staging_*` collections in the target database and
     the old separate staging database if `<NAME>_STAGING_DB` names one;
   - restores every collection into that target database as
     `__staging_<collection>`, including empty ones;
   - verifies every staging collection's document count against the dump;
   - renames each `__staging_<collection>` into place within the same target
     database, one at a time;
   - ensures the dev admin `$DEV_ADMIN_EMAIL` exists and has the password in
     `$DEV_ADMIN_PASSWORD`;
   - if the target names a CMS URL, logs in as the dev admin and calls
     `POST /api/media/backfill` so the site can materialise the imported media
     rows as blob objects;
   - mirrors media only if the target names a media directory;
   - drops the remaining `__staging_*` collections.
4. Removes the shared work directory contents and prints one line naming every
   target:

   ```text
   OK local collections=23 documents=16127 media=7 | atlas collections=23 documents=16127 elapsed=12s archive=adb-rossmoney_20260101_034000.tar.gz
   ```

`users` and `payload-preferences` are never written from the dump. The only
user written is the dev admin: it is created if missing, or its password is
updated if it is there. Every other user, including the account the screenshot
service signs in with, is untouched.

The media mirror downloads into a temporary directory first. The live
`/media` directory is replaced only after every file has arrived, so a failed
download leaves the previous media in place. When `/media` is a mount point,
its contents are replaced in place after the downloads have succeeded.
A manifest is written next to the media directory
(`<media dir>.manifest.json`).

The CMS media backfill is cosmetic. When a target has `<NAME>_CMS_URL`, the
script logs in with `POST $CMS_URL/api/users/login` using the dev admin
credentials, then calls `POST $CMS_URL/api/media/backfill` with
`Authorization: JWT <token>` and no body. It prints one line per target:

```text
media-backfill uploaded=2 skipped=5 failed=0 target=atlas
```

If the login or the route fails, including a 404 when the route is not deployed
yet, the script logs one `WARNING: media-backfill ...` line and carries on. The
database refresh is still reported as a success.

A failure exits non-zero and prints one line naming the target, database, and
mechanism:

```text
FAILED: atlas: renameCollection within rossmoney_me_dev failed for _pages_versions
```

If the S3 listing fails, the line also carries the HTTP status and the first
line of the response body, for example:

```text
FAILED: cannot list s3://example-dumps (HTTP 403: <Error><Code>SignatureDoesNotMatch</Code></Error>)
```

Targets are processed in order and a failure stops the run. A target that
already completed stays complete, a target that has not started is untouched,
and no target is rolled back or copied over another target.

A second run is refused while the lock is held and exits `0` with
`SKIPPED: another run holds <lock>`.

## Environment variables

All values are supplied by the deployment environment. Do not put credentials
in this repository or in the image.

### Shared

| Variable | Default | Example | Purpose |
| --- | --- | --- | --- |
| `SYNC_TARGETS` | `local atlas` | `local atlas` | Space-separated targets to refresh, in order |
| `S3_ENDPOINT` | required | `https://minio.example.com:9000` | S3-compatible endpoint, no trailing slash |
| `S3_BUCKET` | required | `example-dumps` | Bucket holding the production dumps |
| `AWS_ACCESS_KEY_ID` | required | `example-access-key` | S3 access key |
| `AWS_SECRET_ACCESS_KEY` | required | `example-secret-key` | S3 secret key |
| `MEDIA_SOURCE` | `https://www.rossmoney.me/media` | `https://media.example.com/media` | Base URL media files are fetched from |
| `DEV_ADMIN_EMAIL` | required | `dev@example.com` | Dev admin account created or updated in every target |
| `DEV_ADMIN_PASSWORD` | required | `example-dev-password` | Password for the dev admin |
| `WORK_DIR` | `/var/lib/rosso-dev-sync/work` | `/var/lib/rosso-dev-sync/work` | Download and staging area; the archive is kept there on failure. The stack bind-mounts `${WORK_HOST_PATH}` here. |
| `LOG` | `/var/log/rosso-dev-sync/sync.log` | `/var/log/rosso-dev-sync/sync.log` | Bounded job log; use `/dev/stdout` for a direct run. The stack bind-mounts `${LOG_HOST_PATH}` at the log directory. |
| `LOCK` | `/run/rosso-dev-sync.lock` | `/run/rosso-dev-sync.lock` | Prevents overlapping runs |
| `RUN_ONCE` | `0` | `1` | Run the job immediately instead of starting cron |
| `TZ` | `UTC` | `UTC` | Container timezone; the crontab also pins UTC |

### Local target

| Variable | Default | Example | Purpose |
| --- | --- | --- | --- |
| `LOCAL_MONGODB_URI` | required | `mongodb://devsync:example-password@mongo.example.com:27017/?authSource=admin` | MongoDB connection URI |
| `LOCAL_TARGET_DB` | `rossmoney_dev` | `rossmoney_dev` | Dev database refreshed for the screenshot service |
| `LOCAL_STAGING_DB` | `rossmoney_dev_staging` | `rossmoney_dev_staging` | Legacy cleanup only: old separate staging DB dropped at target start if present; not used for the swap |
| `LOCAL_MEDIA_DIR` | `/media` | `/media` | Media directory; set empty to skip the mirror |
| `LOCAL_CMS_URL` | unset | `https://cms.example.com` | Optional base URL for the media backfill; unset skips it |

### Atlas target

| Variable | Default | Example | Purpose |
| --- | --- | --- | --- |
| `ATLAS_MONGODB_URI` | required when `atlas` is active | `mongodb+srv://devsync:example-password@cluster0.example.com/?retryWrites=true&w=majority` | Atlas SRV connection URI |
| `ATLAS_TARGET_DB` | required when `atlas` is active | `rossmoney_me_dev` | Atlas dev database |
| `ATLAS_STAGING_DB` | unset | `rossmoney_me_dev_staging` | Legacy cleanup only: old separate staging DB dropped at target start if present; not used for the swap |
| `ATLAS_MEDIA_DIR` | unset | unset | Optional; Atlas has no media mirror |
| `ATLAS_CMS_URL` | unset | `https://dev.example.com` | Optional base URL for the media backfill; unset skips it |

The Atlas deployment uses the `mongodb+srv` shape. `mongodb+srv` resolves the
cluster through DNS and uses TLS by default, so the image includes
`ca-certificates`; the script makes no IPv4-only assumptions. The script also
accepts a standard `mongodb://` URI for a local or Atlas target when that is
how the deployment is wired.

`LOCAL_MONGODB_URI`, `ATLAS_MONGODB_URI`, `AWS_SECRET_ACCESS_KEY`, and
`DEV_ADMIN_PASSWORD` are secrets.

## Build

The image is based on `mongo:7`, but it carries curl `8.10.1` built from the
official curl source in a builder stage, ahead of the base image's curl `7.81.0`.
The older curl mishandles `--aws-sigv4` with a query string, which turns an S3
listing into `SignatureDoesNotMatch`; the Mongo tooling is unchanged. The build
asserts `curl --version`, and the image smoke test checks `curl`, `mongosh`,
`mongoimport`, and an anonymous HTTPS request. The signed S3 listing needs the
stack credentials, so it is not run in CI.

The image is built and published by `.github/workflows/build.yml` on a
GitHub-hosted `ubuntu-latest` runner. A push to `main` or a manual
`workflow_dispatch` publishes:

- `ghcr.io/tekkifox/rossmoney_me_live-to-dev-sync:latest`
- `ghcr.io/tekkifox/rossmoney_me_live-to-dev-sync:sha-<short sha>`

The build uses the `gha` cache (`cache-from`/`cache-to`), so rebuilds do not
depend on a warm host. A separate `pr-build.yml` workflow builds the image on
pull requests without pushing it, so PR checks do not move any image tags.

To build locally where a Docker daemon is available:

```console
docker build -t rossmoney-live-to-dev-sync:local .
```

## Run once

Start a one-off container without cron:

```console
docker run --rm \
  --env-file .env \
  -v "$MEDIA_HOST_PATH":/media \
  -v "$WORK_HOST_PATH":/var/lib/rosso-dev-sync/work \
  -v "$LOG_HOST_PATH":/var/log/rosso-dev-sync \
  rossmoney-live-to-dev-sync:local run-once
```

`RUN_ONCE=1` works too:

```console
docker run --rm -e RUN_ONCE=1 --env-file .env \
  -v "$MEDIA_HOST_PATH":/media \
  -v "$WORK_HOST_PATH":/var/lib/rosso-dev-sync/work \
  -v "$LOG_HOST_PATH":/var/log/rosso-dev-sync \
  rossmoney-live-to-dev-sync:local
```

To run only one target, pass `SYNC_TARGETS` in the same environment:

```console
docker run --rm --env-file .env -e SYNC_TARGETS=local \
  -v "$MEDIA_HOST_PATH":/media \
  -v "$WORK_HOST_PATH":/var/lib/rosso-dev-sync/work \
  -v "$LOG_HOST_PATH":/var/log/rosso-dev-sync \
  rossmoney-live-to-dev-sync:local run-once
```

Against a container that is already running, execute the job in that container
so it shares the lock and media directory:

```console
docker exec -e LOG=/dev/stdout rosso-dev-sync /usr/local/bin/sync.sh
```

## Deploy as a stack

The stack is Ansible-owned on `paseo` as `paseo-rosso-dev-sync`, running
`ghcr.io/tekkifox/rossmoney_me_live-to-dev-sync:latest`. This repository
publishes that image but does not create or edit the stack. After every push to
`main`, `.github/workflows/build.yml` builds and pushes the image, joins the
tailnet with the `TS_AUTHKEY` repository secret, then uses the `DEPLOY_SSH_KEY`
and `DEPLOY_SEAT_HOST` repository secrets to ask the fleet deploy seat to
deploy `paseo-rosso-dev-sync` on `paseo`. The first push to `main` after this
change is the proof that the deploy works.

[`compose.deploy.yaml`](compose.deploy.yaml) is kept as the reference stack
definition; CI no longer reads it. The stack's environment is maintained by the
fleet Ansible configuration, which must provide these placeholders:

| Placeholder | Purpose |
| --- | --- |
| `${SYNC_TARGETS}` | Space-separated targets; empty uses the container default |
| `${LOCAL_MONGODB_URI}` | Local MongoDB URI |
| `${LOCAL_TARGET_DB}` | Local target database; empty uses `rossmoney_dev` |
| `${LOCAL_STAGING_DB}` | Legacy cleanup only; empty uses `rossmoney_dev_staging` |
| `${LOCAL_CMS_URL}` | Optional local CMS base URL |
| `${ATLAS_MONGODB_URI}` | Atlas SRV URI |
| `${ATLAS_TARGET_DB}` | Atlas target database |
| `${ATLAS_STAGING_DB}` | Legacy cleanup only; empty skips the old Atlas staging DB |
| `${ATLAS_CMS_URL}` | Optional Atlas CMS base URL |
| `${S3_ENDPOINT}` | S3-compatible endpoint |
| `${S3_BUCKET}` | Dump bucket |
| `${AWS_ACCESS_KEY_ID}` | S3 access key |
| `${AWS_SECRET_ACCESS_KEY}` | S3 secret key |
| `${MEDIA_SOURCE}` | Media source base URL; empty uses the public default |
| `${DEV_ADMIN_EMAIL}` | Dev admin email |
| `${DEV_ADMIN_PASSWORD}` | Dev admin password |
| `${MEDIA_HOST_PATH}` | Absolute host path bind-mounted at `/media` |
| `${WORK_HOST_PATH}` | Absolute host path bind-mounted at `/var/lib/rosso-dev-sync/work` |
| `${LOG_HOST_PATH}` | Absolute host path bind-mounted at `/var/log/rosso-dev-sync` |

`LOCAL_MEDIA_DIR` is fixed to `/media` in the stack file and `TZ` is fixed to
`UTC`. The stack attaches to the external network `rosso-mongo-dev_default`, so
`LOCAL_MONGODB_URI` can use the database service name on that network instead of
an address. All URIs, credentials, and host paths stay in the stack environment;
none of them are in this repository.

`/media` is a bind mount from `${MEDIA_HOST_PATH}`. It holds the mirrored media
files and must be the same directory the screenshot service reads. The Atlas
target has no media directory.

`/var/lib/rosso-dev-sync/work` and `/var/log/rosso-dev-sync` are bind mounts
from `${WORK_HOST_PATH}` and `${LOG_HOST_PATH}`. Both host directories must
exist and be writable by the container's root user; on the host they are
`ross:ross` mode `0755` and empty. The image creates the same directories with
usable ownership, so an empty host directory (or no mount at all) also works.

The stack keeps three host-side pieces of data: the media bind mount from
`${MEDIA_HOST_PATH}` at `/media`, the work bind mount from `${WORK_HOST_PATH}`
at `/var/lib/rosso-dev-sync/work`, and the log bind mount from
`${LOG_HOST_PATH}` at `/var/log/rosso-dev-sync`. The stack does not create the
host directories. Removing their contents discards the kept archive and the
log. The bind mounts are declared regardless of the environment; if `WORK_DIR`
or `LOG` are overridden, the job writes to the overridden path and the bind
mounts remain at the defaults, so keep the defaults to retain that data.

The GHCR package is private, so the fleet deployment configuration needs
registry credentials that can pull it.

## Cron and logs

`/etc/cron.d/rosso-dev-sync` runs the job daily at 03:40 UTC with an absolute
path. The entrypoint follows the log file into the container's stdout, so:

```console
docker logs -f rosso-dev-sync
```

shows every run. The log is rotated to `<log>.1` when it exceeds 2 MB.
