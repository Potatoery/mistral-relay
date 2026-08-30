# Use the official Swift Docker image
FROM swift:5.9-jammy as builder

# Set working directory
WORKDIR /app

# Copy package files
COPY Package.swift ./
COPY Sources/ ./Sources/

# Resolve dependencies
RUN swift package resolve

# Build the release
RUN swift build -c release --static-swift-stdlib

# Use a slim runtime image
FROM ubuntu:22.04

# Install required dependencies for Vapor
RUN apt-get update && apt-get install -y \
    libatomic1 \
    libssl3 \
    libuuid1 \
    libcurl4 \
    libsqlite3-0 \
    libnghttp2-14 \
    tzdata \
    && rm -rf /var/lib/apt/lists/*

# Copy built application
WORKDIR /app
COPY --from=builder /app/.build/release/Run .

# Expose port
EXPOSE 8080

# Run the application
CMD ["./Run"]
