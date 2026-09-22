#!/usr/bin/env bash
set -e

echo "=================================================="
echo "    CONFIGURATION BUREAU LINUX UBUNTU MODERNE     "
echo "=================================================="

DATA_DIR="/home/runner/vm_data"
mkdir -p "$DATA_DIR"
sudo chown -R 1000:1000 "$DATA_DIR"

# 1. Démarrage de l'image Kasm Desktop Ubuntu complète (Ubuntu moderne, KasmVNC 60fps, WebAssembly, Google Chrome, audio, clipboard)
echo "=== Téléchargement et lancement de Kasm Desktop Ubuntu ==="
docker pull kasmweb/ubuntu-jammy-desktop:1.16.0

docker run -d \
  --name kasm_desktop \
  --shm-size=1024m \
  -p 6901:6901 \
  -e VNC_PW=vncpass \
  -v "$DATA_DIR":/home/kasm-user \
  kasmweb/ubuntu-jammy-desktop:1.16.0

# 2. Installation et configuration du Reverse Proxy NGINX avec Authentification automatique transparente
echo "=== Configuration du reverse-proxy NGINX (HTTP 3000 -> Kasm 6901 HTTPS + Autologin) ==="
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
        # Autologin direct sans pop-up de mot de passe (kasm_user:vncpass)
        proxy_set_header Authorization "Basic a2FzbV91c2VyOnZuY3Bhc3M=";
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }
}
NGINX_EOF

sudo systemctl restart nginx

# 3. Attente que Kasm soit actif
echo "=== Attente de l'initialisation du bureau Kasm ==="
for i in {1..40}; do
  if curl -s -k https://127.0.0.1:6901/ > /dev/null 2>&1; then
    echo " Bureau moderne Ubuntu Kasm opérationnel !"
    break
  fi
  sleep 2
done

echo " Environnement Linux Ultra-Moderne prêt sur le port 3000 !"
