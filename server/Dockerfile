# syntax=docker/dockerfile:1
FROM --platform=$BUILDPLATFORM golang:1.23-alpine AS build
ARG TARGETOS=linux
ARG TARGETARCH
WORKDIR /src
COPY go.mod ./
COPY *.go ./
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath -ldflags="-s -w" -o /appvault-server .

FROM scratch
LABEL org.opencontainers.image.source="https://github.com/Sausagerolls/AppVault" \
      org.opencontainers.image.description="AppVault server: stores macOS apps offloaded from your Mac" \
      net.unraid.docker.icon="https://raw.githubusercontent.com/Sausagerolls/AppVault/main/server/unraid/appvault-icon.png"
COPY --from=build /appvault-server /appvault-server
ENV APPVAULT_DATA=/data \
    APPVAULT_PORT=8420
VOLUME /data
EXPOSE 8420
HEALTHCHECK --interval=60s --timeout=5s --start-period=10s CMD ["/appvault-server", "healthcheck"]
ENTRYPOINT ["/appvault-server"]
