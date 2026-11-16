#!/usr/bin/env bash
# Ajusta o tempo que o node lifecycle controller espera antes de declarar um nó
# inacessível (--node-monitor-grace-period do kube-controller-manager). Serve para
# o experimento "parâmetro × tempo de detecção" (docs/06-metricas.md).
#
#   scripts/deteccao.sh 20s       detecção mais rápida (mais risco de falso positivo)
#   scripts/deteccao.sh padrao    remove o ajuste (volta ao padrão, 50 s)
#   scripts/deteccao.sh           mostra o valor atual
#
# O kube-controller-manager é um static pod: basta editar o manifesto em cada
# control plane e o kubelet o recria com o novo argumento.
source "$(dirname "$0")/lib.sh"
require_cluster
M=/etc/kubernetes/manifests/kube-controller-manager.yaml
val=${1:-}

for n in $(cp_nodes); do
  if [[ -z "$val" ]]; then
    cur=$(docker exec "$n" grep -o -- '--node-monitor-grace-period=[^ "]*' "$M" || true)
    printf '%-26s %s\n' "$n" "${cur:-padrão (50s)}"
    continue
  fi
  # Edita uma cópia fora da pasta e a move de volta (rename atômico), para o
  # kubelet nunca ler um arquivo pela metade.
  docker exec "$n" bash -c "
    set -e
    cp $M /etc/kubernetes/kcm.tmp
    sed -i '/--node-monitor-grace-period=/d' /etc/kubernetes/kcm.tmp
    if [ '$val' != padrao ]; then
      sed -i 's|^\\([[:space:]]*\\)- kube-controller-manager\$|&\\n\\1- --node-monitor-grace-period=$val|' /etc/kubernetes/kcm.tmp
    fi
    mv /etc/kubernetes/kcm.tmp $M"
  ok "$n: node-monitor-grace-period=${val/padrao/padrão}"
done
if [[ -n "$val" ]]; then
  mark "node-monitor-grace-period=$val"
  info "o kubelet recria os kube-controller-manager em alguns segundos (make status para conferir)"
fi
