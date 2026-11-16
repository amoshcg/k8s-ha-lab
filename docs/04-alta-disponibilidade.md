# 4. Experimentos de alta disponibilidade (demos 1 a 7)

Antes de começar: cluster criado, aplicação implantada (`make up`) e sonda rodando em
outro terminal (`make probe`). Cada demo explica o que vai fazer, executa e espera
**Enter** entre os passos. Ao final de cada uma, se algo ficou estranho, `make reset`.

As demos rodam em sequência sem precisar de reset: a 3 deixa a v2 no ar, a 4 parte
dela, e a 5 termina voltando para a v1.

---

## Demo 1: reconciliação — `./demos/01-reconciliacao.sh`

**Conceito.** O Kubernetes é um conjunto de laços de controle. Você declara o estado
desejado e controladores trabalham continuamente para que o estado atual o alcance.

**O que acontece**
1. Lista Deployment → ReplicaSet → Pods (a cadeia de donos, `ownerReferences`).
2. Apaga um pod: o ReplicaSet controller vê 3 < 4 e cria outro.
3. Mostra os eventos e quem gerou cada um: `SuccessfulCreate` (ReplicaSet controller),
   `Scheduled` (scheduler), `Pulled/Created/Started` (kubelet).
4. Escala para 6 e volta para 4.

**Esperado na sonda:** nenhuma falha. O pod apagado recebe SIGTERM, sai do Service e
continua atendendo por 5 s antes de parar (encerramento gracioso).

**Faça à mão:**
```bash
kubectl -n demo delete pod <pod>
kubectl -n demo get pods -w
kubectl -n demo get pod <pod> -o jsonpath='{.metadata.ownerReferences[0].name}'
```

---

## Demo 2: probes — `./demos/02-probes.sh`

**Conceito.** Detecção de falhas no nível do processo. Readiness decide **tráfego**,
liveness decide **reinício**. Misturar as duas é um erro comum: uma liveness que
depende do banco reinicia todos os pods quando o banco cai.

| Passo | Falha injetada | O que o Kubernetes faz | Na sonda |
|---|---|---|---|
| unready | `/readyz` → 503 | tira o pod do EndpointSlice; RESTARTS continua 0 | 0 falhas |
| break | tudo → 500 | readiness tira do Service em ≤ 4 s; liveness reinicia em ~9 s | erros 500 por alguns segundos |
| crash | processo morre | kubelet reinicia na hora (CrashLoopBackOff se repetir) | poucas falhas, só as que iam para aquele pod |

**Faça à mão:**
```bash
chaos/pod.sh unready            # escolhe um pod ao acaso e mostra qual
kubectl -n demo get endpointslices -l kubernetes.io/service-name=web -o yaml | grep -B2 -A3 ready
chaos/pod.sh fix <pod>
chaos/pod.sh break
kubectl -n demo describe pod <pod> | tail     # "Liveness probe failed ... will be restarted"
```

**Para o relatório:** o tempo até a readiness agir é `periodSeconds × failureThreshold`
(+ propagação). Probes mais agressivas detectam antes, mas aumentam a carga e o risco de
falso positivo.

---

## Demo 3: rollout sem indisponibilidade — `./demos/03-rollout.sh`

**Conceito.** Atualização incremental com `maxSurge: 1` e `maxUnavailable: 0`: a
capacidade nunca fica abaixo de 4 réplicas prontas.

**O que acontece:** `kubectl set image ... k8slab/web:v2`. O Deployment controller
cria um novo ReplicaSet e alterna: +1 pod novo → espera ficar pronto por 3 s
(`minReadySeconds`) → −1 pod antigo → repete.

**Esperado na sonda:** as barras passam de azul (v1) para verde (v2), misturadas durante
~30 s, **sem vermelho**. No terminal, a coluna de versões mostra `v1:6 v2:4` e depois
`v2:10`.

**Faça à mão:**
```bash
kubectl -n demo annotate deploy/web kubernetes.io/change-cause="v2: nova versão" --overwrite
kubectl -n demo set image deploy/web app=k8slab/web:v2
kubectl -n demo rollout status deploy/web
kubectl -n demo rollout history deploy/web
kubectl -n demo get rs          # o ReplicaSet da v1 fica com 0 réplicas, guardado para rollback
```

---

## Demo 4: versão defeituosa e rollback — `./demos/04-rollback.sh`

**Conceito.** A readinessProbe funciona como **barreira**: uma versão que nunca fica
pronta não substitui as que estão funcionando. O defeito fica contido no 1º pod novo.

**O que acontece**
1. `set image ... v3`. O pod v3 sobe, `/readyz` responde 503, ele morre após 8 s e entra
   em CrashLoopBackOff. Como `maxUnavailable: 0`, nenhum pod antigo é removido.
2. Após 60 s (`progressDeadlineSeconds`) a condição `Progressing` vira
   `False / ProgressDeadlineExceeded`, e `kubectl rollout status` termina com erro.
   É o sinal que um pipeline de CI/CD usaria para reverter.
3. `kubectl rollout undo` volta para a revisão anterior.

