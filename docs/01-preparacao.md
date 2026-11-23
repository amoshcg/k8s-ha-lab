# 1. Preparação do ambiente

Você vai precisar de:

| Ferramenta | Versão testada | Para quê |
|---|---|---|
| Docker (Engine ou Desktop) | 24+ | cada nó do cluster é um contêiner |
| kind | v0.31.0 | cria o cluster Kubernetes dentro do Docker |
| kubectl | v1.35.x | cliente da API do Kubernetes |
| make, curl, bash | — | atalhos e scripts |
| Python 3 + matplotlib | opcional | análise dos resultados e gráficos |

**Recursos:** o cluster completo (6 nós) usa ~5–6 GB de RAM. Reserve 8 GB livres e 4
CPUs. Com menos, use a variante leve (`make lite`, 4 nós), que não permite os
experimentos de etcd e eleição de líderes.

---

## Linux (Ubuntu/Debian)

```bash
# Docker Engine
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker "$USER"        # depois saia e entre de novo na sessão
docker run --rm hello-world            # teste

# kind
ARCH=$(uname -m); [ "$ARCH" = x86_64 ] && ARCH=amd64; [ "$ARCH" = aarch64 ] && ARCH=arm64
curl -Lo kind "https://kind.sigs.k8s.io/dl/v0.31.0/kind-linux-${ARCH}"
chmod +x kind && sudo mv kind /usr/local/bin/

# kubectl
curl -LO "https://dl.k8s.io/release/v1.35.0/bin/linux/${ARCH}/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/

# utilitários
sudo apt-get install -y make curl python3-matplotlib
```

## macOS

1. Instale o **Docker Desktop** (ou OrbStack, ou Colima). No Docker Desktop, em
   *Settings → Resources*, dê pelo menos **8 GB de memória e 4 CPUs**.
   Com Colima: `colima start --cpu 4 --memory 8`.
2. Ferramentas (com [Homebrew](https://brew.sh)):
   ```bash
   brew install kind kubectl
   xcode-select --install   # traz make, se ainda não tiver
   ```
3. Opcional: `pip3 install matplotlib`.

Os scripts funcionam com o bash 3.2 que vem no macOS.

## Windows 10/11

Use o **WSL2**: todos os comandos rodam dentro do Ubuntu do WSL.

1. No PowerShell (administrador): `wsl --install -d Ubuntu` e reinicie.
2. Instale o **Docker Desktop** e, em *Settings → Resources → WSL integration*, ative a
   integração com a distribuição Ubuntu.
3. Limite de memória do WSL: crie `C:\Users\<você>\.wslconfig` com
   ```ini
   [wsl2]
   memory=10GB
   processors=4
   ```
   e rode `wsl --shutdown` para aplicar.
4. Dentro do Ubuntu, siga a seção **Linux** a partir do kind (o Docker já vem do Desktop).
5. Clone o repositório **dentro do sistema de arquivos do Linux** (`~/`), não em
   `/mnt/c/...`: é muito mais rápido e evita problemas de permissão.

Próximo: [2. O cluster por dentro](02-cluster.md)
