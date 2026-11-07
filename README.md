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

| Target | Database | Media mirror |
| --- | --- | --- |
| `local` | `rossmoney_dev`, the screenshot service's database | yes, into `/media` |
| `atlas` | `rossmoney_me_dev`, what `dev.rossmoney.me` reads | no |

Each target reads `<NAME>_MONGODB_URI`, `<NAME>_TARGET_DB`,
`<NAME>_STAGING_DB`, and optionally `<NAME>_MEDIA_DIR`, where `<NAME>` is the
uppercased target name. For example, `local` uses `LOCAL_MONGODB_URI` and
`atlas` uses `ATLAS_MONGODB_URI`.

With no `ATLAS_*` variables set, the default run refreshes only `local` and
still succeeds. A target named explicitly in `SYNC_TARGETS` is required, so
`SYNC_TARGETS=atlas` without `ATLAS_MONGODB_URI` fails.

## What a run does

1. Lists `s3://$S3_BUCKET` and picks the newest
   `adb-rossmoney_YYYYMMDD_HHMMSS.tar.gz`.
2. Downloads and extracts it once, rejecting unsafe collection names and
   non-array EJSON files.
3. For each target, in `SYNC_TARGETS` order:
   - restores every collection into that target's staging database, including
     empty ones;
   - verifies every collection's document count against the dump;
   - swaps the staged collections into the target database one at a time;
   - ensures the dev admin `$DEV_ADMIN_EMAIL` exists and has the password in
     `$DEV_ADMIN_PASSWORD`;
   - mirrors media only if the target names a media directory;
   - drops the staging database.
4. Removes the shared work directory and prints one line naming every target:

   ```text
   OK local collections=23 documents=16127 media=7 | atlas collections=23 documents=16127 elapsed=12s archive=adb-rossmoney_20260101_034000.tar.gz
   ```

`users` and `payload-preferences` are never written from the dump. The only
user written is the dev admin: it is created if missing, or its password is
updated if it is there. Every other user, including the account the screenshot
service signs in with, is untouched.

The media mirror downloads into a temporary directory first. The live
`/media` directory is replaced only after every file has arrived, so a failed
download leaves the previous media in place. A manifest is written next to the
media directory (`<media dir>.manifest.json`).

A failure exits non-zero and prints one line naming the target and step:

```text
FAILED: atlas: import failed for posts
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
| `WORK_DIR` | `/var/lib/rosso-dev-sync/work` | `/var/lib/rosso-dev-sync/work` | Download and staging area; the archive is kept there on failure |
| `LOG` | `/var/log/rosso-dev-sync/sync.log` | `/var/log/rosso-dev-sync/sync.log` | Bounded job log; use `/dev/stdout` for a direct run |
| `LOCK` | `/run/rosso-dev-sync.lock` | `/run/rosso-dev-sync.lock` | Prevents overlapping runs |
| `RUN_ONCE` | `0` | `1` | Run the job immediately instead of starting cron |
| `TZ` | `UTC` | `UTC` | Container timezone; the crontab also pins UTC |

### Local target

| Variable | Default | Example | Purpose |
| --- | --- | --- | --- |
| `LOCAL_MONGODB_URI` | required | `mongodb://devsync:example-password@mongo.example.com:27017/?authSource=admin` | MongoDB connection URI |
| `LOCAL_TARGET_DB` | `rossmoney_dev` | `rossmoney_dev` | Dev database refreshed for the screenshot service |
| `LOCAL_STAGING_DB` | `rossmoney_dev_staging` | `rossmoney_dev_staging` | Temporary restore database |
| `LOCAL_MEDIA_DIR` | `/media` | `/media` | Media directory; set empty to skip the mirror |

### Atlas target

| Variable | Default | Example | Purpose |
| --- | --- | --- | --- |
| `ATLAS_MONGODB_URI` | required when `atlas` is active | `mongodb+srv://devsync:example-password@cluster0.example.com/?retryWrites=true&w=majority` | Atlas SRV connection URI |
| `ATLAS_TARGET_DB` | required when `atlas` is active | `rossmoney_me_dev` | Atlas dev database |
| `ATLAS_STAGING_DB` | required when `atlas` is active | `rossmoney_me_dev_staging` | Temporary restore database |
| `ATLAS_MEDIA_DIR` | unset | unset | Optional; Atlas has no media mirror |

