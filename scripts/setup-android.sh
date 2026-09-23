#!/usr/bin/env bash
set -e

echo "=================================================="
echo "    CONFIGURATION DE LA VM ANDROID ÉMULATION      "
echo "    (Système d'origine budtmo/docker-android)     "
echo "=================================================="

DATA_DIR="/home/runner/android_vm_data"
sudo mkdir -p "$DATA_DIR/data"
sudo chown -R 1000:1000 "$DATA_DIR" 2>/dev/null || true
sudo chmod -R 777 "$DATA_DIR" 2>/dev/null || true

# 1. Nettoyage
docker rm -f android_vm redroid13 redroid14 ws_scrcpy android_kasm 2>/dev/null || true
pkill -9 -f nginx 2>/dev/null || true

# 2. Activation KVM
sudo chmod 666 /dev/kvm 2>/dev/null || true

# 3. Démarrage de l'image Android avec interface noVNC intégrée
echo "=== Démarrage de l'émulateur Android (budtmo/docker-android) ==="
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
  budtmo/docker-android:emulator_11.0

# 4. Configuration NGINX port 3000 vers 6080 (Strictement identique à Linux Desktop)
echo "=== Configuration du reverse-proxy NGINX ==="
sudo apt-get update -qq && sudo apt-get install -y -qq nginx > /dev/null 2>&1

cat << 'NGINX_EOF' | sudo tee /etc/nginx/sites-available/default > /dev/null
server {
    listen 3000 default_server;
    listen [::]:3000 default_server;

    proxy_buffering off;
    proxy_request_buffering off;
    tcp_nodelay on;

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

# 5. Boucle de validation active de l'accès Web Android
echo "=== Validation active du serveur Web Android ==="
ANDROID_READY=false
for i in {1..45}; do
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:6080/ || echo "000")
  if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ]; then
    echo " Serveur Web Android opérationnel (HTTP $HTTP_CODE) !"
    ANDROID_READY=true
    break
  fi
  echo "En attente du démarrage Web Android... ($i/45 - HTTP $HTTP_CODE)"
  sleep 3
done

if [ "$ANDROID_READY" = false ]; then
  echo "⚠️ Avertissement : Le serveur Web Android prend plus de temps à s'initialiser."
fi

echo "=================================================="
echo " VM Android d'origine prête et accessible !"
echo "=================================================="
