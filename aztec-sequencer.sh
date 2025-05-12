#!/bin/bash
set -e

echo "Installing Sepolia Execution, Consensus, Aztec Node and monitoring..."

# === Setup variables ===
INSTALL_DIR="aztec-sequencer"
mkdir -p $INSTALL_DIR && cd $INSTALL_DIR

echo "Please provide the following information:"
read -p "Enter Ethereum PRIVATE KEY: " VALIDATOR_PRIVATE_KEY
read -p "Enter Ethereum ADDRESS (0x...): " VALIDATOR_ADDRESS
echo ""

# JWT for Geth <-> Lighthouse communication
mkdir -p jwt
openssl rand -hex 32 > jwt/jwt.hex
echo "JWT generated"

# Get public IP for P2P communications
P2P_IP=$(curl -s ipv4.icanhazip.com)
echo "Your public IP: $P2P_IP"

# === Install Docker if not present ===
if ! command -v docker &> /dev/null; then
    echo "Installing Docker..."
    apt update
    apt install -y curl gnupg apt-transport-https ca-certificates software-properties-common
    
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker.gpg] \
      https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
      tee /etc/apt/sources.list.d/docker.list
    
    apt update
    apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    systemctl enable docker && systemctl restart docker
else
    echo "Docker already installed, skipping..."
fi

# === Create docker-compose.yml ===
cat <<EOF > docker-compose.yml
version: "3.8"
services:

  execution:
    image: ethereum/client-go:stable
    container_name: geth
    volumes:
      - ./geth-data:/root/.ethereum
      - ./jwt/jwt.hex:/root/jwt.hex
    command: >
      --sepolia
      --http
      --http.api eth,net,web3,txpool
      --http.addr 0.0.0.0
      --http.vhosts "*"
      --authrpc.jwtsecret /root/jwt.hex
      --authrpc.addr 0.0.0.0
      --metrics --metrics.addr 0.0.0.0 --metrics.port 6060
    ports:
      - "8545:8545"
      - "8551:8551"
      - "6060:6060"
    restart: unless-stopped

  consensus:
    image: sigp/lighthouse:latest
    container_name: lighthouse
    command: >
      lighthouse bn
      --network sepolia
      --execution-endpoint http://execution:8551
      --execution-jwt /root/jwt.hex
      --checkpoint-sync-url https://sepolia.beaconstate.info
      --metrics
    volumes:
      - ./lighthouse-data:/root/.lighthouse
      - ./jwt/jwt.hex:/root/jwt.hex
    ports:
      - "5052:5052"
      - "5054:5054"
    depends_on:
      - execution
    restart: unless-stopped

  aztec-node:
    image: aztecprotocol/aztec:0.85.0-alpha-testnet.8
    container_name: aztec-sequencer
    network_mode: host
    environment:
      ETHEREUM_HOSTS: http://127.0.0.1:8545
      L1_CONSENSUS_HOST_URLS: http://127.0.0.1:5052
      VALIDATOR_PRIVATE_KEY: ${VALIDATOR_PRIVATE_KEY}
      VALIDATOR_ADDRESS: ${VALIDATOR_ADDRESS}
      P2P_IP: ${P2P_IP}
      LOG_LEVEL: debug
    entrypoint: >
      sh -c 'node --no-warnings /usr/src/yarn-project/aztec/dest/bin/index.js start --network alpha-testnet --node --archiver --sequencer'
    volumes:
      - ./aztec-data:/root/.aztec
    restart: unless-stopped

  prometheus:
    image: prom/prometheus:latest
    container_name: prometheus
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml
    ports:
      - "9090:9090"
    restart: unless-stopped

  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    ports:
      - "3000:3000"
    volumes:
      - grafana-storage:/var/lib/grafana
    restart: unless-stopped

volumes:
  grafana-storage:
  geth-data:
  lighthouse-data:
  aztec-data:
EOF

# === Setup Prometheus ===
cat <<EOF > prometheus.yml
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: "geth"
    static_configs:
      - targets: ["execution:6060"]
  
  - job_name: "lighthouse"
    static_configs:
      - targets: ["consensus:5054"]
EOF

# === Setup cron job ===
CRON_CMD="docker exec -it aztec-sequencer node /usr/src/yarn-project/aztec/dest/bin/index.js add-l1-validator --l1-rpc-urls http://127.0.0.1:8545 --private-key ${VALIDATOR_PRIVATE_KEY} --attester ${VALIDATOR_ADDRESS} --proposer-eoa ${VALIDATOR_ADDRESS} --staking-asset-handler 0xF739D03e98e23A7B65940848aBA8921fF3bAc4b2 --l1-chain-id 11155111"

# Create cron script
cat <<EOF > validator_cron.sh
#!/bin/bash
cd $PWD
export VALIDATOR_PRIVATE_KEY=$VALIDATOR_PRIVATE_KEY
export VALIDATOR_ADDRESS=$VALIDATOR_ADDRESS
$CRON_CMD
EOF

chmod +x validator_cron.sh

# Add cron job to run daily at 21:49:12 UTC
(crontab -l 2>/dev/null || echo "") | grep -v "validator_cron.sh" | { cat; echo "12 49 21 * * $PWD/validator_cron.sh >> $PWD/validator_cron.log 2>&1"; } | crontab -

echo "Cron job set to run daily at 21:49:12 UTC"

# === Launch everything ===
echo "Starting all containers..."
docker compose up -d

# === Info ===
echo "Setup completed!"
echo ""
echo "Prometheus: http://${P2P_IP}:9090"
echo "Grafana: http://${P2P_IP}:3000 (login: admin / admin)"
echo "To check logs: docker compose logs --tail 100 -f"
