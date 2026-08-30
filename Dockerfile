FROM golang:1.25.14

WORKDIR /app

COPY go.mod go.sum ./
RUN go mod download

RUN apt update && apt install -y iputils-ping vim

COPY . .
RUN go build -o /usr/local/bin/taskmasterd cmd/server/main.go
RUN go build -o /usr/local/bin/taskmasterctl cmd/client/main.go

RUN useradd "taskmaster"


CMD [ "taskmasterd" ]
