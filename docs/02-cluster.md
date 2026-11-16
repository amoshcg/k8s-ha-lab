# 2. O cluster por dentro

## 2.1 Criar o cluster

```bash
git clone <seu-repositório> k8s-ha-lab && cd k8s-ha-lab
make cluster          # ~3 a 5 minutos na primeira vez (baixa a imagem do nó)
```

O `kind` lê [`cluster/kind-ha.yaml`](../cluster/kind-ha.yaml) e:

1. cria 6 contêineres Docker, um por nó, todos na rede Docker `kind`;
2. roda `kubeadm init` no primeiro control plane e `kubeadm join` nos demais;
3. cria um 7º contêiner, `k8slab-external-load-balancer` (HAProxy), na frente dos três
   kube-apiservers. É o endereço que o `kubectl` usa;
4. instala o CNI (kindnet), o CoreDNS e um provisionador de volumes local.

O script ainda copia o `etcdctl` para os control planes, para conseguirmos consultar o
etcd mesmo quando a API estiver fora do ar.

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
kubectl get nodes -o wide
```

> Todos os scripts usam `kubectl --context kind-k8slab`, então não interferem em outros
> clusters do seu kubeconfig. Nos comandos manuais deste guia, confira com
> `kubectl config current-context` (o kind já deixa `kind-k8slab` como atual).

## 2.2 Quem é quem

```bash
kubectl -n kube-system get pods -o wide
```

| Componente | Onde roda | Papel | Estado? |
|---|---|---|---|
| **etcd** | 3 control planes | banco chave-valor replicado com **Raft**; guarda TODO o estado do cluster | sim, o único |
| **kube-apiserver** | 3 control planes | única porta de entrada: autentica, autoriza, valida, grava no etcd e oferece *watch* | não (escala horizontalmente) |
| **kube-scheduler** | 3 control planes, **1 ativo** | escolhe um nó para cada pod sem nó | não |
| **kube-controller-manager** | 3 control planes, **1 ativo** | dezenas de controladores (Deployment, ReplicaSet, Node, EndpointSlice, ...) | não |
| **kubelet** | todos os nós (processo do sistema) | executa os pods do seu nó, roda as probes e reporta o status | não |
| **kube-proxy** | todos os nós (DaemonSet) | programa as regras de rede dos Services | não |
| kindnet, CoreDNS | DaemonSet / Deployment | rede entre pods e DNS interno | não |

Duas ideias organizam tudo isso:

1. **Só o kube-apiserver fala com o etcd.** Os demais componentes leem e escrevem
   objetos pela API e recebem notificações de mudança (*watch*). Não há chamadas diretas
   entre scheduler, controllers e kubelets.
2. **Controle por reconciliação** (*level-triggered*). Cada controlador observa o estado
   desejado (`spec`) e o atual (`status`) e age para aproximá-los, repetidamente. Se
   perder um evento ou reiniciar, basta reler o estado. Por isso o sistema tolera falhas
   dos próprios componentes de controle.

Escritas concorrentes usam **concorrência otimista**: cada objeto tem um
`resourceVersion` (derivado da revisão do etcd). Se dois clientes alteram a mesma
versão, o segundo recebe `409 Conflict` e tenta de novo.

```bash
# um objeto e sua versão
kubectl -n kube-system get lease kube-scheduler -o jsonpath='{.metadata.resourceVersion}{"\n"}'
# watch "cru": a conexão fica aberta e cada mudança chega como uma linha JSON (Ctrl+C sai)
kubectl get --raw '/api/v1/namespaces/kube-system/pods?watch=1' | cut -c1-150
```

## 2.3 Static pods: como o plano de controle sobe antes da API

O kube-apiserver não pode ser criado pela própria API. Os quatro componentes do plano de
controle são **static pods**: arquivos YAML que o kubelet do nó lê direto do disco.

```bash
docker exec k8slab-control-plane ls /etc/kubernetes/manifests
# etcd.yaml  kube-apiserver.yaml  kube-controller-manager.yaml  kube-scheduler.yaml
docker exec k8slab-control-plane crictl ps     # contêineres rodando dentro do "nó"
```

Tirar um desses arquivos da pasta faz o kubelet encerrar o componente. Devolver faz o
kubelet recriá-lo. É assim que `chaos/componente.sh stop|start` funciona.

## 2.4 etcd e o consenso Raft

```bash
make status
```

mostra algo como:

```
MEMBRO DO ETCD             PAPEL          TERM   ÍNDICE RAFT
k8slab-control-plane       seguidor       2      1532
k8slab-control-plane2      LÍDER          2      1532
k8slab-control-plane3      seguidor       2      1532
```

- **Líder:** recebe todas as escritas e as replica para os seguidores. Uma escrita só é
  confirmada (*committed*) quando a **maioria** a gravou.
- **TERM:** número do mandato. Cada eleição incrementa o term. Um líder antigo que volte
  com term menor é ignorado.
- **ÍNDICE:** posição no log replicado. Membros saudáveis têm índices iguais ou quase.
- **Eleição:** o líder manda *heartbeats* a cada 100 ms (padrão do etcd). Um seguidor
  que fica ~1 s sem recebê-los (*election timeout*, com aleatoriedade para evitar
  empates) vira candidato e pede votos. Precisa da maioria para vencer.

| Membros | Maioria (quórum) | Falhas toleradas |
|---|---|---|
| 1 | 1 | 0 |
| 3 | 2 | 1 |
| 5 | 3 | 2 |

Por isso o número de membros é ímpar: 4 membros toleram as mesmas 1 falha que 3.

> Nesta topologia (*stacked etcd*, padrão do kubeadm), cada kube-apiserver conversa
> **só com o etcd do próprio nó** (`--etcd-servers=https://127.0.0.1:2379`). Se o etcd
> de um nó para, o apiserver daquele nó também deixa de funcionar, e o HAProxy precisa
> tirá-lo do balanceamento. A demo 10 mostra esse efeito.

