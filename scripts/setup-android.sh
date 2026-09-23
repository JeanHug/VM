#!/usr/bin/env bash
set -e

echo "=================================================="
echo "    ANDROID GRAPHICAL SMARTPHONE (PORTRAIT)       "
echo "   Mode Installation / Boot Direct Système        "
echo "=================================================="

DATA_DIR="/home/runner/android_oreo_data"
sudo mkdir -p "$DATA_DIR"
sudo chown -R runner:docker "$DATA_DIR" 2>/dev/null || sudo chown -R $(id -u):$(id -g) "$DATA_DIR" 2>/dev/null || true
sudo chmod -R 777 "$DATA_DIR"
cd "$DATA_DIR"

# 1. Nettoyage préventif
pkill -9 -f qemu-system 2>/dev/null || true
pkill -9 -f websockify 2>/dev/null || true
pkill -9 -f nginx 2>/dev/null || true
pkill -9 -f android-bridge 2>/dev/null || true

# 2. Installation des paquets
echo "=== 1. Installation des dépendances ==="
sudo apt-get update -qq >/dev/null 2>&1 || true
sudo apt-get install -y -qq qemu-system-x86 qemu-utils novnc websockify nginx adb wget curl p7zip-full squashfs-tools >/dev/null 2>&1 || true

# 3. Téléchargement d'Android-x86 8.1 r6
ISO_NAME="android-x86_64-8.1-r6.iso"
if [ ! -f "$ISO_NAME" ] || [ ! -s "$ISO_NAME" ]; then
  rm -f "$ISO_NAME"
  echo "Téléchargement d'Android-x86 ISO..."
  curl -L -s -o "$ISO_NAME" "https://mirrors.dotsrc.org/osdn/android-x86/71931/android-x86_64-8.1-r6.iso" || \
  curl -L -s -o "$ISO_NAME" "https://sourceforge.net/projects/android-x86/files/Release%208.1/android-x86_64-8.1-r6.iso/download"
fi

# Disque virtuel Android
if [ ! -f "android_system.qcow2" ]; then
  echo "Création de l'image disque système Android..."
  qemu-img create -f qcow2 android_system.qcow2 8G
fi

# 4. Détection KVM
KVM_FLAG=""
if [ -e /dev/kvm ]; then
  sudo chmod 666 /dev/kvm 2>/dev/null || true
  KVM_FLAG="-enable-kvm -cpu host"
else
  KVM_FLAG="-cpu max"
fi

# 5. Démarrage de QEMU avec boot direct ISO (Live CD - Run Android-x86 without installation)
# Le boot standard de l'ISO Android charge directement le Launcher SurfaceFlinger sans invite textuelle
echo "=== 2. Démarrage QEMU Android (Live CD -> Launcher Graphique) ==="
qemu-system-x86_64 \
  $KVM_FLAG \
  -m 2048 \
  -smp 2 \
  -vga std \
  -vnc 127.0.0.1:0 \
  -cdrom "$DATA_DIR/$ISO_NAME" \
  -hda "$DATA_DIR/android_system.qcow2" \
  -boot d \
  -net nic,model=virtio \
  -net user,hostfwd=tcp::5555-:5555 \
  -usb -device usb-tablet \
  -daemonize

# 6. Relais Websockify vers QEMU VNC (:0 -> 6080)
echo "=== 3. Démarrage Websockify (127.0.0.1:5900 -> 6080) ==="
sleep 2
websockify --web /usr/share/novnc 6080 127.0.0.1:5900 >/dev/null 2>&1 &
sleep 2

# 7. Bridge ADB
CURRENT_DIR=$(pwd)
WORK_DIR="/home/runner/work/VM/VM"
if [ -d "$WORK_DIR" ]; then
  CURRENT_DIR="$WORK_DIR"
fi
node "$CURRENT_DIR/scripts/android-bridge.cjs" >/dev/null 2>&1 &
sleep 1

# 8. Configuration NGINX Reverse-Proxy
echo "=== 4. Configuration NGINX ==="
sudo mkdir -p /var/www/android-web
sudo cp -r "$CURRENT_DIR/android-web/"* /var/www/android-web/
sudo chmod -R 755 /var/www/android-web

cat << 'NGINX_EOF' | sudo tee /etc/nginx/sites-available/default > /dev/null
server {
    listen 3000 default_server;
    listen [::]:3000 default_server;

    proxy_buffering off;
    proxy_request_buffering off;
    tcp_nodelay on;

    location / {
        root /var/www/android-web;
        index index.html;
        try_files $uri $uri/ @novnc_proxy;
    }

    location /api/ {
        proxy_pass http://127.0.0.1:8080/api/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }

    location /websockify {
        proxy_pass http://127.0.0.1:6080/websockify;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }

    location @novnc_proxy {
        proxy_pass http://127.0.0.1:6080;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }
}
NGINX_EOF

sudo systemctl restart nginx || sudo service nginx restart

# 9. Validation du port local 3000
for i in {1..20}; do
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:3000/ || echo "000")
  if [ "$HTTP_CODE" = "200" ]; then
    echo " Serveur Web Android QEMU opérationnel (HTTP 200) !"
    break
  fi
  sleep 2
done

# 10. Envoi automatique de la touche Entrée pour valider immédiatement le menu Grub de boot Android
sleep 3
adb connect 127.0.0.1:5555 2>/dev/null || true
echo "=================================================="
echo " Android Live CD QEMU Démarré !"
echo "=================================================="
