# syntax=docker/dockerfile:1
#
# Dockerfile genérico usado pelo compose para buildar qualquer serviço Java a partir do código-fonte.
# O contexto de build é a pasta api/ (todos os submodules), porque um service precisa
# instalar antes as interfaces de que depende (ex.: auth-service usa auth e account).
#
#   INTERFACES: pastas das interfaces a instalar, separadas por espaço (ex.: "auth account")
#   SERVICE:    pasta do service a empacotar (ex.: "auth-service")
#
# Usa o Maven da imagem (e não o ./mvnw) para não depender do fim de linha dos scripts no Windows.

FROM maven:3.9-eclipse-temurin-21 AS build
ARG INTERFACES=""
ARG SERVICE
WORKDIR /src
COPY . .
# o cache do ~/.m2 é compartilhado entre os builds: as dependências só baixam na primeira vez
RUN --mount=type=cache,target=/root/.m2,sharing=locked \
    for i in $INTERFACES; do mvn -B -q -f "$i/pom.xml" install -DskipTests || exit 1; done \
    && mvn -B -q -f "$SERVICE/pom.xml" package -DskipTests \
    && cp "$SERVICE"/target/*-SNAPSHOT.jar /app.jar

FROM eclipse-temurin:21-jre
WORKDIR /app
COPY --from=build /app.jar app.jar
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "app.jar"]
