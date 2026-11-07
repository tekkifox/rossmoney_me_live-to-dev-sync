#!/bin/bash
# Container entrypoint. Keeps the legacy log-file discipline (sync.sh writes a
# bounded log) while following that log into the container's stdout, so
# `docker logs` shows every cron run. RUN_ONCE=1 or the `run-once` command
# bypasses cron and runs the job directly on stdout.
set -euo pipefail

if [ "${1:-}" = "run-once" ]; then
  RUN_ONCE=1
fi

if [ "${RUN_ONCE:-0}" = "1" ]; then
  export LOG="${LOG:-/dev/stdout}"
  exec /usr/local/bin/sync.sh
fi

# cron does not pass the container environment to jobs. Serialise it once, with
# shell quoting, into a root-only file the crontab sources.
ENV_FILE=/run/rosso-dev-sync.env
umask 077
: > "$ENV_FILE"
while IFS= read -r name; do
  case "$name" in
    _|PWD|OLDPWD|SHLVL)
      continue
      ;;
    [!A-Za-z_]*|*[!A-Za-z0-9_]*)
      continue
      ;;
  esac
  printf 'export %s=%q\n' "$name" "${!name}" >> "$ENV_FILE"
done < <(compgen -e)
chmod 600 "$ENV_FILE"

LOG="${LOG:-/var/log/rosso-dev-sync/sync.log}"
case "$LOG" in
  -|/dev/stdout|/dev/stderr)
    ;;
  *)
    mkdir -p "$(dirname "$LOG")" || { echo "cannot create log directory for $LOG" >&2; exit 1; }
    touch "$LOG" || { echo "cannot create $LOG" >&2; exit 1; }
    tail -n 0 -F "$LOG" &
    ;;
esac

exec "$@"
