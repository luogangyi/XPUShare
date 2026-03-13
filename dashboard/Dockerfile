FROM golang:1.22 AS builder

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 go build -o /out/xpushare-dashboard ./main.go

FROM alpine:3.20
RUN apk add --no-cache ca-certificates
COPY --from=builder /out/xpushare-dashboard /usr/local/bin/xpushare-dashboard
ENTRYPOINT ["/usr/local/bin/xpushare-dashboard"]
