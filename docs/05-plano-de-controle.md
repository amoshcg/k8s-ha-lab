# 5. Experimentos do plano de controle (demos 8 a 10)

As demos 9 e 10 precisam do cluster com 3 control planes (`make cluster`, não
`make lite`). Mantenha a sonda e o painel abertos: a pista `api` é a protagonista aqui.

---

## Demo 8: o kube-scheduler — `./demos/08-scheduler.sh`

### Como o scheduler funciona

O scheduler observa pods com `spec.nodeName` vazio e os coloca numa **fila de
prioridade**. Para cada pod, executa o *scheduling framework*, uma sequência de pontos
de extensão, cada um implementado por plugins:

```
fila ─► PreFilter ─► Filter ─► (PostFilter: preempção) ─► PreScore ─► Score ─► NormalizeScore
     ─► Reserve ─► Permit ─► PreBind ─► Bind ─► PostBind
          └──────── ciclo de escalonamento ───────┘   └──── ciclo de binding (assíncrono) ────┘
```

| Fase | O que decide | Plugins padrão (exemplos) |
|---|---|---|
| **Filter** | quais nós são **viáveis** (regras rígidas) | `NodeResourcesFit` (requests cabem?), `TaintToleration`, `NodeAffinity`, `NodePorts`, `NodeUnschedulable`, `PodTopologySpread` (com `DoNotSchedule`), `VolumeBinding` |
| **Score** | qual nó viável é **melhor** (preferências, 0–100 por plugin, com pesos) | `NodeResourcesFit` (estratégia de alocação), `NodeResourcesBalancedAllocation`, `PodTopologySpread` (com `ScheduleAnyway`), `InterPodAffinity`, `ImageLocality`, `TaintToleration` |
| **PostFilter** | se nenhum nó é viável: dá para **preemptar** pods de menor prioridade? | `DefaultPreemption` |
| **Bind** | grava a decisão: cria um objeto `Binding` que preenche `spec.nodeName` | `DefaultBinder` |

Pontos que costumam cair em prova e em apresentação:

- O scheduler decide pelos **requests** declarados, não pelo uso real de CPU/memória.
- Ele decide **uma vez**. Não move pods depois (isso é o *descheduler*).
- Pods que não cabem vão para a fila de não escalonáveis e são reavaliados quando algo
  relevante muda no cluster (um nó novo, um pod removido...).
- A decisão é **otimista**: o scheduler mantém um cache do cluster e "reserva" o nó
  antes de o Binding ser gravado; o binding acontece em paralelo com o próximo pod.
- Um único scheduler ativo por vez (ativo-passivo via Lease, demo 9). Arquiteturas
  alternativas: Omega (estado compartilhado com concorrência otimista entre vários
  schedulers) e o Borg (de onde vieram as ideias de filtro + pontuação).

### O que a demo faz

| Passo | Ação | O que observar |
|---|---|---|
| 1 | réplicas da app | espalhadas entre os workers (pontuação do `PodTopologySpread`) |
| 2 | `describe node` | *Allocatable* × *Allocated resources*: a conta que o `NodeResourcesFit` faz |
| 3 | pod pedindo 64 CPUs | `Pending`; o evento `FailedScheduling` diz quantos nós cada filtro eliminou |
| 4 | `nodeAffinity` obrigatória para `disco=ssd` | só o nó rotulado passa no filtro |
| 5 | taint `NoSchedule` num worker + escalar para 7 | nenhuma réplica nova vai para lá |
| 6 | pod com `spec.nodeName` já preenchido | roda sem passar pelo scheduler (não há evento `Scheduled`) |
| 7 | parar o scheduler nos 3 control planes | pod novo fica `Pending` **sem nenhum evento**; ao voltar, é escalonado |

Mensagem típica do passo 3:

```
0/6 nodes are available: 3 Insufficient cpu, 3 node(s) had untolerated taint
{node-role.kubernetes.io/control-plane: }. preemption: 0/6 nodes are available: ...
```

