#!/usr/bin/env bash
# Demo 7: manutenção planejada (drain) respeitando o PodDisruptionBudget.
source "$(dirname "$0")/../scripts/lib.sh"
require_cluster

node=${1:-$(busiest_worker)}
require_node "$node"

step "1. O PodDisruptionBudget"
try kubectl -n "$NS" get pdb web
say "minAvailable=3: a API de eviction recusa remover um pod se sobrarem menos de 3 prontos."
try_sh "kubectl -n $NS get pods -o wide | grep -E 'NAME|$node'"
pause

step "2. Drenar $node (ex.: atualizar o sistema operacional da máquina)"
say "drain = cordon (o scheduler para de mandar pods para o nó) + eviction de cada pod."
say "Se houver 2 pods aqui, o 2º espera o substituto do 1º ficar pronto: aparecem"
say "mensagens 'would violate the pod's disruption budget', e o drain tenta de novo."
mark "drain $node"
try kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data --timeout=180s
try kubectl get nodes
try_sh "kubectl -n $NS get pods -o wide"
say "Na sonda: nenhuma falha. Manutenção sem janela de indisponibilidade."
pause

step "3. Fim da manutenção"
mark "uncordon $node"
try kubectl uncordon "$node"
say "O nó volta a receber pods NOVOS; os atuais não são rebalanceados automaticamente"
say "(para isso existe o projeto descheduler)."
ok "fim da demo 7"
