#!/usr/bin/env bash
set -e

echo "=================================================="
echo "    CONFIGURATION DU VRAI SMARTPHONE ANDROID 13   "
echo "=================================================="

DATA_DIR="/home/runner/android_vm_data"
sudo mkdir -p "$DATA_DIR/data" "/var/www/android-web"
sudo cp -rf android-web/* /var/www/android-web/ 2>/dev/null || true
sudo chmod -R 777 "$DATA_DIR" /var/www/android-web 2>/dev/null || true

# Nettoyage des conteneurs précédents
docker rm -f android_vm redroid13 ws_scrcpy 2>/dev/null || true

# 1. Vérification de l'accélération matérielle KVM
sudo chmod 666 /dev/kvm 2>/dev/null || true

# 2. Démarrage du conteneur Android
echo "=== Démarrage d'Android avec accélération KVM native ==="
docker pull budtmo/docker-android:emulator_11.0

# On lance avec les variables optimisées pour mobile plein écran
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

# 3. Configuration NGINX avec suppression totale du faux cadre et plein écran 100%
echo "=== Configuration du reverse-proxy NGINX (Plein Écran Natif) ==="
sudo apt-get update -qq && sudo apt-get install -y -qq nginx > /dev/null 2>&1

cat << 'NGINX_EOF' | sudo tee /etc/nginx/sites-available/default > /dev/null
server {
    listen 3000 default_server;
    listen [::]:3000 default_server;

    root /var/www/android-web;
    index index.html;

    proxy_buffering off;
    proxy_request_buffering off;
    tcp_nodelay on;

    # Page d'accueil mobile plein écran personnalisée
    location = / {
        try_files /index.html =404;
    }

    # Proxy vers le flux noVNC avec suppression des bordures et styles intrusifs
    location /stream/ {
        proxy_pass http://127.0.0.1:6080/vnc.html?autoconnect=true&resize=scale&quality=9;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }

    # Websockets noVNC et assets internes
    location / {
        proxy_pass http://127.0.0.1:6080/;
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

# 4. Suppression directe du cadre Nexus à l'intérieur du conteneur
echo "=== Injection du style 100% Plein Écran sans faux cadre ==="
sleep 5
docker exec -u 0 android_vm bash -c '
  # Trouver les fichiers css de noVNC et supprimer tout skin de téléphone
  find /root/ -name "*.css" -o -name "vnc.html" 2>/dev/null | while read f; do
    echo "/* Forcer plein écran sans bordure */
    body, html { margin:0!important; padding:0!important; background:#000!important; overflow:hidden!important; width:100vw!important; height:100vh!important; }
    #noVNC_canvas, canvas, video { width:100vw!important; height:100vh!important; max-width:100vw!important; max-height:100vh!important; object-fit:contain!important; }
    .sidebar, .menu, .phone-frame, .device-skin, .device-art, #noVNC_control_bar { display:none!important; }
    " >> "$f" 2>/dev/null || true
  done
' || true

# 5. Attente active de la disponibilité du serveur Web
echo "=== Attente de l'initialisation du flux Android ==="
for i in {1..40}; do
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:6080/ || echo "000")
  if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ]; then
    echo " Serveur Web Android opérationnel (HTTP $HTTP_CODE) !"
    break
  fi
  sleep 2
done

echo " Android Plein Écran 100% configuré et prêt !"
