#!/usr/bin/env bash
set -e

echo "=================================================="
echo "    CONFIGURATION DE LA VM SMARTPHONE ANDROID 13   "
echo "=================================================="

DATA_DIR="/home/runner/android_vm_data"

# Utilisation de sudo pour créer les dossiers
sudo mkdir -p "$DATA_DIR/data"
sudo chown -R 1000:1000 "$DATA_DIR"
sudo chmod -R 775 "$DATA_DIR"

# Nettoyage des conteneurs précédents
docker rm -f redroid ws_scrcpy 2>/dev/null || true

# 1. Chargement des modules noyau Android si disponibles
sudo modprobe binder_linux 2>/dev/null || true
sudo modprobe ashmem_linux 2>/dev/null || true

# 2. Démarrage de Redroid Android 13
echo "=== Téléchargement et lancement de Redroid Android 13 ==="
docker pull redroid/redroid:13.0.0-latest 2>/dev/null || docker pull redroid/redroid:11.0.0-latest 2>/dev/null || true

docker run -d \
  --name redroid \
  --privileged \
  -p 5555:5555 \
  -v "$DATA_DIR/data":/data \
  redroid/redroid:13.0.0-latest \
  androidboot.hardware=mt6893 \
  androidboot.redroid_width=720 \
  androidboot.redroid_height=1280 \
  androidboot.redroid_dpi=320 \
  androidboot.redroid_fps=60 \
  androidboot.use_memfd=1 2>/dev/null || docker run -d \
  --name redroid \
  --privileged \
  -p 5555:5555 \
  -v "$DATA_DIR/data":/data \
  redroid/redroid:11.0.0-latest \
  androidboot.use_memfd=1 2>/dev/null || true

# 3. Lancement de la passerelle Web WS-Scrcpy (Port 8000)
echo "=== Démarrage de l'interface tactile Web Android ==="
docker pull sorcx/ws-scrcpy:latest 2>/dev/null || true
docker run -d \
  --name ws_scrcpy \
  --net=host \
  sorcx/ws-scrcpy:latest 2>/dev/null || true

# 4. Configuration de NGINX sur le port 3000 vers le Web Android (Port 8000)
echo "=== Configuration du reverse-proxy NGINX pour Android ==="
sudo apt-get update -qq && sudo apt-get install -y -qq nginx > /dev/null 2>&1

cat << 'NGINX_EOF' | sudo tee /etc/nginx/sites-available/default > /dev/null
server {
    listen 3000 default_server;
    listen [::]:3000 default_server;

    proxy_buffering off;
    proxy_request_buffering off;
    tcp_nodelay on;

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }
}
NGINX_EOF

sudo systemctl restart nginx || sudo service nginx restart

# 5. Attente que le service Android soit prêt
echo "=== Attente de l'initialisation de l'instance Android ==="
for i in {1..30}; do
  if curl -s http://127.0.0.1:8000/ > /dev/null 2>&1 || curl -s http://127.0.0.1:3000/ > /dev/null 2>&1; then
    echo " Instance Android 13 opérationnelle !"
    break
  fi
  sleep 2
done

echo " VM Android 13 prête et accessible !"
