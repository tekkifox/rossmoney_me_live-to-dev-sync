#!/bin/bash
# Nightly refresh of the dev databases from the newest production dump.
#
# This is the port of legacy/rosso-dev-sync.sh for the container that replaces
# the root-crontab job. It no longer shells into the database container: it
# talks to each target over TCP through <TARGET>_MONGODB_URI and reads the
# archive locally.
#
# Every target is restored into its own staging database first, checked, then
# swapped in per collection so it is never empty or half-written. users and
# payload-preferences are deliberately left alone: they hold the dev admin the
# tests and screenshots log in with.
#
# Credentials come from the deployment environment and are never printed. A
# failure leaves the downloaded archive in $WORK_DIR and names the failed
# target and step in the log.
set -euo pipefail

ARCHIVE_PREFIX=adb-rossmoney_
KEEP=(users payload-preferences)

SYNC_TARGETS_SET=0
if [ -n "${SYNC_TARGETS:-}" ]; then
  SYNC_TARGETS_SET=1
fi
SYNC_TARGETS=${SYNC_TARGETS:-local atlas}
MEDIA_SOURCE=${MEDIA_SOURCE:-https://www.rossmoney.me/media}
WORK_DIR=${WORK_DIR:-/var/lib/rosso-dev-sync/work}
LOG=${LOG:-/var/log/rosso-dev-sync/sync.log}
LOCK=${LOCK:-/run/rosso-dev-sync.lock}

START=$SECONDS
ARCHIVE_KEY=""
ARCHIVE=""
LIST_BODY=""
MEDIA_TMP=""
MANIFEST_TMP=""
CURRENT_TARGET=""
CURRENT_URI=""
CURRENT_TARGET_DB=""
CURRENT_LEGACY_STAGING=""
TARGET_SEGMENTS=()

fail() {
  if [ -n "$CURRENT_TARGET" ]; then
    echo "FAILED: $CURRENT_TARGET: $*" >&2
  else
    echo "FAILED: $*" >&2
  fi
  exit 1
}

cleanup_staging() {
  local uri=${CURRENT_URI:-}
  local db=${CURRENT_TARGET_DB:-}
  local legacy=${CURRENT_LEGACY_STAGING:-}
  [ -n "$uri" ] && [ -n "$db" ] || return 0

  timeout 20s mongosh "$uri" --quiet --eval "
const d = db.getSiblingDB('$db');
for (const c of d.getCollectionNames()) {
  if (c.startsWith('__staging_')) d.getCollection(c).drop();
}
" >/dev/null 2>&1 || true
  if [ -n "$legacy" ] && [ "$legacy" != "$db" ]; then
    timeout 20s mongosh "$uri" --quiet --eval \
      "db.getSiblingDB('$legacy').dropDatabase()" >/dev/null 2>&1 || true
  fi
}

cleanup() {
  if [ -n "$LIST_BODY" ] && [ -f "$LIST_BODY" ]; then
    rm -f "$LIST_BODY" || true
  fi
  if [ -n "$MEDIA_TMP" ] && [ -d "$MEDIA_TMP" ]; then
    rm -rf "$MEDIA_TMP" || true
  fi
  if [ -n "$MANIFEST_TMP" ] && [ -f "$MANIFEST_TMP" ]; then
    rm -f "$MANIFEST_TMP" || true
  fi
  cleanup_staging
}

trap cleanup EXIT
trap 'fail "unexpected error at line $LINENO"' ERR

[ "$(id -u)" -eq 0 ] || fail "must run as root"

# Keep the log bounded; the previous run is enough history. LOG may be a file
# (the container entrypoint follows it into docker logs) or /dev/stdout.
case "$LOG" in
  -|/dev/stdout|/dev/stderr)
    ;;
  *)
    mkdir -p "$(dirname "$LOG")" || fail "cannot create log directory for $LOG"
    if [ -f "$LOG" ] && [ "$(stat -c%s "$LOG")" -gt 2000000 ]; then
      mv -f "$LOG" "$LOG.1" || fail "cannot rotate $LOG"
    fi
    exec >>"$LOG" 2>&1
    ;;
esac

exec 9>"$LOCK" || fail "cannot open lock $LOCK"
if ! flock -n 9; then
  echo "SKIPPED: another run holds $LOCK"
  exit 0
fi