**Esperado na sonda:** **nenhuma falha** durante todo o processo.

**Importante para a apresentação:** o Kubernetes **para** o rollout, mas **não reverte
sozinho**. Rollback automático por métricas é o que fazem Argo Rollouts e Flagger
(implantações canário e blue-green).

```bash
kubectl -n demo get deploy web -o jsonpath='{range .status.conditions[*]}{.type}={.status} ({.reason}){"\n"}{end}'
kubectl -n demo rollout undo deploy/web                 # volta uma revisão
kubectl -n demo rollout undo deploy/web --to-revision=1 # ou para uma específica
```

---

## Demo 5: o mesmo, sem probes — `./demos/05-sem-probes.sh`

**Conceito.** Prova por contraste: a disponibilidade das demos 3 e 4 vem das probes e da
estratégia de rollout, não de mágica.

**O que acontece**
1. Remove as três probes (o próprio patch dispara um rollout). Sem readiness, o pod é
   "pronto" assim que o contêiner inicia, mas a app ainda leva 3 s aquecendo →
   **erros "conexão recusada"** durante o rollout.
2. Publica a v3 sem probes: cada pod v3 "fica pronto" na hora, os antigos são removidos
   e **o serviço inteiro cai** (503 e depois conexão recusada, em CrashLoop).
3. Reaplica o manifesto original (v1 com probes) e o serviço se recupera.

**Esperado na sonda:** vermelho nos passos 1 e 2; recuperação no 3. Bom para colocar lado
a lado com a demo 4 no relatório (mesma falha, com e sem probes).

---

## Demo 6: falha de nó — `./demos/06-falha-de-no.sh [nó]`

**Conceito.** Detector de falhas por **heartbeat + timeout** num sistema assíncrono:
não dá para distinguir um nó morto de um nó lento, então o sistema espera um prazo antes
de agir, e esse prazo é o tempo em que parte das requisições falha.

**O que acontece:** `docker pause` no worker com mais pods (congela kubelet,
contêineres, tudo). O script imprime a linha do tempo a cada 3 s.

| Tempo (aprox.) | Evento | Mecanismo | Na sonda |
|---|---|---|---|
| 0 s | nó congela | — | começam falhas (timeout) na fração do tráfego que ia para pods daquele nó |
| ~50 s | nó `Unknown`, taint `unreachable`, pods marcados não prontos | node lifecycle controller, `node-monitor-grace-period` (padrão 50 s) | **falhas param** (capacidade reduzida) |
| ~80 s | pods despejados (`Terminating`), substitutos criados em outros nós | taint `NoExecute` + `tolerationSeconds: 30` (padrão 300 s) | — |
| ~90 s | 4 réplicas prontas de novo | ReplicaSet controller + scheduler + kubelet | — |
| unpause | kubelet volta, vê que seus pods foram apagados e os encerra | reconciliação no kubelet | — |

**Por que os pods ficam `Terminating`?** O API server marcou a remoção, mas só o kubelet
daquele nó pode confirmar que os contêineres pararam. Enquanto o nó não responde, o pod
fica nesse estado. Para Deployments isso não importa (os substitutos já existem). Para
**StatefulSets** importa muito: o controlador não cria o substituto de `db-0` enquanto o
antigo não for confirmado como parado, para não haver duas cópias de uma identidade
(*at most one*). Esse é o caso em que o Kubernetes prefere **consistência** a
disponibilidade.

**Variante, partição em vez de travamento:**
```bash
chaos/no.sh partition k8slab-worker2   # o nó continua rodando, só isolado da rede
# ... observe ...
chaos/no.sh heal k8slab-worker2
```
Durante a partição, os pods de lá continuam **vivos** do outro lado. Depois do despejo,
existem por um tempo cópias antigas (isoladas) e substitutas. Ao curar a partição, o
kubelet encerra as antigas.

**Faça à mão:**
```bash
chaos/no.sh pause k8slab-worker2
kubectl get nodes -w                           # em outro terminal
kubectl describe node k8slab-worker2 | grep -A3 Taints
chaos/no.sh unpause k8slab-worker2
```

---

## Demo 7: manutenção planejada — `./demos/07-drain.sh [nó]`

**Conceito.** Falhas **voluntárias** (atualizar o SO de uma máquina) podem ser
coordenadas. O `PodDisruptionBudget` (`minAvailable: 3`) faz a API de *eviction*
recusar remoções que deixariam menos de 3 pods prontos.

**O que acontece:** `kubectl drain` = `cordon` (o nó deixa de receber pods novos) +
eviction de cada pod. Se o nó tem 2 réplicas, a 2ª espera o substituto da 1ª ficar
pronto (mensagens *Cannot evict pod as it would violate the pod's disruption budget*, e
o drain tenta de novo).

**Esperado na sonda:** nenhuma falha. Depois, `kubectl uncordon`. Os pods **não voltam**
sozinhos para o nó (o scheduler só decide onde colocar pods novos; rebalancear é papel
do projeto *descheduler*).

Próximo: [5. Experimentos do plano de controle](05-plano-de-controle.md)
