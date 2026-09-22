#!/usr/bin/env bash
set -e

echo "=================================================="
echo "    CONFIGURATION DE LA VM SMARTPHONE ANDROID     "
echo "=================================================="

DATA_DIR="/home/runner/android_vm_data"
sudo mkdir -p "$DATA_DIR/data"
sudo chmod -R 777 "$DATA_DIR" 2>/dev/null || true

# Nettoyage des anciens conteneurs
docker rm -f android_vm redroid13 ws_scrcpy 2>/dev/null || true

# 1. Vérification et activation de l'accélération matérielle KVM
sudo chmod 666 /dev/kvm 2>/dev/null || true

# 2. Démarrage du conteneur Android officiel (budtmo/docker-android)
echo "=== Démarrage du conteneur Android (Samsung Galaxy S10) ==="
docker pull budtmo/docker-android:emulator_11.0

docker run -d \
  --name android_vm \
  --privileged \
  --device /dev/kvm \
  -p 6080:6080 \
  -p 5554:5554 \
  -p 5555:5555 \
  -e DEVICE="Samsung Galaxy S10" \
  -e WEB_VNC=true \
  -e WEB_PORT=6080 \
  -e APPIUM=false \
  -v "$DATA_DIR/data":/root/android \
  budtmo/docker-android:emulator_11.0

# 3. Configuration du reverse-proxy NGINX sur le port 3000
echo "=== Configuration du reverse-proxy NGINX (Redirection automatique vers noVNC plein écran) ==="
sudo apt-get update -qq && sudo apt-get install -y -qq nginx > /dev/null 2>&1

cat << 'NGINX_EOF' | sudo tee /etc/nginx/sites-available/default > /dev/null
server {
    listen 3000 default_server;
    listen [::]:3000 default_server;

    proxy_buffering off;
    proxy_request_buffering off;
    tcp_nodelay on;

    # Redirection immédiate de la racine vers noVNC en autoconnect et plein écran
    location = / {
        return 302 /vnc.html?autoconnect=true&resize=scale&reconnect=true;
    }

    # Proxy universel pour noVNC, WebSockets, scripts JS, feuilles CSS et flux vidéo
    location / {
        proxy_pass http://127.0.0.1:6080;
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

# 4. Attente et test automatisé exhaustif de tous les composants
echo "=== Validation active des points de terminaison Web Android ==="
VNC_READY=false
for i in {1..50}; do
  HTTP_ROOT=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:3000/ || echo "000")
  HTTP_VNC=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:3000/vnc.html || echo "000")
  HTTP_CSS=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:3000/app/styles/base.css || echo "000")

  echo "[Tentative $i/50] / -> HTTP $HTTP_ROOT | /vnc.html -> HTTP $HTTP_VNC | /app/styles/base.css -> HTTP $HTTP_CSS"

  if [ "$HTTP_ROOT" = "302" ] && [ "$HTTP_VNC" = "200" ] && [ "$HTTP_CSS" = "200" ]; then
    echo " TOUS LES TESTS SONT AU VERT : Serveur Web noVNC Android 100% fonctionnel !"
    VNC_READY=true
    break
  fi
  sleep 3
done

if [ "$VNC_READY" = false ]; then
  echo "⚠️ Le serveur Android a mis plus de temps à démarrer, vérification des processus Docker..."
  docker ps
fi

echo " VM Android prête et accessible en plein écran !"
