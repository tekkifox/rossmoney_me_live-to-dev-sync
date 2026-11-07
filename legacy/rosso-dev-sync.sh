#!/bin/bash
# REFERENCE ONLY - this is the script as it runs today from paseo's root crontab.
# Do not run it as-is: it shells into the mongo container with `docker exec` and
# `docker cp`, which a container of its own cannot do. Port the logic into
# sync.sh at the repository root, talking to $MONGODB_URI directly.

#
# Runs on paseo from root's crontab at 03:40 UTC, after the 03:10 dump. The dev
# database is restored into a staging database first, checked, then swapped in
# per collection so it is never empty or half-written. users and
# payload-preferences are deliberately left alone: they hold the dev admin the
# tests and screenshots log in with.
#
# Credentials live in /opt/rossmoney-dev-sync/{minio,mongo}.env (600, root) and
# are never printed. A failure leaves the downloaded archive in
# /opt/rossmoney-dev-sync/work and names the failed step in the log.
set -euo pipefail

LOG=/var/log/rosso-dev-sync.log
LOCK=/run/rosso-dev-sync.lock
CONF=/opt/rossmoney-dev-sync
WORK="$CONF/work"
MEDIA_DIR="$CONF/media"
MEDIA_MANIFEST="$CONF/media-manifest.json"
ARCHIVE_PREFIX=adb-rossmoney_
MONGO_CONTAINER=rosso-mongo-dev
STAGING=rossmoney_dev_staging
TARGET=rossmoney_dev
KEEP=(users payload-preferences)

START=$SECONDS
ARCHIVE_KEY=""
ARCHIVE=""
CONTAINER_TMP=""
MEDIA_TMP=""
MANIFEST_TMP=""

fail() {
  echo "$(date -Is) rosso-dev-sync FAILED: $* (archive=${ARCHIVE:-none}, elapsed=$((SECONDS - START))s)"
  exit 1
}

cleanup() {
  if [ -n "$CONTAINER_TMP" ]; then
    docker exec "$MONGO_CONTAINER" rm -rf "$CONTAINER_TMP" >/dev/null 2>&1 || true
  fi
  if [ -n "$MEDIA_TMP" ] && [ -d "$MEDIA_TMP" ]; then
    rm -rf "$MEDIA_TMP" || true
  fi
  if [ -n "$MANIFEST_TMP" ] && [ -f "$MANIFEST_TMP" ]; then
    rm -f "$MANIFEST_TMP" || true
  fi
}

trap cleanup EXIT
trap 'fail "unexpected error at line $LINENO"' ERR

[ "$(id -u)" -eq 0 ] || { echo "rosso-dev-sync must run as root" >&2; exit 1; }

# Keep the log bounded; the previous run is enough history.
mkdir -p "$(dirname "$LOG")"
if [ -f "$LOG" ] && [ "$(stat -c%s "$LOG")" -gt 2000000 ]; then
  mv -f "$LOG" "$LOG.1"
fi
exec >>"$LOG" 2>&1

exec 9>"$LOCK" || exit 1
if ! flock -n 9; then
  echo "$(date -Is) rosso-dev-sync SKIPPED: another run holds $LOCK"
  exit 0
fi

for f in "$CONF/minio.env" "$CONF/mongo.env"; do
  [ -r "$f" ] || fail "missing $f"
done
set -a
# shellcheck disable=SC1091
. "$CONF/minio.env"
# shellcheck disable=SC1091
. "$CONF/mongo.env"
set +a

for name in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY S3_ENDPOINT S3_BUCKET MONGODB_URI; do
  if [ -z "${!name:-}" ]; then
    fail "missing $name in $CONF/*.env"
  fi
done

for cmd in curl tar gzip jq flock docker node stat; do
  command -v "$cmd" >/dev/null 2>&1 || fail "missing command: $cmd"
done
docker inspect "$MONGO_CONTAINER" >/dev/null 2>&1 || fail "container $MONGO_CONTAINER is not running"

# The shared server sits behind the host's docker bridge; from inside the
# database container it is loopback. Rewrite only the authority, keeping
# credentials and options.
MONGODB_URI=$(node -e 'const u = new URL(process.env.MONGODB_URI); u.host = "127.0.0.1:27017"; process.stdout.write(u.toString())') \
  || fail "cannot parse MONGODB_URI"
