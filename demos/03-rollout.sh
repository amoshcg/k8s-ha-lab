#!/usr/bin/env bash
# Demo 3: rolling update sem indisponibilidade (v1 -> v2).
source "$(dirname "$0")/../scripts/lib.sh"
require_cluster

step "1. Situação atual"
try kubectl -n "$NS" get deploy web -o wide
try kubectl -n "$NS" rollout history deploy/web
say "Estratégia: maxSurge=1, maxUnavailable=0. Sobe 1 pod novo; só quando ele fica"
say "pronto (readiness ok + minReadySeconds=3) um antigo é removido. E assim por diante."
pause

step "2. Publicar a v2"
say "No painel da sonda as barras vão mudar de azul (v1) para verde (v2), sem vermelho."
try kubectl -n "$NS" annotate deploy/web kubernetes.io/change-cause="v2: nova versão" --overwrite
mark "rollout v1 -> v2"
try kubectl -n "$NS" set image deploy/web app=k8slab/web:v2
try kubectl -n "$NS" rollout status deploy/web --timeout=180s
pause

step "3. Resultado"
say "O ReplicaSet antigo continua existindo com 0 réplicas: é ele que permite o rollback."
try kubectl -n "$NS" get rs -o wide
try kubectl -n "$NS" rollout history deploy/web
ok "fim da demo 3"
