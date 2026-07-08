# --- Build stage: has Python/gcc/make needed to compile better-sqlite3's native module ---
FROM node:20-slim AS builder

RUN apt-get update && \
    apt-get install -y --no-install-recommends python3 make g++ && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev

# --- Final stage: clean slim image, no build tools, just the finished node_modules ---
FROM node:20-slim

WORKDIR /app
COPY --from=builder /app/node_modules ./node_modules
COPY . .

VOLUME ["/app/data"]

CMD ["node", "src/index.js"]
