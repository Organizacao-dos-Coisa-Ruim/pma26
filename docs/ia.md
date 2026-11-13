# Registro de uso de IA

Exigência do curso: declarar quais partes foram feitas com auxílio de IA e quais foram feitas pelos integrantes. Todo integrante deve conseguir explicar e defender qualquer parte, inclusive as feitas com IA.

| Data | Repositório / arquivos | Ferramenta | O que a IA fez | O que o grupo fez |
|------|------------------------|------------|----------------|-------------------|
| 2026-11-13 | `pma26`: `RUBRICA.md`, `CLAUDE.md` | Claude Code | Resumiu o enunciado do projeto e escreveu as convenções do repositório | Definiu o escopo (e-commerce em microsserviços) e revisou os arquivos |
| 2026-11-13 | Kanban do GitHub (issues #1–#96 do `pma26`) | Claude Code | Montou o backlog: tasks por serviço/entrega, subtasks, tamanho e prioridade | Definiu o critério de prioridade e a estrutura (uma task por microsserviço + deploy/CI/CD) |
| 2026-11-13 | `gateway-service`: todo o código (rotas, `AuthorizationFilter`, `RouterValidator`, `AuthService`, `GatewayResource`, testes, Dockerfile, README) | Claude Code | Implementou o gateway e os testes a pedido do grupo | Pediu a implementação; revisão do PR pendente |
| 2026-11-13 | `pma-26-account` (interface: endpoint `login`, `LoginIn`, `create` devolvendo a conta, pom como lib) e `pma26-account-service` (todo o código: Model, Repository, Service, Resource, Parser, BCrypt, migration Flyway, Dockerfile, testes, README); `pma26`: URL do submodule `api/account` | Claude Code | Implementou o serviço de contas (issue #9 e subtasks #10–#16) a pedido do grupo | Pediu a implementação; revisão do PR pendente |
