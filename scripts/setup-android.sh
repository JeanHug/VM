#!/usr/bin/env bash
set -e

echo "=================================================="
echo "    ANDROID GRAPHICAL SMARTPHONE (PORTRAIT)       "
echo "  Optimisé : Boot Direct GUI + SurfaceFlinger     "
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
echo "=== 1. Installation des paquets système ==="
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

# 4. Extraction des fichiers de boot Android
echo "=== 2. Extraction des composants du système ==="
mkdir -p "$DATA_DIR/android_fs"
7z x -y "$ISO_NAME" -o"$DATA_DIR/android_fs" >/dev/null 2>&1 || true

# Disque de données persistantes data.img
if [ ! -f "data.img" ]; then
  echo "Création de la partition de données persistantes Android (data.img)..."
  qemu-img create -f raw data.img 4G
  mkfs.ext4 -F -L "data" data.img >/dev/null 2>&1 || true
fi

# 5. Détection KVM matériel
KVM_FLAG=""
if [ -e /dev/kvm ]; then
  sudo chmod 666 /dev/kvm 2>/dev/null || true
  KVM_FLAG="-enable-kvm -cpu host"
else
  KVM_FLAG="-cpu max"
fi

# 6. Démarrage de QEMU Android en mode Graphique Direct (VGA standard / 720x1280 Portrait)
echo "=== 3. Démarrage de QEMU Android (Mode Graphique UI Portrait) ==="
qemu-system-x86_64 \
  $KVM_FLAG \
  -m 2048 \
  -smp 2 \
  -vga std \
  -vnc 127.0.0.1:0 \
  -kernel "$DATA_DIR/android_fs/kernel" \
  -initrd "$DATA_DIR/android_fs/initrd.img" \
  -drive file="$DATA_DIR/data.img",format=raw,if=virtio,index=0 \
  -drive file="$DATA_DIR/$ISO_NAME",format=raw,if=ide,index=1,media=cdrom \
  -append "root=/dev/ram0 androidboot.hardware=android_x86 androidboot.selinux=permissive SRC=/ DATA=/dev/vda UVESA_MODE=720x1280 DPI=280 vga=788 quiet AUTO_LOAD=old_pc_graphics" \
  -net nic,model=virtio \
  -net user,hostfwd=tcp::5555-:5555 \
  -usb -device usb-tablet \
  -daemonize

# 7. Relais Websockify vers QEMU VNC (:0 -> 6080)
echo "=== 4. Démarrage Websockify (127.0.0.1:5900 -> 6080) ==="
sleep 2
websockify --web /usr/share/novnc 6080 127.0.0.1:5900 >/dev/null 2>&1 &
sleep 2

# 8. Démarrage du bridge ADB
CURRENT_DIR=$(pwd)
WORK_DIR="/home/runner/work/VM/VM"
if [ -d "$WORK_DIR" ]; then
  CURRENT_DIR="$WORK_DIR"
fi
node "$CURRENT_DIR/scripts/android-bridge.cjs" >/dev/null 2>&1 &
sleep 1

# 9. Configuration NGINX Reverse-Proxy
echo "=== 5. Configuration NGINX ==="
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

# 10. Validation HTTP locale
echo "=== 6. Validation du serveur Web Android ==="
for i in {1..20}; do
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:3000/ || echo "000")
  if [ "$HTTP_CODE" = "200" ]; then
    echo " Serveur Web Android QEMU opérationnel (HTTP 200) !"
    break
  fi
  sleep 2
done

echo "=================================================="
echo " Android Graphique Prêt (Port 3000 Ouvert) !"
echo "=================================================="
