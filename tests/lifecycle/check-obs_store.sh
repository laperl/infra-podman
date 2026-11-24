#!/usr/bin/env bash
# What the operator would check by hand on the observability store (SPEC 4.8, R62), on the
# runner as in DEV. Usage: check-obs_store.sh <step>
#   running      both containers up, hardened, on 127.0.0.1 only, with the retention of the
#                inventory and their data in the folder of the store
#   write        one metric and one log line go in and can be read back
#   kept         the metric and the log line of "write" are still there (after a restart)
#   destroyed    container units gone, data folder kept (SPEC 4.2)
set -Eeuo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
as=$here/as-svc.sh
metrics=dev-obs-metrics
logs=dev-obs-logs
home=$(getent passwd svc_runner | cut -d: -f6)
dir=$home/.local/share/infra-podman/dev-obs
vm=http://127.0.0.1:18010
vl=http://127.0.0.1:18011
# fd 3 is the real stdout: a failure inside a command whose output is discarded must
# still reach the annotations.
exec 3>&1
fail() { echo "::error title=check-obs_store::$*" >&3; exit 1; }
errlog=$(mktemp)
exec 2> >(tee "$errlog" >&2)
trap 'fail "line $LINENO: $BASH_COMMAND: $(tail -5 "$errlog" | tr "\n" " ")"' ERR

# Retries a read for up to 30 s: both bases make new data searchable after a short delay.
eventually() {
  local _
  for _ in $(seq 30); do
    if "$@"; then return 0; fi
    sleep 1
  done
  return 1
}
has_metric() { curl -fsS "$vm/api/v1/query?query=ci_obs_metric" | grep -q '"42"'; }
has_log() { curl -fsS "$vl/select/logsql/query" --data-urlencode 'query=ci_obs_line' | grep -q 'ci_obs_line'; }

case ${1:?step} in
  running)
    for c in $metrics $logs; do
      [[ $("$as" systemctl --user is-active "$c.service") == active ]] || fail "$c is not active"
      [[ $("$as" podman inspect -f '{{.HostConfig.ReadonlyRootfs}}' "$c") == true ]] || fail "$c: root file system not read-only"
      [[ $("$as" podman inspect -f '{{.HostConfig.CapDrop}}' "$c") == *CAP_* ]] || fail "$c: capabilities not dropped"
    done
    [[ $("$as" podman inspect -f '{{json .Config.Cmd}}' $metrics) == *'-retentionPeriod=1y'* ]] || fail "metrics retention is not 1y"
    [[ $("$as" podman inspect -f '{{json .Config.Cmd}}' $logs) == *'-retentionPeriod=90d'* ]] || fail "logs retention is not 90d"
    # Each listens only where the inventory says: 127.0.0.1, never every interface.
    listening=$(ss -ltnH '( sport = :18010 or sport = :18011 )' | awk '{print $4}' | sort -u | tr '\n' ' ')
    [[ $listening == '127.0.0.1:18010 127.0.0.1:18011 ' ]] || fail "listening on: $listening"
    # No way out: both containers are only on their own internal network.
    for c in $metrics $logs; do
      # shellcheck disable=SC2016  # a Go template, not a shell expansion
      net=$("$as" podman inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$c")
      [[ $net == "$c-net " ]] || fail "$c is on: $net"
      [[ $("$as" podman network inspect -f '{{.Internal}}' "$c-net") == true ]] || fail "$c-net is not internal"
    done
    # Their data is the folder of the store, owned by the service user.
    sudo test -d "$dir/metrics/data" || fail "no VictoriaMetrics data in $dir/metrics"
    [[ $(sudo stat -c %U "$dir/logs") == svc_runner ]] || fail "$dir/logs is not owned by svc_runner"
    echo "ok: running, hardened, only on 127.0.0.1, retention 1y and 90d, data in $dir"
    ;;
  write)
    curl -fsS --data-binary 'ci_obs_metric{job="ci"} 42' "$vm/api/v1/import/prometheus"
    curl -fsS -X POST "$vl/insert/jsonline?_stream_fields=app" --data-binary '{"_msg":"ci_obs_line from lifecycle","app":"ci"}'
    eventually has_metric || fail "the metric written is not readable"
    eventually has_log || fail "the log line written is not readable"
    echo "ok: one metric and one log line in and out"
    ;;
  kept)
    eventually has_metric || fail "the metric is gone"
    eventually has_log || fail "the log line is gone"
    echo "ok: the data survived"
    ;;
  destroyed)
    for c in $metrics $logs; do
      if "$as" test -e "$home/.config/containers/systemd/$c.container"; then fail "$c.container is still there"; fi
      if "$as" podman container exists "$c"; then fail "$c still exists"; fi
    done
    sudo test -d "$dir/metrics/data" || fail "the metrics data is gone"
    sudo test -d "$dir/logs" || fail "the logs data is gone"
    echo "ok: containers gone, data kept in $dir"
    ;;
  *) fail "unknown step $1" ;;
esac
