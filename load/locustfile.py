"""
Teste de carga do pma26 pelo gateway (rubrica: Load Testing + HPA).

Antes da carga (test_start), o admin cria um catálogo de produtos: depois do RBAC, só admin cria
produto. No fim (test_stop), o admin apaga esses produtos. Por isso o teste precisa de ADMIN_EMAIL e
ADMIN_PASSWORD (os mesmos do docker/.env ou do secrets.env do Kubernetes).

Cada usuário virtual do Locust faz o que um cliente da loja faria:
  1. ao entrar: cria uma conta (POST /auth/register) e faz login (POST /auth/login) -> guarda o JWT;
  2. depois, em loop, com uma pausa de 0,5 a 1,5 s entre as ações:
     - navega no catálogo        (GET /products)          peso 4
     - consulta uma cotação      (GET /exchange/{par})    peso 2
     - faz um pedido             (POST /orders)           peso 1  -> o Order busca o preço no Product (Feign)
     - consulta os seus pedidos  (GET /orders)            peso 1
     - consulta a própria conta  (GET /accounts/{id})     peso 1

Toda requisição autenticada passa pelo filtro do gateway, que chama o Auth (/auth/solve) para validar
o token. Por isso o gateway é o deployment que mais gasta CPU e é ele que o HPA escala.

A forma da carga (quantos usuários em cada momento) está em StagesShape, no fim do arquivo.
Rodar: load/run.sh (sobe o Locust em container, sem instalar nada).
"""
import base64
import json
import logging
import os
import random
import uuid

import requests
from locust import HttpUser, LoadTestShape, between, events, task

# Pares consultados. Poucos pares de propósito: com o cache Redis (TTL 5 min), a AwesomeAPI recebe
# no máximo 1 chamada por par a cada 5 minutos, por maior que seja a carga.
PAIRS = ["USD/BRL", "EUR/BRL", "BTC/BRL"]

# Catálogo criado pelo admin no início do teste: (nome, preço, unidade)
CATALOGO = [
    ("Tomate", 10.12, "kg"),
    ("Caneca", 19.99, "un"),
    ("Caderno", 12.50, "un"),
    ("Café", 32.90, "kg"),
    ("Queijo", 54.00, "kg"),
]
PRODUCT_IDS = []  # preenchido no test_start, lido pelos usuários
ADMIN = {}        # headers do admin, para apagar o catálogo no test_stop


def jwt_subject(token: str) -> str:
    """Lê o campo 'sub' (id da conta) do payload do JWT, sem validar a assinatura."""
    payload = token.split(".")[1]
    payload += "=" * (-len(payload) % 4)  # base64url sem padding
    return json.loads(base64.urlsafe_b64decode(payload))["sub"]


@events.test_start.add_listener
def criar_catalogo(environment, **kwargs):
    """O admin cria os produtos que os usuários vão comprar (fora da medição do Locust)."""
    email, senha = os.getenv("ADMIN_EMAIL"), os.getenv("ADMIN_PASSWORD")
    if not email or not senha:
        logging.error("Defina ADMIN_EMAIL e ADMIN_PASSWORD: só o admin cria produtos (RBAC).")
        environment.runner.quit()
        return
    host = environment.host
    resp = requests.post(f"{host}/auth/login", json={"email": email, "password": senha}, timeout=10)
    if resp.status_code != 200:
        logging.error("Login do admin falhou (%s): confira ADMIN_EMAIL/ADMIN_PASSWORD.", resp.status_code)
        environment.runner.quit()
        return
    ADMIN["Authorization"] = f"Bearer {resp.json()['jwt']}"
    PRODUCT_IDS.clear()
    for nome, preco, unidade in CATALOGO:
        r = requests.post(f"{host}/products", headers=ADMIN, timeout=10,
                          json={"name": f"{nome} (load test)", "price": preco, "unit": unidade})
        if r.status_code == 201:
            PRODUCT_IDS.append(r.json()["id"])
    logging.info("Catálogo do load test: %d produtos criados.", len(PRODUCT_IDS))
    if not PRODUCT_IDS:
        logging.error("Nenhum produto criado: o teste para aqui.")
        environment.runner.quit()


@events.test_stop.add_listener
def apagar_catalogo(environment, **kwargs):
    """Apaga os produtos criados no início, para não poluir o catálogo."""
    for product_id in PRODUCT_IDS:
        requests.delete(f"{environment.host}/products/{product_id}", headers=ADMIN, timeout=10)
    logging.info("Catálogo do load test apagado (%d produtos).", len(PRODUCT_IDS))


class Cliente(HttpUser):
    wait_time = between(0.5, 1.5)

    def on_start(self):
        email = f"load-{uuid.uuid4().hex[:12]}@pma26.local"
        senha = "load-test-123"
        self.client.post("/auth/register", json={"name": "Load Test", "email": email, "password": senha},
                         name="/auth/register")
        with self.client.post("/auth/login", json={"email": email, "password": senha},
                              name="/auth/login", catch_response=True) as resp:
            if resp.status_code != 200:
                resp.failure(f"login falhou: {resp.status_code}")
                self.stop()  # sem token o usuário não tem o que fazer
                return
            token = resp.json()["jwt"]
        self.account_id = jwt_subject(token)
        self.client.headers["Authorization"] = f"Bearer {token}"

    @task(4)
    def catalogo(self):
        self.client.get("/products", name="/products")

    @task(2)
    def cotacao(self):
        # name agrupa as URLs no relatório (senão cada par vira uma linha)
        self.client.get(f"/exchange/{random.choice(PAIRS)}", name="/exchange/{par}")

    @task(1)
    def pedido(self):
        # 1 a 3 produtos diferentes do catálogo, com quantidade de 1 a 3
        itens = [{"productId": pid, "quantity": random.randint(1, 3)}
                 for pid in random.sample(PRODUCT_IDS, k=random.randint(1, min(3, len(PRODUCT_IDS))))]
        self.client.post("/orders", json={"items": itens}, name="/orders [POST]")

    @task(1)
    def meus_pedidos(self):
        self.client.get("/orders", name="/orders [GET]")

    @task(1)
    def minha_conta(self):
        self.client.get(f"/accounts/{self.account_id}", name="/accounts/{id}")


class StagesShape(LoadTestShape):
    """
    Carga em degraus, para o vídeo mostrar o HPA subindo e descendo:

      0:00-1:00  sobe até 20 usuários   (aquecimento: a JVM compila o código quente)
      1:00-3:00  50 usuários            (passa dos 50% de CPU: HPA começa a criar pods)
      3:00-7:00  100 usuários           (pico: HPA chega perto do máximo)
      7:00-8:00  10 usuários            (carga cai; o HPA espera 5 min estável antes de reduzir)

    Duração total configurável: LOAD_SCALE=0.5 deixa tudo com metade do tempo (teste rápido).
    Usuários do pico configuráveis: LOAD_PEAK=200.
    """
    scale = float(os.getenv("LOAD_SCALE", "1"))
    peak = int(os.getenv("LOAD_PEAK", "100"))

    # (fim do degrau em segundos, usuários, usuários criados por segundo)
    stages = [
        (60, 20, 1),
        (180, peak // 2, 2),
        (420, peak, 5),
        (480, 10, 10),
    ]

    def tick(self):
        t = self.get_run_time()
        for fim, usuarios, taxa in self.stages:
            if t < fim * self.scale:
                return usuarios, taxa
        return None  # acabou: o Locust para
