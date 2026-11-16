# Uma única receita gera as duas imagens do laboratório:
#   docker build --target web    --build-arg VERSION=v1 -t k8slab/web:v1 app/
#   docker build --target prober                        -t k8slab/prober  app/
# O binário Go é estático, então a imagem final parte de "scratch" (vazia):
# fica com poucos MB e sobe em milissegundos.

FROM golang:1.25-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY web ./web
COPY prober ./prober
ARG TARGETOS
ARG TARGETARCH
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath -ldflags="-s -w" -o /out/web ./web \
 && CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath -ldflags="-s -w" -o /out/prober ./prober

FROM scratch AS web
ARG VERSION=v1
ARG BROKEN=false
ENV APP_VERSION=$VERSION \
    BROKEN=$BROKEN
COPY --from=build /out/web /web
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/web"]

FROM scratch AS prober
COPY --from=build /out/prober /prober
USER 65532:65532
EXPOSE 8090
ENTRYPOINT ["/prober"]
