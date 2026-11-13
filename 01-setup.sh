#!/usr/bin/env bash
# Sätter upp k3s och Argo CD och skapar Application-objektet "demo".
# Körs en gång. Kräver Linux (eller WSL2 med systemd) och sudo.
#
#   REPO_URL=https://github.com/<användare>/gitops-exjobb.git ./01-setup.sh
set -euo pipefail

: "${REPO_URL:?Ange REPO_URL, t.ex. REPO_URL=https://github.com/<användare>/gitops-exjobb.git}"
ARGOCD_REF="${ARGOCD_REF:-stable}"
HERE="$(cd "$(dirname "$0")" && pwd)"
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

if ! command -v k3s >/dev/null 2>&1; then
  echo ">> Installerar k3s"
  curl -sfL https://get.k3s.io | sh -s - --write-kubeconfig-mode 644
fi

echo ">> Väntar på att noden blir Ready"
for _ in $(seq 1 60); do
  kubectl get nodes 2>/dev/null | grep -q ' Ready' && break
  sleep 5
done
kubectl get nodes

echo ">> Installerar Argo CD ($ARGOCD_REF)"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd --server-side --force-conflicts \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_REF}/manifests/install.yaml"

echo ">> Väntar på Argo CD (kan ta några minuter första gången)"
kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=600s
kubectl -n argocd rollout status deploy/argocd-server --timeout=600s
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=600s

echo ">> Skapar Application 'demo' mot $REPO_URL"
sed "s|REPO_URL|${REPO_URL}|" "$HERE/argocd/application.yaml" > "$HERE/argocd/application.rendered.yaml"
kubectl apply -f "$HERE/argocd/application.rendered.yaml"

echo ">> Väntar på att appen blir Synced och Healthy"
for _ in $(seq 1 120); do
  s=$(kubectl -n argocd get application demo -o jsonpath='{.status.sync.status}' 2>/dev/null || true)
  h=$(kubectl -n argocd get application demo -o jsonpath='{.status.health.status}' 2>/dev/null || true)
  [ "$s" = "Synced" ] && [ "$h" = "Healthy" ] && break
  sleep 5
done
kubectl -n argocd get application demo
kubectl -n demo get deploy,svc,networkpolicy

s=$(kubectl -n argocd get application demo -o jsonpath='{.status.sync.status}')
h=$(kubectl -n argocd get application demo -o jsonpath='{.status.health.status}')
if [ "$s" != "Synced" ] || [ "$h" != "Healthy" ]; then
  echo "!! Appen är inte Synced/Healthy ($s/$h). Kontrollera REPO_URL och att repot är publikt."
  exit 1
fi
echo ">> Klart. Kör nu ./02-kor-tester.sh"
