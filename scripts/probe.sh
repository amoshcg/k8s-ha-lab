#!/usr/bin/env bash
# Sobe a sonda externa (contêiner na rede "kind", fora do cluster).
#   scripts/probe.sh [rótulo]     ex.: scripts/probe.sh falha-de-no
# Painel: http://localhost:8090  ·  CSV e resumo: pasta results/
# Ctrl+C encerra e imprime o resumo (disponibilidade, latência, incidentes).
source "$(dirname "$0")/lib.sh"
require_cluster

LABEL="${1:-sonda}"
LAB="$ROOT/.lab"
mkdir -p "$ROOT/results" "$LAB"

# Credenciais mínimas para a pista "api": token de uma ServiceAccount que só
# pode alterar o ConfigMap demo/api-heartbeat (ver k8s/40-api-heartbeat.yaml).
kubectl -n "$NS" get sa api-prober >/dev/null 2>&1 || die "rode antes: make deploy"
kubectl -n "$NS" create token api-prober --duration=24h >"$LAB/token"
kubectl config view --raw --minify --context "$KCTX" \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 --decode >"$LAB/ca.crt"

docker rm -f "$PROBER_CONTAINER" >/dev/null 2>&1 || true
TTY=-i
[[ -t 0 && -t 1 ]] && TTY=-it

# A sonda fala com o cluster pelos nomes dos contêineres na rede "kind":
#   aplicação: NodePort 30080 do nó de entrada
#   API:       o HAProxy que o kind coloca na frente dos 3 kube-apiservers
API_URL="https://${CLUSTER}-external-load-balancer:6443"
docker inspect "${CLUSTER}-external-load-balancer" >/dev/null 2>&1 ||
  API_URL="https://${CLUSTER}-control-plane:6443"   # cluster com um só control plane

exec docker run --rm $TTY --name "$PROBER_CONTAINER" --network kind \
  -p 127.0.0.1:8090:8090 \
  --user "$(id -u):$(id -g)" \
  -e TZ="$(host_tz)" \
  -v "$ROOT/results:/results" \
  -v "$LAB:/lab:ro" \
  k8slab/prober:latest \
  -target "http://${ENTRY_NODE}:30080/" \
  -api-url "$API_URL" -api-token-file /lab/token -api-ca-file /lab/ca.crt \
  -label "$LABEL" "${@:2}"