Para ver a **pontuação** de cada plugin em cada nó, use o
[kube-scheduler-simulator](https://github.com/kubernetes-sigs/kube-scheduler-simulator)
(projeto oficial do SIG Scheduling; sobe em contêineres com `make docker_up`). Ótimo para um slide.

---

## Demo 9: eleição de líder — `./demos/09-lideres.sh`

**Conceito.** Exclusão mútua distribuída com **lease** (arrendamento com prazo): o líder
precisa renovar a cada ~2 s. Se não renovar por 15 s (`leaseDurationSeconds`), um
seguidor pode tomar a Lease. O prazo evita depender de detectar a falha: basta o tempo
passar.

| Passo | Falha | Esperado |
|---|---|---|
| 2 | `SIGSTOP` no kube-scheduler líder + criação de um pod | o pod fica `Pending` até outro scheduler assumir, ~15–20 s depois |
| 3 | `SIGCONT` no antigo líder | ele tenta renovar uma Lease que já não é dele, percebe que perdeu a liderança e **encerra**; o kubelet o reinicia como seguidor (RESTARTS +1) |
| 4 | `SIGSTOP` no kube-controller-manager líder + apagar um pod | o pod **não é reposto** até o novo líder assumir; a sonda segue sem falhas (3 réplicas bastam) |

O passo 3 mostra um cuidado clássico com leases: um processo pausado (GC longo, VM
congelada) pode "acordar" achando que ainda é líder. Aqui ele verifica a Lease antes
de agir e desiste. Em sistemas que escrevem em recursos externos, a defesa completa
exige *fencing tokens*.

**Faça à mão:**
```bash
kubectl -n kube-system get lease kube-scheduler -w
chaos/componente.sh freeze kube-scheduler lider
chaos/componente.sh unfreeze kube-scheduler todos
```

---

## Demo 10: etcd e Raft — `./demos/10-etcd.sh`

| Passo | Falha | Esperado no etcd | Na sonda |
|---|---|---|---|
| 2 | `SIGSTOP` no **líder** | seguidores esperam o *election timeout* (~1 s), um vence com 2 votos, **TERM sobe** | `api`: falhas breves; a fatia que passa pelo apiserver do nó afetado falha até o HAProxy removê-lo. `app`: nada |
| 2b | `SIGCONT` | o antigo líder volta como seguidor (term maior vence) e alcança o log | — |
| 3 | parada **graciosa** do líder (SIGTERM) | o líder **transfere** a liderança antes de sair: sem esperar timeout | `api`: falhas só pelo apiserver local que perdeu o etcd |
| 4 | `SIGSTOP` em **2 de 3** membros | sem maioria, sem líder: leituras e escritas consistentes recusadas | `api`: **100% de falhas**. `app`: **100% ok** |
| 4b | `SIGCONT` nos dois | quórum volta, novo líder, API volta | `api` recupera |

**A mensagem do passo 4** é a mais importante da apresentação:

- O etcd escolhe **consistência** quando não há maioria (CP no teorema CAP). O membro
  isolado não aceita escritas, porque poderia divergir.
- Mesmo assim **a aplicação continua no ar**. Pods, kubelets, kube-proxy e regras de
  rede já programadas não dependem do plano de controle a cada requisição. O que se
  perde é a capacidade de **mudar** o cluster: deploys, escalonamento, reação a novas
  falhas.
- Durante a queda, scheduler e controller-manager não conseguem renovar suas Leases,
  perdem a liderança e reiniciam. Veja a coluna de reinícios em `make status`.

Não deixe o quórum perdido por mais de ~1 minuto: as livenessProbes dos static pods
acabam reiniciando os processos congelados (o que também é uma recuperação, só que menos
didática).

**Faça à mão:**
```bash
make status                                   # tabela de membros, líder e term
chaos/componente.sh freeze etcd lider
make status                                   # novo líder, term +1
chaos/componente.sh unfreeze etcd todos
# perda de quórum:
chaos/componente.sh freeze etcd k8slab-control-plane2
chaos/componente.sh freeze etcd k8slab-control-plane3
kubectl get pods -A --request-timeout=5s      # falha
curl -s localhost:8080/                       # funciona
chaos/componente.sh unfreeze etcd todos
```

### Extra: latência entre membros do etcd

```bash
chaos/no.sh latency k8slab-control-plane2 100 20     # +100 ms ±20 na saída do nó
chaos/no.sh latency k8slab-control-plane3 100 20
# observe a latência p95/p99 da pista "api" no painel subir: cada escrita espera a maioria
chaos/no.sh clear k8slab-control-plane2 ; chaos/no.sh clear k8slab-control-plane3
```

Com atraso maior que o *election timeout* (1 s), começam eleições espúrias. É por isso
que a documentação do etcd recomenda ajustar `--heartbeat-interval` e
`--election-timeout` ao RTT entre os membros, e manter os membros perto uns dos outros.

Próximo: [6. Métricas para o relatório](06-metricas.md)
