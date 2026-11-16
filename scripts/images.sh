#!/usr/bin/env bash
# Constrói as imagens do laboratório e as carrega nos nós do kind (não precisa de
# registry: "kind load" copia a imagem para o containerd de cada nó).
#
#   k8slab/web:v1   versão inicial
#   k8slab/web:v2   versão nova e saudável (rollout)
#   k8slab/web:v3   versão com defeito: nunca fica pronta e morre (rollback)
#   k8slab/prober   a sonda externa + painel
source "$(dirname "$0")/lib.sh"
require_cluster

# --provenance=false evita o manifesto de atestado que faz o "kind load" falhar
# quando o Docker usa o image store do containerd.
build() { run docker build --provenance=false -q "$@" "$ROOT/app"; }

info "construindo imagens"
build --target web --build-arg VERSION=v1 -t k8slab/web:v1
build --target web --build-arg VERSION=v2 -t k8slab/web:v2
build --target web --build-arg VERSION=v3 --build-arg BROKEN=true -t k8slab/web:v3
build --target prober -t k8slab/prober:latest

info "carregando as imagens da aplicação nos nós do cluster"
run kind load docker-image --name "$CLUSTER" k8slab/web:v1 k8slab/web:v2 k8slab/web:v3
ok "imagens prontas. Próximo passo: make deploy"