export MONGODB_URI

mongo_eval() {
  docker exec -i -e MONGODB_URI "$MONGO_CONTAINER" \
    sh -c 'mongosh "$MONGODB_URI" --quiet --eval "$1"' _ "$1"
}

mongo_import() {
  docker exec -i -e MONGODB_URI "$MONGO_CONTAINER" \
    sh -c 'mongoimport --uri "$MONGODB_URI" --db "$1" --collection "$2" --file "$3" --jsonArray --quiet' \
    _ "$1" "$2" "$3"
}

# Keep the secret out of curl's argv. A config on stdin carries the user:pass.
s3_curl() {
  local ak=${AWS_ACCESS_KEY_ID//\\/\\\\}
  local sk=${AWS_SECRET_ACCESS_KEY//\\/\\\\}
  ak=${ak//\"/\\\"}
  sk=${sk//\"/\\\"}
  printf 'user = "%s:%s"\n' "$ak" "$sk" |
    curl -fsS -K - --aws-sigv4 "aws:amz:us-east-1:s3" "$@"
}

# 1. Find the newest dump.
LIST_XML=$(s3_curl --max-time 60 "$S3_ENDPOINT/$S3_BUCKET?list-type=2&prefix=$ARCHIVE_PREFIX") \
  || fail "cannot list s3://$S3_BUCKET"
ARCHIVE_KEY=$(printf '%s\n' "$LIST_XML" \
  | grep -o '<Key>[^<]*</Key>' \
  | sed -E 's#</?Key>##g' \
  | grep -E "^${ARCHIVE_PREFIX}[0-9]{8}_[0-9]{6}\.tar\.gz$" \
  | sort \
  | tail -n 1 || true)
[ -n "$ARCHIVE_KEY" ] || fail "no ${ARCHIVE_PREFIX}*.tar.gz archive in s3://$S3_BUCKET"

# 2. Download and extract it.
rm -rf "$WORK"
mkdir -p "$WORK/dump"
chmod 700 "$WORK"
ARCHIVE="$WORK/$ARCHIVE_KEY"
s3_curl --max-time 300 -o "$ARCHIVE" "$S3_ENDPOINT/$S3_BUCKET/$ARCHIVE_KEY" \
  || fail "download failed for $ARCHIVE_KEY"
chmod 600 "$ARCHIVE"

tar -xzf "$ARCHIVE" -C "$WORK/dump" || fail "cannot extract $ARCHIVE_KEY"
mapfile -t FILES < <(find "$WORK/dump" -maxdepth 1 -type f -name '*.json' -printf '%f\n' | sort)
[ "${#FILES[@]}" -gt 0 ] || fail "archive $ARCHIVE_KEY contains no collection JSON files"

COLLS=()
declare -A EXPECTED_COUNT=()
EXPECTED_DOCS=0
for f in "${FILES[@]}"; do
  c=${f%.json}
  [[ $c =~ ^[A-Za-z0-9._-]+$ ]] || fail "unsafe collection name in archive: $c"
  n=$(jq -e 'if type == "array" then length else error("not an array") end' "$WORK/dump/$f") \
    || fail "invalid EJSON in $f"
  COLLS+=("$c")
  EXPECTED_COUNT[$c]=$n
  EXPECTED_DOCS=$((EXPECTED_DOCS + n))
done
[ "$EXPECTED_DOCS" -gt 0 ] || fail "archive $ARCHIVE_KEY contains zero documents"

# 3. Restore every collection into the staging database, empty ones included.
mongo_eval "db.getSiblingDB('$STAGING').dropDatabase()" >/dev/null \
  || fail "cannot drop $STAGING"
for c in "${COLLS[@]}"; do
  mongo_eval "db.getSiblingDB('$STAGING').createCollection('$c')" >/dev/null \
    || fail "cannot create staging collection $c"
done

CONTAINER_TMP="/tmp/rosso-dev-sync.$$"
docker exec "$MONGO_CONTAINER" mkdir -p "$CONTAINER_TMP" \
  || fail "cannot create $CONTAINER_TMP in $MONGO_CONTAINER"
for f in "${FILES[@]}"; do
  docker cp "$WORK/dump/$f" "$MONGO_CONTAINER:$CONTAINER_TMP/$f" >/dev/null \
    || fail "cannot copy $f into $MONGO_CONTAINER"
done

for c in "${COLLS[@]}"; do
  if [ "${EXPECTED_COUNT[$c]}" -gt 0 ]; then
    mongo_import "$STAGING" "$c" "$CONTAINER_TMP/$c.json" \
      || fail "import failed for $c"
  fi
done

STATS=$(mongo_eval "
const s = db.getSiblingDB('$STAGING');
const names = s.getCollectionNames();
let total = 0;
for (const c of names) total += s.getCollection(c).countDocuments({});
print(JSON.stringify({ collections: names.length, documents: total }));
") || fail "cannot verify $STAGING"
STAGE_COLLECTIONS=$(printf '%s' "$STATS" | jq -er '.collections') \
  || fail "unexpected staging stats: $STATS"
STAGE_DOCS=$(printf '%s' "$STATS" | jq -er '.documents') \
  || fail "unexpected staging stats: $STATS"
[ "$STAGE_COLLECTIONS" -eq "${#COLLS[@]}" ] \
  || fail "staging has $STAGE_COLLECTIONS collections, expected ${#COLLS[@]}"
[ "$STAGE_DOCS" -eq "$EXPECTED_DOCS" ] \
  || fail "staging has $STAGE_DOCS documents, expected $EXPECTED_DOCS"

# 4. Swap in per collection; users and payload-preferences stay as they are.
SYNCED=0
for c in "${COLLS[@]}"; do
  skip=0
  for k in "${KEEP[@]}"; do
    if [ "$c" = "$k" ]; then
      skip=1
    fi
  done
  if [ "$skip" -eq 1 ]; then
    continue
  fi
  mongo_eval "db.adminCommand({ renameCollection: '$STAGING.$c', to: '$TARGET.$c', dropTarget: true })" >/dev/null \
    || fail "swap failed for $c"
  SYNCED=$((SYNCED + 1))
done

# 5. The dev admin is the known dev account. The dump carries production's
#    users; `users` is in KEEP so the import never writes them, which makes this
#    the one place a dev user is written. Payload stores a random salt plus a
#    pbkdf2-sha256 (600k rounds, 32 bytes) hash in its `pbkdf2-sha256-v1:` form.
DEV_ENV=${DEV_ENV:-/opt/rossmoney-dev-sync/dev-admin.env}
[ -r "$DEV_ENV" ] || fail "missing $DEV_ENV"
set -a
# shellcheck disable=SC1091
. "$DEV_ENV"
set +a
[ -n "${DEV_ADMIN_EMAIL:-}" ] && [ -n "${DEV_ADMIN_PASSWORD:-}" ] \
  || fail "dev admin email or password is empty in $DEV_ENV"
read -r DEV_SALT DEV_HASH <<<"$(python3 - "$DEV_ADMIN_PASSWORD" <<'PYHASH'
import hashlib, secrets, sys
pw = sys.argv[1].encode()
salt = secrets.token_hex(32)
digest = hashlib.pbkdf2_hmac('sha256', pw, salt.encode(), 600000, 32).hex()
print(salt, 'pbkdf2-sha256-v1:' + digest)
PYHASH
)" || fail "cannot hash the dev admin password"
mongo_eval "const d = db.getSiblingDB('$TARGET'); \
  d.users.deleteMany({}); \
  d.users.insertOne({ email: '$DEV_ADMIN_EMAIL', name: 'Dev', salt: '$DEV_SALT', hash: '$DEV_HASH', loginAttempts: 0, createdAt: new Date(), updatedAt: new Date() });" \
  || fail "cannot set the dev admin"
ADMIN_STATS=$(mongo_eval "const d = db.getSiblingDB('$TARGET'); print(JSON.stringify({ users: d.users.countDocuments({}), admins: d.users.countDocuments({ email: '$DEV_ADMIN_EMAIL' }) }));") \
  || fail "cannot verify $TARGET users"
USERS=$(printf '%s' "$ADMIN_STATS" | jq -er '.users') || fail "unexpected user stats: $ADMIN_STATS"
ADMINS=$(printf '%s' "$ADMIN_STATS" | jq -er '.admins') || fail "unexpected user stats: $ADMIN_STATS"
[ "$USERS" = "1" ] || fail "$TARGET.users must hold exactly the dev admin, found $USERS"
[ "$ADMINS" = "1" ] || fail "dev admin $DEV_ADMIN_EMAIL is missing after the swap"

# 6. Mirror the media files the refreshed collection references.
MEDIA_LIST="$WORK/media-files.json"
mongo_eval "
const m = db.getSiblingDB('$TARGET').getCollection('media').find({}).toArray();
const names = new Set();
for (const d of m) {
  if (d.filename) names.add(d.filename);
  if (d.sizes) {
    for (const k of Object.keys(d.sizes)) {
      const s = d.sizes[k];
      if (s && s.filename) names.add(s.filename);
    }
  }
}
print(JSON.stringify(Array.from(names).sort()));
" > "$MEDIA_LIST" || fail "cannot read the media collection"
jq -e 'type == "array"' "$MEDIA_LIST" >/dev/null || fail "unexpected media list"
MEDIA_COUNT=$(jq 'length' "$MEDIA_LIST")

MEDIA_TMP="$CONF/.media-tmp.$$"
rm -rf "$MEDIA_TMP"
mkdir -p "$MEDIA_TMP"
while IFS= read -r -d '' name; do
  case "$name" in
    ''|*/*|.*)
      fail "unsafe media filename: $name"
      ;;
  esac
  encoded=$(jq -rn --arg f "$name" '$f | @uri')
  curl -fsSL --retry 3 --retry-delay 2 --max-time 120 \
    -o "$MEDIA_TMP/$name" "https://www.rossmoney.me/media/$encoded" \
    || fail "media download failed: $name"
done < <(jq -j '.[] + "\u0000"' "$MEDIA_LIST")

GOT=$(find "$MEDIA_TMP" -maxdepth 1 -type f | wc -l)
[ "$GOT" -eq "$MEDIA_COUNT" ] \
  || fail "downloaded $GOT media files, expected $MEDIA_COUNT"

# Swap the whole directory only after every download has succeeded.
if [ -d "$MEDIA_DIR" ]; then
  rm -rf "$MEDIA_DIR.prev"
  mv "$MEDIA_DIR" "$MEDIA_DIR.prev" || fail "cannot move the previous media directory aside"
fi
mv "$MEDIA_TMP" "$MEDIA_DIR" || fail "cannot install the new media directory"
rm -rf "$MEDIA_DIR.prev"
chmod 755 "$MEDIA_DIR"
find "$MEDIA_DIR" -type f -exec chmod 644 {} +

FILES_JSON='[]'
while IFS= read -r -d '' name; do
  size=$(stat -c%s "$MEDIA_DIR/$name")
  FILES_JSON=$(jq -c --arg n "$name" --argjson b "$size" '. + [{ name: $n, bytes: $b }]' <<<"$FILES_JSON")
done < <(jq -j '.[] + "\u0000"' "$MEDIA_LIST")

MANIFEST_TMP="$CONF/.media-manifest.$$"
jq -n \
  --arg archive "$ARCHIVE_KEY" \
  --arg fetched_at "$(date -Is)" \
  --argjson count "$MEDIA_COUNT" \
  --argjson files "$FILES_JSON" \
  '{ archive: $archive, fetched_at: $fetched_at, count: $count, files: $files }' \
  > "$MANIFEST_TMP" || fail "cannot write the media manifest"
chmod 644 "$MANIFEST_TMP"
mv "$MANIFEST_TMP" "$MEDIA_MANIFEST" || fail "cannot install the media manifest"

# 7. Clean up only the things this run owns, then report one line.
mongo_eval "db.getSiblingDB('$STAGING').dropDatabase()" >/dev/null \
  || fail "cannot drop $STAGING"
rm -rf "$WORK"

echo "$(date -Is) rosso-dev-sync OK collections=${#COLLS[@]} synced=$SYNCED documents=$EXPECTED_DOCS media=$MEDIA_COUNT elapsed=$((SECONDS - START))s archive=$ARCHIVE_KEY"
