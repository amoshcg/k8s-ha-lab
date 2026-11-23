# Atalhos do laboratório. "make" sozinho lista os alvos.
SHELL := bash
.DEFAULT_GOAL := help

.PHONY: help up cluster images deploy probe status watch reset reset-app down

help: ## mostra esta ajuda
	@grep -hE '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*## "}{printf "  \033[36mmake %-10s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "  Apresentação: ./demos/00-apresentacao.sh   (antes: make reset-app; make probe; scripts/deteccao.sh 20s)"

up: cluster images deploy ## cria o cluster, constrói as imagens e implanta a aplicação

cluster: ## cria o cluster kind (3 control planes + 3 workers)
	@scripts/cluster.sh up

images: ## constrói as imagens e as carrega nos nós
	@scripts/images.sh

deploy: ## aplica os manifestos de k8s/ (volta a app para v1)
	@scripts/deploy.sh

probe: ## sobe a sonda + painel em http://localhost:8090 (use LABEL=nome)
	@scripts/probe.sh $(or $(LABEL),sonda)

status: ## panorama: nós, líderes (etcd, scheduler, controller-manager), pods
	@scripts/status.sh

watch: ## acompanha nós, ReplicaSets e pods a cada segundo
	@scripts/watch.sh

reset: ## desfaz as falhas injetadas (nós e etcd congelados)
	@chaos/restaura.sh

reset-app: ## como reset, e reaplica a aplicação (v1 com probes)
	@chaos/restaura.sh --app

down: ## apaga o cluster e a sonda
	@scripts/cluster.sh down
