#!/usr/bin/env bash
# Gera carga na aplicação com k6 e mede vazão e latência.
#   scripts/carga.sh                    20 usuários virtuais por 60 s
#   VUS=50 DURACAO=2m scripts/carga.sh
# Combine com uma falha ou rollout em outro terminal para medir o impacto na vazão.
# O resumo do k6 fica em results/carga_<data>.json.
source "$(dirname "$0")/lib.sh"
require_cluster

K6_IMAGE="${K6_IMAGE:-grafana/k6:1.0.0}"
stamp=$(date +%Y%m%d-%H%M%S)
mkdir -p "$ROOT/results"
mark "carga k6 início (VUS=${VUS:-20}, ${DURACAO:-60s})"
docker run --rm -i --network kind \
  --user "$(id -u):$(id -g)" \
  -e VUS="${VUS:-20}" -e DURACAO="${DURACAO:-60s}" \
  -e ALVO="http://${ENTRY_NODE}:30080/" \
  -v "$ROOT/bench:/bench:ro" -v "$ROOT/results:/results" \
  "$K6_IMAGE" run --summary-export "/results/carga_${stamp}.json" /bench/carga.js
mark "carga k6 fim"
ok "resumo em results/carga_${stamp}.json"