for name in S3_ENDPOINT S3_BUCKET AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY \
  DEV_ADMIN_EMAIL DEV_ADMIN_PASSWORD; do
  [ -n "${!name:-}" ] || fail "missing $name"
done

case "$WORK_DIR" in
  /?*) ;;
  *) fail "WORK_DIR must be an absolute path below /" ;;
esac
case "$WORK_DIR" in
  */) fail "WORK_DIR must not end with a slash" ;;
  *..*) fail "WORK_DIR must not contain .." ;;
esac
S3_ENDPOINT=${S3_ENDPOINT%/}
case "$S3_ENDPOINT" in
  http://*|https://*) ;;
  *) fail "S3_ENDPOINT must be an http(s) URL" ;;
esac
MEDIA_SOURCE=${MEDIA_SOURCE%/}
case "$MEDIA_SOURCE" in
  http://*|https://*) ;;
  *) fail "MEDIA_SOURCE must be an http(s) URL" ;;
esac

# Resolve SYNC_TARGETS into parallel arrays before anything is downloaded. A
# target is named by its environment prefix: local -> LOCAL_*,
# atlas -> ATLAS_*.
TARGETS_EXPLICIT=0
if [ "$SYNC_TARGETS_SET" -eq 1 ]; then
  TARGETS_EXPLICIT=1
fi
read -r -a TARGET_NAMES <<<"$SYNC_TARGETS"
[ "${#TARGET_NAMES[@]}" -gt 0 ] || fail "SYNC_TARGETS is empty"

ACTIVE_NAMES=()
ACTIVE_URIS=()
ACTIVE_DBS=()
ACTIVE_LEGACY_STAGINGS=()
ACTIVE_MEDIA_DIRS=()
ACTIVE_CMS_URLS=()
declare -A SEEN_TARGET=()

for name in "${TARGET_NAMES[@]}"; do
  name=${name,,}
  [[ $name =~ ^[A-Za-z][A-Za-z0-9_]*$ ]] || fail "unsafe target name: $name"
  [ -z "${SEEN_TARGET[$name]:-}" ] || fail "duplicate target: $name"
  SEEN_TARGET[$name]=1
  CURRENT_TARGET=$name

  prefix=${name^^}
  uri_var="${prefix}_MONGODB_URI"
  uri="${!uri_var:-}"
  if [ -z "$uri" ]; then
    if [ "$TARGETS_EXPLICIT" -eq 0 ] && [ "$name" = atlas ]; then
      echo "SKIPPED target atlas: $uri_var is not set"
      CURRENT_TARGET=""
      continue
    fi
    fail "missing $uri_var"
  fi
  case "$uri" in
    mongodb://*|mongodb+srv://*) ;;
    *) fail "$uri_var must start with mongodb:// or mongodb+srv://" ;;
  esac

  target_var="${prefix}_TARGET_DB"
  target_db="${!target_var:-}"
  legacy_staging_var="${prefix}_STAGING_DB"
  legacy_staging_db="${!legacy_staging_var:-}"
  media_var="${prefix}_MEDIA_DIR"
  media_dir=""
  if [ -v "$media_var" ]; then
    media_dir="${!media_var}"
  elif [ "$name" = local ]; then
    media_dir=/media
  fi
  cms_var="${prefix}_CMS_URL"
  cms_url=""
  if [ -n "${!cms_var:-}" ]; then
    cms_url="${!cms_var%/}"
    case "$cms_url" in
      http://*|https://*) ;;
      *) fail "$cms_var must be an http(s) URL" ;;
    esac
  fi

  if [ "$name" = local ]; then
    target_db=${target_db:-rossmoney_dev}
    legacy_staging_db=${legacy_staging_db:-rossmoney_dev_staging}
  fi
  [ -n "$target_db" ] || fail "missing $target_var"
  case "$target_db" in
    ''|*[!A-Za-z0-9_-]*|admin|local|config)
      fail "unsafe database name: $target_db"
      ;;
  esac
  if [ -n "$legacy_staging_db" ] && [ "$legacy_staging_db" != "$target_db" ]; then
    case "$legacy_staging_db" in
      ''|*[!A-Za-z0-9_-]*|admin|local|config)
        fail "unsafe legacy staging database name: $legacy_staging_db"
        ;;
    esac
  elif [ "$legacy_staging_db" = "$target_db" ]; then
    legacy_staging_db=""
  fi
  if [ -n "$media_dir" ]; then
    case "$media_dir" in
      /?*) ;;
      *) fail "MEDIA_DIR must be an absolute path below /" ;;
    esac
    case "$media_dir" in
      */) fail "MEDIA_DIR must not end with a slash" ;;
      *..*) fail "MEDIA_DIR must not contain .." ;;
    esac
  fi

  ACTIVE_NAMES+=("$name")
  ACTIVE_URIS+=("$uri")
  ACTIVE_DBS+=("$target_db")
  ACTIVE_LEGACY_STAGINGS+=("$legacy_staging_db")
  ACTIVE_MEDIA_DIRS+=("$media_dir")
  ACTIVE_CMS_URLS+=("$cms_url")
  CURRENT_TARGET=""
