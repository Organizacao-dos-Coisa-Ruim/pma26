# Kubernetes

Manifests do sistema para o **kind** (cluster local, gratuito) e para o **EKS** (AWS).
Organizados com **Kustomize**, que já vem no `kubectl` (`kubectl apply -k`).

```
k8s/
├── base/                    igual nos dois ambientes
│   ├── account.yaml         Deployment + Service
│   ├── auth.yaml            Deployment + Service
│   ├── exchange.yaml        Deployment + Service
│   ├── product.yaml         Deployment + Service
│   ├── order.yaml           Deployment + Service
│   ├── gateway.yaml         Deployment + Service + HPA
│   ├── redis.yaml           Deployment + Service (cache do Exchange)
│   ├── namespace.yaml       namespace pma26
│   └── kustomization.yaml   ConfigMap (URLs, TTL...) e enableServiceLinks: false
├── overlays/
│   ├── kind/                Postgres no cluster, imagens locais, gateway em localhost:8080
│   └── eks/                 RDS, imagens do Docker Hub, gateway com LoadBalancer; up.sh/down.sh criam e destroem a AWS
└── addons/
    └── metrics-server/      CPU/memória dos pods, necessário para o HPA
```

## Rodar no kind

Pré-requisitos: Docker, `kubectl` e [kind](https://kind.sigs.k8s.io/) (`winget install Kubernetes.kind`).
Não suba junto com o compose: os dois usam a porta 8080.

```bash
# 1. imagens dos serviços (o compose builda todas)
docker compose -f docker/compose.yml build

# 2. cluster com a porta 8080 ligada ao gateway
kind create cluster --name pma26 --config k8s/overlays/kind/kind-cluster.yaml
kind load docker-image gateway auth account exchange product order --name pma26

# 3. segredos (pode copiar os valores do docker/.env)
cp k8s/overlays/kind/secrets.env.example k8s/overlays/kind/secrets.env   # e preencha

# 4. metrics-server (uma vez por cluster) e o sistema
kubectl apply -k k8s/addons/metrics-server
kubectl apply -k k8s/overlays/kind
kubectl -n pma26 get pods -w        # esperar todos 1/1 Running (~2 min)
```

O gateway fica em http://localhost:8080, como no compose. Testes:

```bash
set -a; . docker/.env; set +a
./docker/smoke-test.sh

# os scripts que rodam em container precisam da rede e do endereço do kind
export NETWORK=kind GATEWAY_INTERNAL=http://pma26-control-plane:30080
./docker/load-exchange.sh 500 10 USD/BRL
./docker/zap-scan.sh zap-report
```

Depois de mudar o código de um serviço: rebuildar a imagem, `kind load docker-image <serviço> --name pma26`
e `kubectl -n pma26 rollout restart deploy/<serviço>`.

**Derrubar:** `kind delete cluster --name pma26`.

## HPA (load test)

O gateway escala de 1 a 10 pods mantendo a CPU média em 50% do `request` (250m). Para ver escalar:

```bash
kubectl -n pma26 get hpa gateway -w          # num terminal

# noutro: 2 minutos de carga com 50 conexões
TOKEN=$(curl -s -X POST localhost:8080/auth/login -H 'Content-Type: application/json' \
  -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASSWORD\"}" | sed -n 's/.*"jwt":"\([^"]*\)".*/\1/p')
docker run --rm --network kind williamyeh/hey -z 120s -c 50 \
  -H "Authorization: Bearer $TOKEN" http://pma26-control-plane:30080/exchange/USD/BRL
```

Sem carga, o HPA espera 5 minutos estável antes de reduzir as réplicas (evita ficar subindo e descendo).

## Decisões

| Decisão | Por quê |
|---------|---------|
| Nomes `gateway`, `auth`, `account`, `exchange`, `product`, `order` | iguais ao compose, à imagem e ao que o HPA e o load test usam |
| `requests` de CPU e memória em todo Deployment | o HPA mede a CPU como % do `request`; sem ele, não escala |
| `startupProbe` + `readinessProbe` + `livenessProbe` em `/actuator/health/*` | a JVM demora a subir (até 150 s de tolerância); o Service só manda tráfego para pod pronto; pod travado é reiniciado |
| `enableServiceLinks: false` | o Kubernetes injetaria `REDIS_PORT=tcp://10.96.x.x:6379`, que colide com a variável `REDIS_PORT` do exchange (o pod não subia) |
| `JAVA_TOOL_OPTIONS=-XX:MaxRAMPercentage=75` | a JVM usa até 75% do limite de memória do container (o padrão é 25%) |
| `imagePullPolicy: IfNotPresent` | sem tag, a imagem é `latest`, e o padrão seria sempre baixar do registry; no kind ela é carregada localmente |
| ConfigMap e Secret gerados pelo Kustomize | o nome ganha um hash do conteúdo: mudar uma configuração reinicia os pods sozinho |
| Segredos em `secrets.env` fora do git | mesmo esquema do `docker/.env` |
| Postgres no cluster só no kind | no EKS o banco é o RDS; o Redis fica no cluster nos dois (é só cache, não precisa de serviço gerenciado) |

## Validação (kind, 2026-11-15)

- Todos os pods `Running` e `Ready`.
- `docker/smoke-test.sh`: 20 cenários OK, inclusive cotação real e RBAC.
- `docker/zap-scan.sh`: 0 alertas, 120 regras passando (mesmo resultado do compose).
- HPA: com 50 conexões contínuas, o gateway foi de 2 para 10 pods em ~90 s
  (eventos `SuccessfulRescale`: 2 → 3 → 4 → 8 → 10). Sem carga, voltou a 1 (10 → 3 → 1,
  "All metrics below target") depois dos 5 minutos de estabilização.

## Ainda não incluído

- Prometheus e Grafana no cluster (continuam no compose).
- Product e Order (o gateway já tem as rotas; falta criar os serviços).
- Overlay do EKS testado de verdade (depende do cluster, #51–#60).