The Atlas URI must use the `mongodb+srv` shape. `mongodb+srv` resolves the
cluster through DNS and uses TLS by default, so the image includes
`ca-certificates`; the script makes no IPv4-only assumptions. A standard
`mongodb://` URI also works for a local or Atlas target when needed.

`LOCAL_MONGODB_URI`, `ATLAS_MONGODB_URI`, `AWS_SECRET_ACCESS_KEY`, and
`DEV_ADMIN_PASSWORD` are secrets.

## Build

The image is built and published by `.github/workflows/build.yml` on the
self-hosted paseo runner. A push to `main` or a manual `workflow_dispatch`
publishes:

- `ghcr.io/tekkifox/rossmoney_me_live-to-dev-sync:latest`
- `ghcr.io/tekkifox/rossmoney_me_live-to-dev-sync:sha-<short sha>`

Pull requests also build the image as a check. A same-repository pull request
pushes only its short-SHA tag; `latest` is enabled only on the default branch.
Fork pull requests build without pushing.

To build locally where a Docker daemon is available:

```console
docker build -t rossmoney-live-to-dev-sync:local .
```

## Run once

Start a one-off container without cron:

```console
docker run --rm \
  --env-file .env \
  -v rossmoney_media:/media \
  rossmoney-live-to-dev-sync:local run-once
```

`RUN_ONCE=1` works too:

```console
docker run --rm -e RUN_ONCE=1 --env-file .env \
  -v rossmoney_media:/media rossmoney-live-to-dev-sync:local
```

To run only one target, pass `SYNC_TARGETS` in the same environment:

```console
docker run --rm --env-file .env -e SYNC_TARGETS=local \
  -v rossmoney_media:/media rossmoney-live-to-dev-sync:local run-once
```

Against a container that is already running, execute the job in that container
so it shares the lock and media directory:

```console
docker exec -e LOG=/dev/stdout rossmoney-live-to-dev-sync /usr/local/bin/sync.sh
```

## Deploy as a stack

Deploy this as a Portainer stack. Set the environment variables in the stack
environment (or as Portainer secrets); do not bake them into the compose file.
The GHCR package is private, so the Portainer registry configuration needs
credentials that can pull it.

```yaml
services:
  live-to-dev-sync:
    image: ghcr.io/tekkifox/rossmoney_me_live-to-dev-sync:latest
    container_name: rossmoney-live-to-dev-sync
    restart: unless-stopped
    environment:
      LOCAL_MONGODB_URI: ${LOCAL_MONGODB_URI}
      LOCAL_TARGET_DB: ${LOCAL_TARGET_DB:-rossmoney_dev}
      LOCAL_STAGING_DB: ${LOCAL_STAGING_DB:-rossmoney_dev_staging}
      LOCAL_MEDIA_DIR: /media
      ATLAS_MONGODB_URI: ${ATLAS_MONGODB_URI:-}
      ATLAS_TARGET_DB: ${ATLAS_TARGET_DB:-}
      ATLAS_STAGING_DB: ${ATLAS_STAGING_DB:-}
      S3_ENDPOINT: ${S3_ENDPOINT}
      S3_BUCKET: ${S3_BUCKET}
      AWS_ACCESS_KEY_ID: ${AWS_ACCESS_KEY_ID}
      AWS_SECRET_ACCESS_KEY: ${AWS_SECRET_ACCESS_KEY}
      MEDIA_SOURCE: ${MEDIA_SOURCE:-https://www.rossmoney.me/media}
      DEV_ADMIN_EMAIL: ${DEV_ADMIN_EMAIL}
      DEV_ADMIN_PASSWORD: ${DEV_ADMIN_PASSWORD}
      TZ: UTC
    volumes:
      - media:/media

volumes:
  media:
```

Leave `SYNC_TARGETS` unset to use the default `local atlas`; the `atlas` target
is skipped automatically when `ATLAS_MONGODB_URI` is empty. To run only one
target, set `SYNC_TARGETS` in the stack environment.

`/media` is a volume. It holds the mirrored media files and must be the same
directory the screenshot service reads; keeping it on a named volume means the
files survive container replacement. The Atlas target has no media directory.

## Cron and logs

`/etc/cron.d/rosso-dev-sync` runs the job daily at 03:40 UTC with an absolute
path. The entrypoint follows the log file into the container's stdout, so:

```console
docker logs -f rossmoney-live-to-dev-sync
```

shows every run. The log is rotated to `<log>.1` when it exceeds 2 MB.
