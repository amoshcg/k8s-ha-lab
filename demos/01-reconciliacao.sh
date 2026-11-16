#!/usr/bin/env bash
# Demo 1: o laço de reconciliação.
# Você declara o estado desejado; controladores comparam com o estado atual e agem
# para aproximar um do outro, sem parar.
source "$(dirname "$0")/../scripts/lib.sh"
require_cluster

step "1. Estado desejado × estado atual"
say "O Deployment declara 4 réplicas. O Deployment controller cria um ReplicaSet,"
say "o ReplicaSet controller cria os pods, o scheduler escolhe um nó para cada um"
say "e o kubelet do nó os executa. Cada um só lê e escreve objetos na API."
try kubectl -n "$NS" get deploy,rs,pods -o wide
pause

step "2. Apagar um pod (perturbar o estado atual)"
pod=$(app_pods | head -n1)
say "Vou apagar $pod. O ReplicaSet controller percebe 3 < 4 e cria outro."
say "Observe a sonda: o pod apagado encerra com graça (sai do Service antes de parar),"
say "então nenhuma requisição deve falhar."
mark "delete pod $pod"
try kubectl -n "$NS" delete pod "$pod" --wait=false
countdown 8 "aguardando a reconciliação"
try kubectl -n "$NS" get pods -o wide
pause

step "3. Quem fez o quê (eventos)"
say "SuccessfulCreate = ReplicaSet controller · Scheduled = kube-scheduler · Pulled/Created/Started = kubelet"
try_sh "kubectl -n $NS get events --sort-by=.lastTimestamp | tail -n 12"
pause

step "4. Mudar o estado desejado: escalar para 6"
mark "scale web=6"
try kubectl -n "$NS" scale deploy/web --replicas=6
countdown 10 "aguardando os novos pods"
say "Repare na coluna NODE: o scheduler espalha as réplicas entre os workers (topologySpreadConstraints)."
try kubectl -n "$NS" get pods -o wide
pause

step "5. Voltar para 4"
mark "scale web=4"
try kubectl -n "$NS" scale deploy/web --replicas=4
countdown 8 "aguardando"
try kubectl -n "$NS" get pods -o wide
ok "fim da demo 1"
