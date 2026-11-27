#!/usr/bin/env bash
# What the operator would check by hand on the observability agents (SPEC 4.8, R62), on the
# runner, which is also the machine of the store. Usage: check-obs_agent.sh <step>
#   running   node_exporter, vmagent, the GPU timer and systemd-journal-upload on, the first two
#             only on 127.0.0.1
#   arrived   the metrics of the machine and of the GPU, and its logs (system and containers),
#             are in the store
#   offline   with the store stopped for a minute, what happened meanwhile arrives afterwards,
#             without gaps
set -Eeuo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
as=$here/as-svc.sh
agent=dev-obs-agent
vm=http://127.0.0.1:17010
vl=http://127.0.0.1:17011
exec 3>&1
fail() { echo "::error title=check-obs_agent::$*" >&3; exit 1; }
errlog=$(mktemp)
exec 2> >(tee "$errlog" >&2)
trap 'fail "line $LINENO: $BASH_COMMAND: $(tail -5 "$errlog" | tr "\n" " ")"' ERR

# Retries for up to $1 seconds: data takes a scrape, a send, and VictoriaMetrics' 30 s.
within() {
  local secs=$1 _
  shift
  for _ in $(seq "$secs"); do
    if "$@"; then return 0; fi
    sleep 1
  done
  return 1
}
# metric <query>: true when the query returns at least one series.
metric() { curl -fsS "$vm/api/v1/query" --data-urlencode "query=$1" --data-urlencode nocache=1 | grep -q '"value"'; }
# logs <LogsQL query>: true when it finds at least one line.
logs() { [[ -n $(curl -fsS "$vl/select/logsql/query" --data-urlencode "query=$1" --data-urlencode limit=1) ]]; }

case ${1:?step} in
  running)
    for u in prometheus-node-exporter.service systemd-journal-upload.service infra-podman-obs-gpu.timer; do
      [[ $(systemctl is-active "$u") == active ]] || fail "$u is not active"
    done
    [[ $("$as" systemctl --user is-active "$agent.service") == active ]] || fail "$agent is not active"
    listening=$(ss -ltnH '( sport = :9100 or sport = :8429 )' | awk '{print $4}' | sort -u | tr '\n' ' ')
    [[ $listening == '127.0.0.1:8429 127.0.0.1:9100 ' ]] || fail "listening on: $listening"
    curl -fsS http://127.0.0.1:9100/metrics | grep -q '^obs_gpu_temperature_celsius{gpu="0"} 36$' \
      || fail "node_exporter does not show the GPU"
    echo "ok: the four agents on, node_exporter and vmagent only on 127.0.0.1, GPU read"
    ;;
  arrived)
    within 120 metric 'node_load1{machine="ci",job="node"}' || fail "no system metrics in the store"
    within 60 metric 'obs_gpu_temperature_celsius{machine="ci"} == 36' || fail "no GPU metrics in the store"
    within 60 metric 'up{machine="ci",job="victorialogs"} == 1' || fail "the store's own metrics are not read"
    logger -t ci-obs-agent ci_obs_agent_line
    within 60 logs 'ci_obs_agent_line' || fail "a system log line did not arrive"
    # The logs of the containers of svc_runner, each in its own stream (-journald.streamFields).
    within 60 logs "_SYSTEMD_USER_UNIT:\"$agent.service\"" || fail "the container logs did not arrive by their unit"
    echo "ok: system, GPU and store metrics, and system and container logs, in the store"
    ;;
  offline)
    "$as" systemctl --user stop dev-obs-metrics.service dev-obs-logs.service
    from=$(date +%s)
    logger -t ci-obs-agent ci_obs_offline_line
    sleep 60
    to=$(date +%s)
    "$as" systemctl --user start dev-obs-metrics.service dev-obs-logs.service
    within 180 logs 'ci_obs_offline_line' || fail "the log written while the store was down never arrived"
    # Every 10 s for a minute: about 6 samples. Without the queue there would be none.
    samples() {
      curl -fsS "$vm/api/v1/query" --data-urlencode "query=count_over_time(node_load1{machine=\"ci\"}[$((to - from))s])" \
        --data-urlencode "time=$to" --data-urlencode nocache=1 \
        | grep -Eo '"[0-9]+"\]' | tr -dc '0-9'
    }
    enough() { local n; n=$(samples); [[ ${n:-0} -ge 4 ]]; }
    within 180 enough || fail "the metrics of the minute offline did not arrive: $(samples) samples"
    [[ $(systemctl is-active systemd-journal-upload.service) == active ]] || fail "systemd-journal-upload did not come back"
    echo "ok: a minute without store, then its logs and $(samples) metric samples arrived"
    ;;
  *) fail "unknown step $1" ;;
esac
