# 7. Solução de problemas

| Sintoma | Causa provável | Solução |
|---|---|---|
| `kind create cluster` trava ou pods do `kube-system` em CrashLoop com *too many open files* | limites de inotify (Linux) | ver [preparação](01-preparacao.md#linux-ubuntudebian); depois `make down && make cluster` |
| nós `NotReady` logo após criar, contêineres sendo mortos (OOM) | pouca memória para o Docker | Docker Desktop/WSL com ≥ 8 GB, ou `make lite` |
| kubelet não sobe; log cita cgroup v1 | host com cgroup v1 | `NODE_IMAGE=kindest/node:v1.34.3@sha256:08497ee19eace7b4b5348db5c6a1591d7752b164530a36f855cb0f2bdcbadd48 make cluster` |
| `port is already allocated` (8080) ao criar o cluster | outra coisa usa a porta 8080 | troque `hostPort` em `cluster/kind-ha.yaml` |
| sonda não sobe: porta 8090 ocupada | outra coisa usa a 8090 | edite `-p 127.0.0.1:8090:8090` em `scripts/probe.sh` e use `PROBER_URL=http://localhost:<porta>` nos scripts |
| `kind load` falha com *content digest ... not found* | image store do containerd no Docker | o script já usa `--provenance=false`; se persistir: `docker save k8slab/web:v1 -o /tmp/v1.tar && kind load image-archive /tmp/v1.tar --name k8slab` (repita por versão) |
| pods em `ErrImagePull`/`ImagePullBackOff` com imagem `k8slab/...` | imagens não carregadas nos nós | `make images` |
| depois de reiniciar o computador ou o Docker, o cluster não volta | contêineres do kind voltam com outros IPs; cluster com vários nós não se recupera | `make down && make up` (por isso as falhas usam `docker pause`, nunca `docker stop`) |
| `kubectl` trava ou dá timeout depois de uma demo | algum componente ficou congelado/parado | `make reset`; conferir com `make status` |
| `make status` mostra todos os membros do etcd como SEM RESPOSTA | `etcdctl` não foi copiado para os nós | `scripts/cluster.sh up` (com o cluster existente, só reinstala o etcdctl) |
| `chaos/no.sh latency` falha com *Specified qdisc kind is unknown* | kernel da VM do Docker (macOS/Windows) sem `sch_netem` | experimento opcional; use Linux nativo ou uma VM Linux |
| sonda: *permission denied* ao gravar em `results/` | dono da pasta diferente do seu usuário | `sudo chown -R "$USER" results` |
| pista `api` sempre falhando com HTTP 401 | token da sonda expirou (24 h) | reinicie a sonda (`make probe` gera um token novo) |
| scripts com `$'\r': command not found` | arquivos com final de linha do Windows | clone dentro do WSL e use `git config --global core.autocrlf input` |
| `kubectl` dos seus outros clusters mudou de contexto | o kind define `kind-k8slab` como atual | `kubectl config use-context <o-seu>`; os scripts do laboratório sempre usam `--context kind-k8slab` |

## Comandos de diagnóstico

```bash
make status
kubectl -n kube-system get pods -o wide
kubectl get events -A --sort-by=.lastTimestamp | tail -30
docker exec k8slab-control-plane crictl ps -a          # contêineres dentro do nó
docker exec k8slab-control-plane journalctl -u kubelet --no-pager | tail -50
kind export logs ./logs-kind --name k8slab             # todos os logs, para anexar a um pedido de ajuda
```
