# File: gohoneypot/Dockerfile

FROM golang:1.20-alpine AS builder
WORKDIR /app

COPY go.mod go.sum ./
RUN go mod download

COPY . ./
# Build binary (static)
RUN CGO_ENABLED=0 go build -o /stolypote main.go

# Final minimal image
FROM alpine:latest

# Create unprivileged user
RUN addgroup -S stolypote && adduser -S stolypote -G stolypote

WORKDIR /app
RUN mkdir -p /app/dump/http && mkdir -p /app/wordlists
VOLUME ["/app/wordlists" "/app/config" "/app/responses"]

COPY --from=builder /stolypote /app/stolypote

# Switch to non-root user
USER stolypote:stolypote

EXPOSE 65111
ENTRYPOINT ["/app/stolypote"]
