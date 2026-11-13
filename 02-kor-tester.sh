#!/usr/bin/env bash
# Kör testerna mot Argo CD-appen "demo" och loggar utfallet till resultat/resultat.csv.
#
# Serie A: fem manuella ändringar, RUNS körningar per ändring. Application-objektet
#          återskapas före varje körning så att varje körning startar från samma läge.
# Serie B: ändring T1 upprepas REPEATS gånger i rad utan att Application återskapas.
#
#   ./02-kor-tester.sh                 # standard: 10 körningar per test
#   RUNS=5 ./02-kor-tester.sh          # snabbare genomkörning
set -uo pipefail

RUNS="${RUNS:-10}"            # körningar per test i serie A
REPEATS="${REPEATS:-6}"       # upprepningar i serie B
TIMEOUT_A="${TIMEOUT_A:-200}" # sekunder att vänta på återställning, serie A
TIMEOUT_B="${TIMEOUT_B:-400}" # sekunder att vänta på återställning, serie B
POLL="${POLL:-0.3}"           # paus mellan avläsningar
TESTS="${TESTS-1 2 3 4 5}"   # vilka tester som körs i serie A (tomt = hoppa över serie A)
RUN_B="${RUN_B:-1}"           # 1 = kör serie B

NS=demo
APP=demo
BASE_IMAGE="nginx:1.27"
ALT_IMAGE="nginx:1.26"
MARKER="MANIPULERAD-FORBI-GIT"

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/resultat"
CSV="$OUT/resultat.csv"
APPFILE="$HERE/argocd/application.rendered.yaml"
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

mkdir -p "$OUT"
[ -f "$APPFILE" ] || { echo "Hittar inte $APPFILE. Kör 01-setup.sh först."; exit 1; }

now()     { date +%s.%N; }
since()   { awk -v a="$1" -v b="$(now)" 'BEGIN{printf "%.1f", b-a}'; }
over()    { awk -v a="$1" -v b="$(now)" -v t="$2" 'BEGIN{exit !((b-a) > t)}'; }
appfield(){ kubectl -n argocd get application "$APP" -o jsonpath="$1" 2>/dev/null || true; }

TEST_NAMES=(
  ""
  "Byta image i Deployment"
  "Ta bort NetworkPolicy"
  "Lägga till extra container"
  "Skapa pod som inte finns i Git"
  "Ändra fil i körande container"
)

manipulate() {
  case "$1" in
    1) kubectl -n $NS set image deployment/web web=$ALT_IMAGE >/dev/null ;;
    2) kubectl -n $NS delete networkpolicy web-allow-ingress >/dev/null ;;
    3) kubectl -n $NS patch deployment web --type=json -p \
         '[{"op":"add","path":"/spec/template/spec/containers/-","value":{"name":"extra","image":"busybox:1.36","command":["sleep","3600"]}}]' >/dev/null ;;
    4) kubectl -n $NS run rogue --image=busybox:1.36 --restart=Never -- sleep 3600 >/dev/null ;;
    5) kubectl -n $NS exec deploy/web -c web -- sh -c "echo $MARKER > /usr/share/nginx/html/index.html" >/dev/null ;;
  esac
}

# Returnerar 0 när klustret åter matchar det som ligger i Git för den aktuella ändringen.
restored() {
  local v
  case "$1" in
    1) v=$(kubectl -n $NS get deploy web -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null) || return 1
       [ "$v" = "$BASE_IMAGE" ] ;;
    2) v=$(kubectl -n $NS get networkpolicy web-allow-ingress --ignore-not-found -o name 2>/dev/null) || return 1
       [ -n "$v" ] ;;
    3) v=$(kubectl -n $NS get deploy web -o jsonpath='{.spec.template.spec.containers[*].name}' 2>/dev/null) || return 1
       [ "$v" = "web" ] ;;
    4) v=$(kubectl -n $NS get pod rogue --ignore-not-found -o name 2>/dev/null) || return 1
       [ -z "$v" ] ;;
    5) v=$(kubectl -n $NS exec deploy/web -c web -- cat /usr/share/nginx/html/index.html 2>/dev/null) || return 1
       [ -n "$v" ] && ! printf '%s' "$v" | grep -q "$MARKER" ;;
  esac
}

