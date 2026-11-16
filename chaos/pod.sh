#!/usr/bin/env bash
# Falhas no nível do POD da aplicação.
#
#   chaos/pod.sh delete  [pod]   apaga o pod (encerramento gracioso, como num rollout ou drain)
#   chaos/pod.sh crash   [pod]   o processo morre abruptamente (exit 2), sem graceful shutdown
#   chaos/pod.sh break   [pod]   o pod "trava": /healthz e /readyz falham => sai do Service e é reiniciado
#   chaos/pod.sh unready [pod]   só /readyz falha => sai do Service, mas NÃO é reiniciado
#   chaos/pod.sh fix     <pod>   desfaz break/unready
#
# Sem [pod], escolhe um pod em execução ao acaso. As chamadas usam o proxy do
# kube-apiserver para atingir exatamente o pod escolhido.
source "$(dirname "$0")/../scripts/lib.sh"
require_cluster

action=${1:-}
pod=${2:-}
[[ -n "$action" ]] || { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

if [[ -z "$pod" ]]; then
  [[ "$action" == fix ]] && die "informe o pod: chaos/pod.sh fix <pod>"
  pods=$(app_pods)
  [[ -n "$pods" ]] || die "nenhum pod da aplicação em execução"
  count=$(printf '%s\n' "$pods" | wc -l | tr -d ' ')
  pod=$(printf '%s\n' "$pods" | sed -n "$((RANDOM % count + 1))p")
fi
node=$(pod_node "$pod")

case "$action" in
  delete)
    mark "delete pod $pod ($node)"
    run kubectl -n "$NS" delete pod "$pod" --wait=false
    ;;
  crash | break | unready | fix)
    mark "$action $pod ($node)"
    printf '%s$ kubectl get --raw /api/v1/namespaces/%s/pods/%s:8080/proxy/admin/%s%s\n' "$B" "$NS" "$pod" "$action" "$N"
    pod_call "$pod" "/admin/$action"
    echo
    ;;
  *) die "ação desconhecida: $action" ;;
esac
ok "$action aplicado em $pod (nó $node) às $(date +%H:%M:%S)"