## 2.5 Eleição de líder com Lease

Rodar 3 schedulers ativos ao mesmo tempo causaria decisões conflitantes. Então os três
disputam um objeto **Lease** na API, e só quem o detém trabalha (ativo-passivo):

```bash
kubectl -n kube-system get lease kube-scheduler kube-controller-manager
kubectl -n kube-system get lease kube-scheduler -o yaml
```

- `holderIdentity`: o dono atual (nome do nó + identificador do processo)
- `leaseDurationSeconds: 15`: se o dono não renovar em 15 s, outro pode tomar
- `renewTime`: atualizado a cada ~2 s pelo líder

A exclusão mútua é garantida pela concorrência otimista da API (o `resourceVersion`
acima), que por sua vez se apoia na ordenação total do etcd.

## 2.6 Heartbeats dos nós

Cada kubelet também mantém uma Lease, no namespace `kube-node-lease`, renovada a cada
10 s. É o "estou vivo" do nó:

```bash
kubectl -n kube-node-lease get lease
```

O **node lifecycle controller** (no kube-controller-manager) vigia essas Leases. Se um nó
passa do `node-monitor-grace-period` (50 s por padrão) sem renovar, ele é marcado como
`Unknown`, recebe o taint `node.kubernetes.io/unreachable` e seus pods deixam de ser
considerados prontos. É um **detector de falhas por timeout**: não distingue um nó morto
de um nó lento ou isolado na rede. A demo 6 mede esse tempo.

## 2.7 O caminho de um `kubectl apply`

```
kubectl apply ─► kube-apiserver ─► etcd (grava o Deployment)
                       │ watch
     Deployment controller ─► cria ReplicaSet ─► etcd
                       │ watch
     ReplicaSet controller ─► cria 4 Pods (sem nó) ─► etcd
                       │ watch
     kube-scheduler ─► filtra e pontua os nós ─► grava o Binding (pod.spec.nodeName)
                       │ watch
     kubelet do nó escolhido ─► containerd sobe o contêiner ─► probes ─► status Ready
                       │ watch
     EndpointSlice controller ─► adiciona o pod ao Service ─► kube-proxy programa a rede
```

Nenhuma seta é uma chamada direta entre componentes: todos escrevem na API e reagem ao
que leem dela.

Próximo: [3. Aplicação e sonda](03-aplicacao-e-sonda.md)
