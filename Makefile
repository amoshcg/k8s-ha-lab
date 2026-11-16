# Atalhos do laboratório. "make" sozinho lista os alvos.
SHELL := bash
.DEFAULT_GOAL := help

.PHONY: help up cluster images deploy probe status watch reset reset-app down analyze lite

help: ## mostra esta ajuda
	@grep -hE '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*## "}{printf "  \033[36mmake %-10s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "  Demos guiadas: ./demos/01-reconciliacao.sh ... ./demos/10-etcd.sh"
	@echo "  Roteiro do seminário: ./demos/00-apresentacao.sh"
	@echo "  Falhas avulsas: ./chaos/no.sh, ./chaos/componente.sh, ./chaos/pod.sh"
	@echo "  Carga (k6): scripts/carga.sh   ·   Detecção de nó: scripts/deteccao.sh 20s|padrao"

up: cluster images deploy ## cria o cluster, constrói as imagens e implanta a aplicação

cluster: ## cria o cluster kind (3 control planes + 3 workers)
	@scripts/cluster.sh up

lite: ## cria a variante leve do cluster (1 control plane + 3 workers)
	@KIND_CONFIG=cluster/kind-lite.yaml scripts/cluster.sh up

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

reset: ## desfaz todas as falhas injetadas (nós, rede, componentes, taints)
	@chaos/restaura.sh

reset-app: ## como reset, e reaplica a aplicação (v1 com probes)
	@chaos/restaura.sh --app

analyze: ## analisa o CSV mais recente da sonda (ou CSV=results/arquivo.csv)
	@python3 analysis/analisa.py $(or $(CSV),$(shell ls -t results/*.csv 2>/dev/null | head -n1))

down: ## apaga o cluster e a sonda
	@scripts/cluster.sh down
