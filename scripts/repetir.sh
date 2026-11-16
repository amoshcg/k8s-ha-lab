#!/usr/bin/env bash
# Repete um experimento N vezes, sem pausas, para obter mediana e extremos.
#   scripts/repetir.sh <N> <comando...>
# Exemplos (com a sonda rodando em outro terminal):
#   scripts/repetir.sh 5 demos/06-falha-de-no.sh
#   scripts/repetir.sh 10 chaos/pod.sh crash
# Entre as repetições: restaura o laboratório e espera ESPERA segundos (padrão 20).
# Depois: make analyze  (a tabela "Experimentos repetidos" agrupa as marcas iguais)
source "$(dirname "$0")/lib.sh"
require_cluster

n=${1:?informe N}
shift
[[ $# -gt 0 ]] || die "informe o comando"
export AUTO=1 AUTO_WAIT="${AUTO_WAIT:-2}"
for i in $(seq 1 "$n"); do
  step "repetição $i de $n: $*"
  "$@" || warn "a repetição $i terminou com erro"
  "$ROOT/chaos/restaura.sh" >/dev/null || warn "restauração falhou"
  kubectl -n "$NS" rollout status deploy/web --timeout=180s >/dev/null || true
  [[ $i -lt $n ]] && countdown "${ESPERA:-20}" "estabilizando antes da próxima"
done
ok "concluído. Rode: make analyze"