done

[ "${#ACTIVE_NAMES[@]}" -gt 0 ] || fail "no sync targets configured"

for cmd in curl tar gzip jq flock mountpoint mongosh mongoimport openssl od stat find sort mktemp head timeout; do
  command -v "$cmd" >/dev/null 2>&1 || fail "missing command: $cmd"
done

mongo_eval() {
  local uri=$1
  local eval_s=$2
  mongosh "$uri" --quiet --eval "$eval_s"
}

mongo_import() {
  local uri=$1
  local db=$2
  local coll=$3
  local file=$4
  mongoimport --uri "$uri" --db "$db" --collection "$coll" --file "$file" --jsonArray --quiet
}

# WORK_DIR is a named volume in the stack, so it is a mount point; clear its
# contents instead of removing the directory.
clear_work_dir() {
  [ -d "$WORK_DIR" ] || return 0
  while IFS= read -r -d '' entry; do
    rm -rf "$entry" || fail "cannot remove $entry from $WORK_DIR"
  done < <(find "$WORK_DIR" -mindepth 1 -maxdepth 1 -print0)
}

# Keep the secret out of curl's argv. A config on stdin carries the user:pass.
s3_curl() {
  local ak=${AWS_ACCESS_KEY_ID//\\/\\\\}
  local sk=${AWS_SECRET_ACCESS_KEY//\\/\\\\}
  ak=${ak//\"/\\\"}
  sk=${sk//\"/\\\"}
  printf 'user = "%s:%s"\n' "$ak" "$sk" |
    curl -sS -K - --aws-sigv4 "aws:amz:us-east-1:s3" "$@"
}

# 1. Find the newest dump.
LIST_BODY=$(mktemp) || fail "cannot create a temporary file for the S3 listing"
LIST_CODE=$(s3_curl --max-time 60 -o "$LIST_BODY" -w '%{http_code}' \
  "$S3_ENDPOINT/$S3_BUCKET?list-type=2&prefix=$ARCHIVE_PREFIX") || {
  rm -f "$LIST_BODY"
  LIST_BODY=""
  fail "cannot list s3://$S3_BUCKET (request failed)"
}
if [ "$LIST_CODE" -lt 200 ] || [ "$LIST_CODE" -ge 300 ]; then
  FIRST_LINE=$(head -n 1 "$LIST_BODY" 2>/dev/null | tr -d '\r' || true)
  [ -n "$FIRST_LINE" ] || FIRST_LINE="(empty body)"
  rm -f "$LIST_BODY"
  LIST_BODY=""
  fail "cannot list s3://$S3_BUCKET (HTTP $LIST_CODE: $FIRST_LINE)"
fi
LIST_XML=$(cat "$LIST_BODY")
rm -f "$LIST_BODY"
LIST_BODY=""
ARCHIVE_KEY=$(printf '%s\n' "$LIST_XML" \
  | grep -o '<Key>[^<]*</Key>' \
  | sed -E 's#</?Key>##g' \
  | grep -E "^${ARCHIVE_PREFIX}[0-9]{8}_[0-9]{6}\.tar\.gz$" \
  | sort \
  | tail -n 1 || true)
[ -n "$ARCHIVE_KEY" ] || fail "no ${ARCHIVE_PREFIX}*.tar.gz archive in s3://$S3_BUCKET"

# 2. Download and extract it once for every target.
mkdir -p "$WORK_DIR" || fail "cannot create $WORK_DIR"
chmod 700 "$WORK_DIR"
clear_work_dir
mkdir -p "$WORK_DIR/dump"
ARCHIVE="$WORK_DIR/$ARCHIVE_KEY"
DL_CODE=$(s3_curl --max-time 300 -o "$ARCHIVE" -w '%{http_code}' \
  "$S3_ENDPOINT/$S3_BUCKET/$ARCHIVE_KEY") || {
  rm -f "$ARCHIVE"
  fail "download failed for $ARCHIVE_KEY (request failed)"
}
if [ "$DL_CODE" -lt 200 ] || [ "$DL_CODE" -ge 300 ]; then
  FIRST_LINE=$(head -n 1 "$ARCHIVE" 2>/dev/null | tr -d '\r' || true)
  [ -n "$FIRST_LINE" ] || FIRST_LINE="(empty body)"
  rm -f "$ARCHIVE"
  fail "download failed for $ARCHIVE_KEY (HTTP $DL_CODE: $FIRST_LINE)"
fi
chmod 600 "$ARCHIVE"

tar -xzf "$ARCHIVE" -C "$WORK_DIR/dump" || fail "cannot extract $ARCHIVE_KEY"
mapfile -t FILES < <(find "$WORK_DIR/dump" -maxdepth 1 -type f -name '*.json' -printf '%f\n' | sort)
[ "${#FILES[@]}" -gt 0 ] || fail "archive $ARCHIVE_KEY contains no collection JSON files"

COLLS=()
declare -A EXPECTED_COUNT=()
EXPECTED_DOCS=0
for f in "${FILES[@]}"; do
  c=${f%.json}
  [[ $c =~ ^[A-Za-z0-9._-]+$ ]] || fail "unsafe collection name in archive: $c"
  case "$c" in
    system.*) fail "unsafe collection name in archive: $c" ;;
    __staging_*) fail "reserved collection name in archive: $c" ;;
  esac
  n=$(jq -e 'if type == "array" then length else error("not an array") end' "$WORK_DIR/dump/$f") \
    || fail "invalid EJSON in $f"
  COLLS+=("$c")
  EXPECTED_COUNT[$c]=$n
  EXPECTED_DOCS=$((EXPECTED_DOCS + n))
done
[ "$EXPECTED_DOCS" -gt 0 ] || fail "archive $ARCHIVE_KEY contains zero documents"

# The dev admin password is the same for every target. Payload stores a random
# salt plus a pbkdf2-sha256 (600k rounds, 32 bytes) hash in its
# `pbkdf2-sha256-v1:` form.
DEV_SALT=$(openssl rand -hex 32) || fail "cannot generate the dev admin salt"
PASS_HEX=$(printf '%s' "$DEV_ADMIN_PASSWORD" | od -An -v -tx1 | tr -d ' \n') \
  || fail "cannot encode the dev admin password"
SALT_HEX=$(printf '%s' "$DEV_SALT" | od -An -v -tx1 | tr -d ' \n') \
  || fail "cannot encode the dev admin salt"
DEV_HASH=$(openssl kdf -keylen 32 -kdfopt digest:SHA256 \
  -kdfopt "hexpass:$PASS_HEX" -kdfopt "hexsalt:$SALT_HEX" -kdfopt iter:600000 PBKDF2 \
  | tr -d ':\n' | tr 'A-F' 'a-f') || fail "cannot hash the dev admin password"
[ "${#DEV_HASH}" -eq 64 ] || fail "unexpected dev admin hash length"
case "$DEV_HASH" in
  *[!0-9a-f]*) fail "unexpected dev admin hash" ;;
esac
DEV_EMAIL_JSON=$(printf '%s' "$DEV_ADMIN_EMAIL" | jq -Rs .) \
  || fail "cannot encode the dev admin email"

# Replace the contents of a media directory that is a mount point. A mount
# point cannot be renamed, so move the old entries aside and move the fully
# downloaded set into place; restore the old set if the install fails.
install_media_in_place() {
  local media_dir=$1
  local tmp=$2
  local prev="$media_dir/.sync-prev.$$"
  local tmp_name=${tmp##*/}
  local prev_name=${prev##*/}
  local entry

  rm -rf "$prev"
  mkdir "$prev" || fail "cannot create $prev"
  while IFS= read -r -d '' entry; do
    mv "$entry" "$prev/" || fail "cannot move the previous media files aside"
  done < <(find "$media_dir" -mindepth 1 -maxdepth 1 \
    ! -name "$tmp_name" ! -name "$prev_name" -print0)

  while IFS= read -r -d '' entry; do
    if ! mv "$entry" "$media_dir/"; then
      while IFS= read -r -d '' entry; do
        mv "$entry" "$media_dir/" || true
      done < <(find "$prev" -mindepth 1 -maxdepth 1 -print0)
      fail "cannot install the new media files"
    fi
  done < <(find "$tmp" -mindepth 1 -maxdepth 1 -print0)

  rm -rf "$prev" "$tmp"
}

# Mirror the media files the refreshed media collection references. The live
# directory is replaced only after every download has succeeded.
mirror_media() {
  local uri=$1
  local target_db=$2
  local media_dir=$3
  local name=$4
  local media_list="$WORK_DIR/media-files-$name.json"
  local manifest="${media_dir}.manifest.json"

  mongo_eval "$uri" "
const m = db.getSiblingDB('$target_db').getCollection('media').find({}).toArray();
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
" > "$media_list" || fail "cannot read the media collection"
  jq -e 'type == "array"' "$media_list" >/dev/null || fail "unexpected media list"
  MEDIA_COUNT=$(jq 'length' "$media_list")

  MEDIA_TMP="${media_dir}.tmp.$$"
  if mountpoint -q "$media_dir"; then
    MEDIA_TMP="$media_dir/.sync-tmp.$$"
  fi
  rm -rf "$MEDIA_TMP"
  mkdir -p "$MEDIA_TMP" || fail "cannot create $MEDIA_TMP"
  while IFS= read -r -d '' file; do
    case "$file" in
      ''|*/*|.*)
        fail "unsafe media filename: $file"
        ;;
    esac
    encoded=$(jq -rn --arg f "$file" '$f | @uri')
    curl -fsSL --retry 3 --retry-delay 2 --max-time 120 \
      -o "$MEDIA_TMP/$file" "$MEDIA_SOURCE/$encoded" \
      || fail "media download failed: $file"
  done < <(jq -j '.[] + "\u0000"' "$media_list")

  GOT=$(find "$MEDIA_TMP" -maxdepth 1 -type f | wc -l)
  [ "$GOT" -eq "$MEDIA_COUNT" ] \
    || fail "downloaded $GOT media files, expected $MEDIA_COUNT"

  # Swap the whole directory only after every download has succeeded. A mount
  # point (the usual case for the /media volume) is replaced in place instead.
  if mountpoint -q "$media_dir"; then
    install_media_in_place "$media_dir" "$MEDIA_TMP"
  else
    if [ -d "$media_dir" ]; then
      rm -rf "$media_dir.prev"
      mv "$media_dir" "$media_dir.prev" || fail "cannot move the previous media directory aside"
    fi
    if ! mv "$MEDIA_TMP" "$media_dir"; then
      if [ -d "$media_dir.prev" ]; then
        mv "$media_dir.prev" "$media_dir" || true
      fi
      fail "cannot install the new media directory"
    fi
    rm -rf "$media_dir.prev"
  fi
  MEDIA_TMP=""
  chmod 755 "$media_dir"
  find "$media_dir" -type f -exec chmod 644 {} +

  FILES_JSON='[]'
  while IFS= read -r -d '' file; do
    size=$(stat -c%s "$media_dir/$file")
    FILES_JSON=$(jq -c --arg n "$file" --argjson b "$size" '. + [{ name: $n, bytes: $b }]' <<<"$FILES_JSON")
  done < <(jq -j '.[] + "\u0000"' "$media_list")

  mkdir -p "$(dirname "$manifest")" || fail "cannot create media manifest directory"
  MANIFEST_TMP="${manifest}.tmp.$$"
  jq -n \
    --arg archive "$ARCHIVE_KEY" \
    --arg fetched_at "$(date -Is)" \
    --argjson count "$MEDIA_COUNT" \
    --argjson files "$FILES_JSON" \
    '{ archive: $archive, fetched_at: $fetched_at, count: $count, files: $files }' \
    > "$MANIFEST_TMP" || fail "cannot write the media manifest"
  chmod 644 "$MANIFEST_TMP"
  mv "$MANIFEST_TMP" "$manifest" || fail "cannot install the media manifest"
  MANIFEST_TMP=""
}

# Cosmetic follow-up for a target that names a site: materialise the media rows
# that were just imported as Vercel Blob objects. Login and route failures are
# warnings only; the database swap has already succeeded.
run_media_backfill() {
  local name=$1
  local cms_url=$2
  [ -n "$cms_url" ] || return 0

  local login_json
  local login_code
  local token
  local code
  local uploaded
  local skipped
  local failed
  local login_file="$WORK_DIR/media-backfill-$name-login.json"
  local response_file="$WORK_DIR/media-backfill-$name-response.json"

  login_json=$(jq -nc --arg email "$DEV_ADMIN_EMAIL" --arg password "$DEV_ADMIN_PASSWORD" \
    '{email: $email, password: $password}') \
    || { echo "WARNING: media-backfill $name: cannot encode credentials" >&2; return 0; }

  login_code=$(printf '%s' "$login_json" | \
    curl -sS --max-time 30 -o "$login_file" -w '%{http_code}' \
      -X POST -H 'Content-Type: application/json' --data @- \
      "$cms_url/api/users/login" 2>/dev/null) \
    || { echo "WARNING: media-backfill $name: login request failed" >&2; return 0; }
  if [ "$login_code" != 200 ]; then
    echo "WARNING: media-backfill $name: login returned HTTP $login_code" >&2
    return 0
  fi
  token=$(jq -er '.token' "$login_file" 2>/dev/null) \
    || { echo "WARNING: media-backfill $name: login returned no token" >&2; return 0; }

  code=$(curl -sS --max-time 120 -o "$response_file" -w '%{http_code}' \
    -X POST -H "Authorization: JWT $token" "$cms_url/api/media/backfill" 2>/dev/null) \
    || { echo "WARNING: media-backfill $name: backfill request failed" >&2; return 0; }
  if [ "$code" != 200 ]; then
    echo "WARNING: media-backfill $name: backfill returned HTTP $code" >&2
    return 0
  fi
  uploaded=$(jq -er '.uploaded' "$response_file" 2>/dev/null) \
    || { echo "WARNING: media-backfill $name: unexpected response" >&2; return 0; }
  skipped=$(jq -er '.skipped' "$response_file" 2>/dev/null) \
    || { echo "WARNING: media-backfill $name: unexpected response" >&2; return 0; }
  failed=$(jq -er '.failed' "$response_file" 2>/dev/null) \
    || { echo "WARNING: media-backfill $name: unexpected response" >&2; return 0; }
  echo "media-backfill uploaded=$uploaded skipped=$skipped failed=$failed target=$name"
}

process_target() {
  local name=$1
  local uri=$2
  local target_db=$3
  local legacy_staging_db=$4
  local media_dir=$5
  local cms_url=$6

  CURRENT_TARGET=$name
  CURRENT_URI=$uri
  CURRENT_TARGET_DB=$target_db
  CURRENT_LEGACY_STAGING=$legacy_staging_db

  # 3. Clean up leftovers from an earlier failed run, then stage every
  #    collection inside the target database under __staging_<collection>.
  if [ -n "$legacy_staging_db" ]; then
    mongo_eval "$uri" "db.getSiblingDB('$legacy_staging_db').dropDatabase()" >/dev/null \
      || fail "cannot drop legacy staging database $legacy_staging_db"
  fi
  mongo_eval "$uri" "
const d = db.getSiblingDB('$target_db');
for (const c of d.getCollectionNames()) {
  if (c.startsWith('__staging_')) d.getCollection(c).drop();
}
" >/dev/null || fail "cannot drop leftover staging collections in $target_db"

  for c in "${COLLS[@]}"; do
    mongo_eval "$uri" "db.getSiblingDB('$target_db').createCollection('__staging_$c')" >/dev/null \
      || fail "cannot create staging collection __staging_$c in $target_db"
  done

  for c in "${COLLS[@]}"; do
    if [ "${EXPECTED_COUNT[$c]}" -gt 0 ]; then
      mongo_import "$uri" "$target_db" "__staging_$c" "$WORK_DIR/dump/$c.json" \
        || fail "staging import into $target_db failed for $c"
    fi
  done

  STATS=$(mongo_eval "$uri" "
const d = db.getSiblingDB('$target_db');
const names = d.getCollectionNames().filter(c => c.startsWith('__staging_'));
const counts = {};
let total = 0;
for (const c of names) {
  counts[c] = d.getCollection(c).countDocuments({});
  total += counts[c];
}
print(JSON.stringify({ collections: names.length, documents: total, counts: counts }));
") || fail "cannot verify staging collections in $target_db"
  STAGE_COLLECTIONS=$(printf '%s' "$STATS" | jq -er '.collections') \
    || fail "unexpected staging stats in $target_db: $STATS"
  STAGE_DOCS=$(printf '%s' "$STATS" | jq -er '.documents') \
    || fail "unexpected staging stats in $target_db: $STATS"
  [ "$STAGE_COLLECTIONS" -eq "${#COLLS[@]}" ] \
    || fail "staging in $target_db has $STAGE_COLLECTIONS collections, expected ${#COLLS[@]}"
  [ "$STAGE_DOCS" -eq "$EXPECTED_DOCS" ] \
    || fail "staging in $target_db has $STAGE_DOCS documents, expected $EXPECTED_DOCS"
  for c in "${COLLS[@]}"; do
    STAGE_COUNT=$(printf '%s' "$STATS" | jq -er --arg c "__staging_$c" '.counts[$c]') \
      || fail "staging collection __staging_$c is missing from $target_db"
    [ "$STAGE_COUNT" -eq "${EXPECTED_COUNT[$c]}" ] \
      || fail "staging collection __staging_$c in $target_db has $STAGE_COUNT documents, expected ${EXPECTED_COUNT[$c]}"
  done

  # 4. Swap in per collection; users and payload-preferences stay as they are.
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
    mongo_eval "$uri" "db.adminCommand({ renameCollection: '$target_db.__staging_$c', to: '$target_db.$c', dropTarget: true })" >/dev/null \
      || fail "renameCollection within $target_db failed for $c"
  done

  # 5. The dev admin is the known dev account. Only this one user is written;
  #    everyone else, including the account the screenshot service signs in
  #    with, is left untouched.
  ADMIN_RESULT=$(mongo_eval "$uri" "
const d = db.getSiblingDB('$target_db');
const email = $DEV_EMAIL_JSON;
const r = d.users.updateOne(
  { email: email },
  {
    \$set: { salt: '$DEV_SALT', hash: '$DEV_HASH', updatedAt: new Date() },
    \$setOnInsert: { name: 'Dev', loginAttempts: 0, createdAt: new Date() }
  },
  { upsert: true }
);
print(JSON.stringify({
  matched: r.matchedCount,
  modified: r.modifiedCount,
  upserted: r.upsertedCount,
  admins: d.users.countDocuments({ email: email })
}));
") || fail "cannot set the dev admin"
  ADMINS=$(printf '%s' "$ADMIN_RESULT" | jq -er '.admins') \
    || fail "unexpected dev admin stats: $ADMIN_RESULT"
  [ "$ADMINS" -eq 1 ] || fail "dev admin $DEV_ADMIN_EMAIL is missing after the swap"

  # 6. Cosmetic: ask the site to materialise the imported media rows as blob
  #    objects. A warning here does not fail the refresh.
  run_media_backfill "$name" "$cms_url"

  # 7. Mirror media only for a target that names a media directory.
  MEDIA_COUNT=""
  if [ -n "$media_dir" ]; then
    mirror_media "$uri" "$target_db" "$media_dir" "$name"
  fi

  # 8. Drop the staging collections, including the keep-list copies.
  mongo_eval "$uri" "
const d = db.getSiblingDB('$target_db');
for (const c of d.getCollectionNames()) {
  if (c.startsWith('__staging_')) d.getCollection(c).drop();
}
" >/dev/null || fail "cannot drop staging collections in $target_db"

  local segment="$name collections=${#COLLS[@]} documents=$EXPECTED_DOCS"
  if [ -n "$media_dir" ]; then
    segment="$segment media=$MEDIA_COUNT"
  fi
  TARGET_SEGMENTS+=("$segment")
  CURRENT_TARGET=""
  CURRENT_URI=""
  CURRENT_TARGET_DB=""
  CURRENT_LEGACY_STAGING=""
}

for i in "${!ACTIVE_NAMES[@]}"; do
  process_target "${ACTIVE_NAMES[$i]}" "${ACTIVE_URIS[$i]}" "${ACTIVE_DBS[$i]}" \
    "${ACTIVE_LEGACY_STAGINGS[$i]}" "${ACTIVE_MEDIA_DIRS[$i]}" "${ACTIVE_CMS_URLS[$i]}"
done

# 9. Clear the shared work volume and report one line naming every target.
clear_work_dir

LINE="OK"
for segment in "${TARGET_SEGMENTS[@]}"; do
  if [ "$LINE" = "OK" ]; then
    LINE="$LINE $segment"
  else
    LINE="$LINE | $segment"
  fi
done
echo "$LINE elapsed=$((SECONDS - START))s archive=$ARCHIVE_KEY"
