#!/usr/bin/env bash
set -e

echo "=================================================="
echo "    ANDROID 8.1 OREO QEMU VNC DIRECT STREAM       "
echo "  (-vnc :0, -vga qxl, nomodeset xforcevesa)       "
echo "=================================================="

DATA_DIR="/home/runner/android_oreo_data"
sudo mkdir -p "$DATA_DIR"
cd "$DATA_DIR"

# 1. Nettoyage des processus antérieurs
pkill -9 -f qemu-system 2>/dev/null || true
pkill -9 -f websockify 2>/dev/null || true
pkill -9 -f nginx 2>/dev/null || true
docker rm -f redroid8 redroid13 android_vm 2>/dev/null || true

# 2. Installation des paquets nécessaires (QEMU, websockify, novnc, nginx, adb)
echo "=== Installation de QEMU & noVNC ==="
sudo apt-get update -qq >/dev/null 2>&1 || true
sudo apt-get install -y -qq qemu-system-x86 qemu-utils novnc websockify nginx adb wget curl p7zip-full >/dev/null 2>&1 || true

# 3. Téléchargement de l'image ISO Android-x86 8.1 Oreo (ou extraction kernel/initrd/system)
echo "=== Téléchargement d'Android-x86 8.1 r6 Oreo ==="
ISO_NAME="android-x86_64-8.1-r6.iso"
if [ ! -f "$ISO_NAME" ]; then
  wget -q --show-progress -O "$ISO_NAME" "https://osdn.net/projects/android-x86/downloads/71931/android-x86_64-8.1-r6.iso" || \
  wget -q --show-progress -O "$ISO_NAME" "https://mirrors.dotsrc.org/osdn/android-x86/71931/android-x86_64-8.1-r6.iso" || \
  wget -q --show-progress -O "$ISO_NAME" "https://sourceforge.net/projects/android-x86/files/Release%208.1/android-x86_64-8.1-r6.iso/download"
fi

# Création du disque virtuel persistant de 8GB
if [ ! -f "android8.qcow2" ]; then
  qemu-img create -f qcow2 android8.qcow2 8G
fi

# Extraction pour boot direct rapide du kernel & system
mkdir -p iso_extract
7z x -y "$ISO_NAME" -oiso_extract >/dev/null 2>&1 || true

# 4. Détection KVM pour accélération matérielle
KVM_FLAG=""
if [ -e /dev/kvm ] && [ -w /dev/kvm ]; then
  echo " KVM détecté et activé pour accélération matérielle maximale !"
  KVM_FLAG="-enable-kvm -cpu host"
else
  echo "⚠️ KVM non disponible, mode CPU standard x86_64"
  KVM_FLAG="-cpu max"
fi

# 5. Démarrage de QEMU Android 8.1 avec les paramètres exacts :
# - -vnc :0 (écoute sur 127.0.0.1:5900)
# - -vga qxl (carte graphique vidéo fluide)
# - nomodeset xforcevesa UVESA_MODE=720x1440 DPI=320 au kernel
echo "=== Lancement du moteur QEMU Android 8.1 avec VNC :0 & QXL ==="

if [ -f "iso_extract/kernel" ] && [ -f "iso_extract/initrd.img" ]; then
  echo " Boot Direct rapide via Kernel + Initrd + System.sfs"
  qemu-system-x86_64 \
    $KVM_FLAG \
    -m 2048 \
    -smp 2 \
    -vga qxl \
    -vnc :0 \
    -cdrom "$ISO_NAME" \
    -drive file=android8.qcow2,format=qcow2,if=virtio \
    -kernel iso_extract/kernel \
    -initrd iso_extract/initrd.img \
    -append "root=/dev/ram0 androidboot.hardware=android_x86 nomodeset xforcevesa UVESA_MODE=720x1440 DPI=320 SRC=/ androidboot.selinux=permissive quiet" \
    -net nic,model=virtio \
    -net user,hostfwd=tcp::5555-:5555 \
    -usb -device usb-tablet \
    -daemonize
else
  echo " Boot via CD-ROM ISO standard"
  qemu-system-x86_64 \
    $KVM_FLAG \
    -m 2048 \
    -smp 2 \
    -vga qxl \
    -vnc :0 \
    -boot d \
    -cdrom "$ISO_NAME" \
    -drive file=android8.qcow2,format=qcow2,if=virtio \
    -net nic,model=virtio \
    -net user,hostfwd=tcp::5555-:5555 \
    -usb -device usb-tablet \
    -daemonize
fi

# 6. Démarrage de websockify pointant précisément sur le port VNC de QEMU (:0 = 5900)
echo "=== Connexion websockify sur QEMU VNC 127.0.0.1:5900 ==="
sleep 2
websockify --web /usr/share/novnc 6080 127.0.0.1:5900 &
sleep 2

# 7. Démarrage du bridge ADB pour les commandes clavier/souris/touches
CURRENT_DIR=$(pwd)
WORK_DIR="/home/runner/work/VM/VM"
if [ -d "$WORK_DIR" ]; then
  CURRENT_DIR="$WORK_DIR"
fi
node "$CURRENT_DIR/scripts/android-bridge.cjs" &
sleep 1

# 8. Configuration NGINX Reverse-Proxy
echo "=== Configuration NGINX ==="
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

    # Interface Web Android 8.1 Oreo (Cadre normal par défaut, plein écran sans bouton)
    location / {
        root /var/www/android-web;
        index index.html;
        try_files $uri $uri/ @novnc_proxy;
    }

    # API Bridge ADB & Clavier
    location /api/ {
        proxy_pass http://127.0.0.1:8080/api/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }

    # Flux noVNC WebSockets vers QEMU VNC 5900
    location /websockify {
        proxy_pass http://127.0.0.1:6080/websockify;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }

    # Fichiers noVNC natifs
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

# 9. Validation du port 3000
for i in {1..20}; do
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:3000/ || echo "000")
  if [ "$HTTP_CODE" = "200" ]; then
    echo " Serveur Web Android 8.1 QEMU VNC opérationnel (HTTP 200) !"
    break
  fi
  sleep 2
done

echo "=================================================="
echo " Android 8.1 QEMU VNC Stream configuré avec succès !"
echo "=================================================="
