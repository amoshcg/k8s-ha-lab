#!/usr/bin/env bash
# Demo 9: eleição de líder do kube-scheduler e do kube-controller-manager (Lease).
source "$(dirname "$0")/../scripts/lib.sh"
require_cluster
[[ $(cp_nodes | wc -l) -ge 3 ]] || die "esta demo precisa do cluster com 3 control planes (cluster/kind-ha.yaml)"

lease() {
  try kubectl -n kube-system get lease "$1" \
    -o custom-columns='LEASE:.metadata.name,DONO:.spec.holderIdentity,DURAÇÃO:.spec.leaseDurationSeconds,RENOVADA:.spec.renewTime,TROCAS:.spec.leaseTransitions'
}

# Espera o dono da Lease mudar e mede quanto tempo levou.
wait_new_holder() {
  local l=$1 old=$2 t0 h el
  t0=$(date +%s)
  while :; do
    h=$(lease_holder "$l" || true)
    el=$(($(date +%s) - t0))
    if [[ -n "$h" && "$h" != "$old" ]]; then
      ok "novo líder de $l: $h (após ${el}s)"; mark "novo líder $l: $h"; return 0
    fi
    printf '\r%sT+%2ds dono atual: %s%s ' "$D" "$el" "${h:-?}" "$N"
    ((el > 60)) && { warn "sem troca em 60 s"; return 1; }
    sleep 1
  done
}

step "1. Três schedulers, um líder"
say "Cada control plane roda um kube-scheduler e um kube-controller-manager, mas só um de"
say "cada age (ativo-passivo). O líder é quem detém um objeto Lease na API e o renova a"
say "cada ~2 s. Os outros tentam tomar a Lease; só conseguem se ela expirar (15 s)."
say "A escrita na Lease usa controle de concorrência otimista (resourceVersion): se dois"
say "tentam ao mesmo tempo, um recebe conflito. Quem garante a ordem é o etcd."
lease kube-scheduler
lease kube-controller-manager
pause

step "2. Travar o kube-scheduler líder"
old=$(lease_holder kube-scheduler)
say "Vou congelar o scheduler de $old. Um pod criado agora fica Pending até a Lease"
say "expirar e outro scheduler assumir."
"$ROOT/chaos/componente.sh" freeze kube-scheduler "$old"
p="pendente-$RANDOM"
try kubectl -n "$NS" run "$p" --image=k8slab/web:v1 --image-pull-policy=IfNotPresent --restart=Never --labels=demo=scheduler
countdown 3 "o pod foi criado"
try kubectl -n "$NS" get pod "$p" -o wide
wait_new_holder kube-scheduler "$old" || true
countdown 3 "o novo líder escalona o pod pendente"
try kubectl -n "$NS" get pod "$p" -o wide
try kubectl -n "$NS" delete pod "$p" --wait=false
pause

step "3. O antigo líder volta"
say "Ao descongelar, o scheduler antigo tenta renovar uma Lease que já não é dele,"
say "percebe que perdeu a liderança e encerra; o kubelet o reinicia como seguidor."
"$ROOT/chaos/componente.sh" unfreeze kube-scheduler "$old"
countdown 10 "aguardando"
try kubectl -n kube-system get pods -l component=kube-scheduler -o wide
lease kube-scheduler
pause

step "4. Travar o kube-controller-manager líder e apagar um pod"
old=$(lease_holder kube-controller-manager)
say "Sem controller-manager ativo, ninguém reconcilia: o pod apagado não é reposto"
say "até o novo líder assumir. Os pods que já existem continuam atendendo normalmente."
"$ROOT/chaos/componente.sh" freeze kube-controller-manager "$old"
"$ROOT/chaos/pod.sh" delete
countdown 5 "observe: só 3 pods"
try kubectl -n "$NS" get pods -l app=web
wait_new_holder kube-controller-manager "$old" || true
countdown 8 "o novo líder reconcilia"
try kubectl -n "$NS" get pods -l app=web
"$ROOT/chaos/componente.sh" unfreeze kube-controller-manager "$old"
ok "fim da demo 9"
