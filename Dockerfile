# Stage 1: Build static Go binary
FROM golang:1.23-alpine AS builder

RUN apk add --no-cache git ca-certificates tzdata

WORKDIR /src

COPY go.mod ./
# If go.sum exists copy it
COPY go.sum* ./
RUN go mod download || true

COPY . .

RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-w -s" -o /app/varta-server ./cmd/server

# Stage 2: Minimal runtime image
FROM alpine:3.20

RUN apk add --no-cache ca-certificates tzdata curl

WORKDIR /app

COPY --from=builder /app/varta-server /app/varta-server
COPY migrations /app/migrations

RUN addgroup -S varta && adduser -S varta -G varta && chown -R varta:varta /app

USER varta

EXPOSE 3047

ENTRYPOINT ["/app/varta-server"]
