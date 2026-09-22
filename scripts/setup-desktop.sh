#!/usr/bin/env bash
set -e

echo "=================================================="
echo "    CONFIGURATION BUREAU MODERNE HAUTE QUALITÉ   "
echo "=================================================="

DATA_DIR="/home/runner/vm_data"
mkdir -p "$DATA_DIR"
sudo chown -R 1000:1000 "$DATA_DIR"

# 1. Démarrage de l'image officielle Kasm Chrome (KasmVNC v1.16+ ultra moderne, WebAssembly, audio, 60fps)
echo "=== Démarrage de Kasm Chrome officiel ==="
docker pull kasmweb/chrome:1.16.0

docker run -d \
  --name kasm_chrome \
  --shm-size=1024m \
  -p 6901:6901 \
  -e VNC_PW=vncpass \
  -v "$DATA_DIR":/home/kasm-user \
  kasmweb/chrome:1.16.0

# 2. Installation de NGINX sur le host pour faire pont HTTP pur vers 3000 sans certificat
echo "=== Configuration du reverse-proxy NGINX local (Port 3000 HTTP -> 6901 HTTPS) ==="
sudo apt-get update -qq && sudo apt-get install -y -qq nginx > /dev/null 2>&1

cat << 'NGINX_EOF' | sudo tee /etc/nginx/sites-available/default > /dev/null
server {
    listen 3000 default_server;
    listen [::]:3000 default_server;

    location / {
        proxy_pass https://127.0.0.1:6901;
        proxy_ssl_verify off;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }
}
NGINX_EOF

sudo systemctl restart nginx

# 3. Attente que Kasm soit actif
echo "=== Attente de l'initialisation de Kasm Chrome ==="
for i in {1..30}; do
  if curl -s -k https://127.0.0.1:6901/ > /dev/null 2>&1; then
    echo " Kasm Chrome opérationnel !"
    break
  fi
  sleep 2
done

echo " Bureau moderne Chrome Kasm opérationnel sur le port 3000 !"
