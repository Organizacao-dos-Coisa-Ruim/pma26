"""
Teste de carga do pma26 pelo gateway (rubrica: Load Testing + HPA).

Cada usuário virtual do Locust faz o que um cliente real faria:
  1. ao entrar: cria uma conta (POST /auth/register) e faz login (POST /auth/login) -> guarda o JWT;
  2. depois, em loop, com uma pausa de 0,5 a 1,5 s entre as ações:
     - consulta cotações (GET /exchange/{de}/{para})  peso 3
     - consulta a própria conta (GET /accounts/{id})  peso 1

Toda requisição autenticada passa pelo filtro do gateway, que chama o Auth (/auth/solve) para validar
o token. Por isso o gateway é o deployment que mais gasta CPU e é ele que o HPA escala.

A forma da carga (quantos usuários em cada momento) está em StagesShape, no fim do arquivo.
Rodar: load/run.sh (sobe o Locust em container, sem instalar nada).
"""
import base64
import json
import os
import random
import uuid

from locust import HttpUser, LoadTestShape, between, task

# Pares consultados. Poucos pares de propósito: com o cache Redis (TTL 5 min), a AwesomeAPI recebe
# no máximo 1 chamada por par a cada 5 minutos, por maior que seja a carga.
PAIRS = ["USD/BRL", "EUR/BRL", "BTC/BRL"]


def jwt_subject(token: str) -> str:
    """Lê o campo 'sub' (id da conta) do payload do JWT, sem validar a assinatura."""
    payload = token.split(".")[1]
    payload += "=" * (-len(payload) % 4)  # base64url sem padding
    return json.loads(base64.urlsafe_b64decode(payload))["sub"]


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

    @task(3)
    def cotacao(self):
        # name agrupa as URLs no relatório (senão cada par vira uma linha)
        self.client.get(f"/exchange/{random.choice(PAIRS)}", name="/exchange/{par}")

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