# Städar bort allt som en körning kan ha lämnat kvar, oavsett om Argo CD återställde eller inte.
cleanup() {
  kubectl -n $NS delete pod rogue --ignore-not-found --wait=true >/dev/null 2>&1
  local names
  names=$(kubectl -n $NS get deploy web -o jsonpath='{.spec.template.spec.containers[*].name}' 2>/dev/null)
  if [ "$names" != "web" ] && [ -n "$names" ]; then
    kubectl -n $NS patch deployment web --type=json \
      -p '[{"op":"remove","path":"/spec/template/spec/containers/1"}]' >/dev/null 2>&1
  fi
  local img
  img=$(kubectl -n $NS get deploy web -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
  [ "$img" = "$BASE_IMAGE" ] || kubectl -n $NS set image deployment/web web=$BASE_IMAGE >/dev/null 2>&1
  kubectl -n $NS get networkpolicy web-allow-ingress >/dev/null 2>&1 \
    || kubectl -n $NS apply -f "$HERE/manifests/networkpolicy.yaml" >/dev/null 2>&1
  if [ "${1:-0}" = "5" ]; then
    kubectl -n $NS delete pod -l app=web --wait=true >/dev/null 2>&1
  fi
  kubectl -n $NS rollout status deploy/web --timeout=180s >/dev/null 2>&1
}

wait_baseline() {
  local t0 s h
  t0=$(now)
  while :; do
    s=$(appfield '{.status.sync.status}'); h=$(appfield '{.status.health.status}')
    [ "$s" = "Synced" ] && [ "$h" = "Healthy" ] && return 0
    if over "$t0" 300; then
      echo "!! Appen nådde inte Synced/Healthy inom 300 s (nu: $s/$h). Avbryter."
      exit 1
    fi
    sleep 2
  done
}

recreate_app() {
  kubectl -n argocd delete application "$APP" --wait=true >/dev/null 2>&1
  kubectl apply -f "$APPFILE" >/dev/null
  sleep 3
}

# run_one <serie> <test-id> <körning> <timeout>
run_one() {
  local serie="$1" id="$2" n="$3" timeout="$4"
  local pre_op t0 start sync op det="nej" t_det="" res="nej" t_res=""
  pre_op=$(appfield '{.status.operationState.startedAt}')
  start=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  t0=$(now)
  if ! manipulate "$id"; then
    echo "   !! Ändringen gick inte att utföra, körningen hoppas över"
    return
  fi
  while ! over "$t0" "$timeout"; do
    if [ "$det" = "nej" ]; then
      sync=$(appfield '{.status.sync.status}')
      op=$(appfield '{.status.operationState.startedAt}')
      if [ "$sync" = "OutOfSync" ] || [ "$op" != "$pre_op" ]; then
        det="ja"; t_det=$(since "$t0")
      fi
    fi
    if restored "$id"; then
      res="ja"; t_res=$(since "$t0")
      # En återställning utan observerad statusändring räknas ändå som upptäckt.
      [ "$det" = "nej" ] && { det="ja"; t_det="$t_res"; }
      break
    fi
    sleep "$POLL"
  done
  printf '%s,T%s,"%s",%s,%s,%s,%s,%s,%s,%s\n' \
    "$serie" "$id" "${TEST_NAMES[$id]}" "$n" "$start" "$det" "$t_det" "$res" "$t_res" "$timeout" >> "$CSV"
  printf '   %s T%s körning %-2s  upptäckt: %-3s (%s s)  återställd: %-3s (%s s)\n' \
    "$serie" "$id" "$n" "$det" "${t_det:--}" "$res" "${t_res:--}"
}

write_versions() {
  {
    echo "datum: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "os: $(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-okänt}")"
    echo "kernel: $(uname -r)"
    echo "cpu: $(nproc) kärnor"
    echo "minne: $(awk '/MemTotal/{printf "%.1f GB", $2/1024/1024}' /proc/meminfo)"
    echo "k3s: $(k3s --version 2>/dev/null | head -1)"
    echo "kubernetes: $(kubectl version 2>/dev/null | tr '\n' ' ')"
    echo "argocd-image: $(kubectl -n argocd get statefulset argocd-application-controller -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)"
    echo "timeout.reconciliation: $(kubectl -n argocd get cm argocd-cm -o jsonpath='{.data.timeout\.reconciliation}' 2>/dev/null) (tomt = standardvärde)"
    echo "repo: $(kubectl -n argocd get application $APP -o jsonpath='{.spec.source.repoURL}' 2>/dev/null)"
    echo "revision: $(kubectl -n argocd get application $APP -o jsonpath='{.status.sync.revision}' 2>/dev/null)"
    echo "RUNS=$RUNS REPEATS=$REPEATS TIMEOUT_A=$TIMEOUT_A TIMEOUT_B=$TIMEOUT_B POLL=$POLL TESTS=[$TESTS] RUN_B=$RUN_B"
  } > "$OUT/versioner.txt"
}

# ---------------------------------------------------------------------------
if [ -f "$CSV" ]; then
  mv "$CSV" "$OUT/resultat-$(date +%Y%m%d-%H%M%S).csv"
fi
echo "serie,test,namn,korning,start_utc,upptackt,tid_till_upptackt_s,aterstalld,tid_till_aterstallning_s,timeout_s" > "$CSV"

wait_baseline
write_versions
echo ">> Versioner sparade i $OUT/versioner.txt"
echo ">> Serie A: test [$TESTS], $RUNS körningar per test. Ändringar som inte återställs väntar $TIMEOUT_A s per körning."

for id in $TESTS; do
  echo ">> Serie A, T$id: ${TEST_NAMES[$id]}"
  for n in $(seq 1 "$RUNS"); do
    cleanup "$id"
    recreate_app
    wait_baseline
    run_one A "$id" "$n" "$TIMEOUT_A"
  done
  cleanup "$id"
done

if [ "$RUN_B" = "1" ]; then
  echo ">> Serie B: T1 upprepas $REPEATS gånger utan att Application återskapas"
  recreate_app
  wait_baseline
  for n in $(seq 1 "$REPEATS"); do
    run_one B 1 "$n" "$TIMEOUT_B"
    cleanup 1
    wait_baseline
  done
fi

echo ">> Klart. Rådata: $CSV"
echo ">> Kör ./03-sammanstall.py för tabellerna."
