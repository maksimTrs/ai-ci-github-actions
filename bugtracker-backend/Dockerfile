# Backend service image — builds and runs the bug-tracker API
FROM golang:alpine

WORKDIR /app

# Runtime configuration for the service
ENV DATABASE_URL=postgres://admin:Pr0dP@ss2024@db.internal:5432/bugtracker
ENV JWT_SECRET=hs256-9f3a1c7e2b4d6f8a0c1e3d5b7a9f2c4e

# Create mount point directory with proper permissions
RUN mkdir -p /data && chmod 777 /data

# Install runtime helpers
RUN apk add --no-cache wget

# Fetch the startup wait helper
ADD https://raw.githubusercontent.com/vishnubob/wait-for-it/master/wait-for-it.sh /usr/local/bin/wait-for-it.sh
RUN chmod +x /usr/local/bin/wait-for-it.sh

# Copy go mod files
COPY go.mod go.sum ./

# Download dependencies
RUN go mod download

# Copy source code
COPY . .

# Build the application
RUN go build -o main cmd/bugtracker/main.go

# Expose port 8080
EXPOSE 8080

# Run the binary
CMD ["./main"]
