#!/usr/bin/env bash
set -e

echo "=================================================="
echo "    ANDROID 8.1 OREO QEMU VNC DIRECT STREAM       "
echo "  (-vnc :0, -vga qxl, nomodeset xforcevesa)       "
echo "=================================================="

# 1. Dossier de données avec permissions complètes runner
DATA_DIR="/home/runner/android_oreo_data"
sudo mkdir -p "$DATA_DIR"
sudo chown -R runner:docker "$DATA_DIR" 2>/dev/null || sudo chown -R $(id -u):$(id -g) "$DATA_DIR" 2>/dev/null || true
sudo chmod -R 777 "$DATA_DIR"
cd "$DATA_DIR"

# 2. Nettoyage des anciens processus
pkill -9 -f qemu-system 2>/dev/null || true
pkill -9 -f websockify 2>/dev/null || true
pkill -9 -f nginx 2>/dev/null || true
docker rm -f redroid8 redroid13 android_vm 2>/dev/null || true

# 3. Installation des paquets requis
echo "=== Installation de QEMU & noVNC ==="
sudo apt-get update -qq >/dev/null 2>&1 || true
sudo apt-get install -y -qq qemu-system-x86 qemu-utils novnc websockify nginx adb wget curl p7zip-full aria2 >/dev/null 2>&1 || true

# 4. Téléchargement d'Android-x86 8.1 Oreo avec mirror résilient et permissions
echo "=== Téléchargement d'Android-x86 8.1 r6 Oreo ==="
ISO_NAME="android-x86_64-8.1-r6.iso"
if [ ! -f "$ISO_NAME" ] || [ ! -s "$ISO_NAME" ]; then
  rm -f "$ISO_NAME"
  curl -L -s -o "$ISO_NAME" "https://mirrors.dotsrc.org/osdn/android-x86/71931/android-x86_64-8.1-r6.iso" || \
  curl -L -s -o "$ISO_NAME" "https://sourceforge.net/projects/android-x86/files/Release%208.1/android-x86_64-8.1-r6.iso/download" || \
  wget -q -O "$ISO_NAME" "https://osdn.net/projects/android-x86/downloads/71931/android-x86_64-8.1-r6.iso"
fi

sudo chmod 666 "$ISO_NAME" 2>/dev/null || true

# Disque virtuel persistant de 8GB
if [ ! -f "android8.qcow2" ]; then
  qemu-img create -f qcow2 android8.qcow2 8G
  sudo chmod 666 android8.qcow2
fi

# Extraction rapide des fichiers Kernel & Initrd pour boot direct
mkdir -p iso_extract
7z x -y "$ISO_NAME" -oiso_extract >/dev/null 2>&1 || true
sudo chmod -R 777 iso_extract 2>/dev/null || true

# 5. Détection KVM pour accélération matérielle
KVM_FLAG=""
if [ -e /dev/kvm ]; then
  sudo chmod 666 /dev/kvm 2>/dev/null || true
  echo " KVM activé pour accélération matérielle !"
  KVM_FLAG="-enable-kvm -cpu host"
else
  echo " Mode CPU x86_64"
  KVM_FLAG="-cpu max"
fi

# 6. Démarrage de QEMU Android 8.1 :
# - -vnc :0 (écoute sur 127.0.0.1:5900)
# - -vga qxl (carte graphique sans écran noir)
# - nomodeset xforcevesa au kernel
echo "=== Démarrage de QEMU Android 8.1 avec VNC :0 & QXL ==="

if [ -f "iso_extract/kernel" ] && [ -f "iso_extract/initrd.img" ]; then
  echo " Démarrage Direct Kernel + Initrd"
  qemu-system-x86_64 \
    $KVM_FLAG \
    -m 2048 \
    -smp 2 \
    -vga qxl \
    -vnc :0 \
    -cdrom "$DATA_DIR/$ISO_NAME" \
    -drive file="$DATA_DIR/android8.qcow2",format=qcow2,if=virtio \
    -kernel "$DATA_DIR/iso_extract/kernel" \
    -initrd "$DATA_DIR/iso_extract/initrd.img" \
    -append "root=/dev/ram0 androidboot.hardware=android_x86 nomodeset xforcevesa UVESA_MODE=720x1440 DPI=320 SRC=/ androidboot.selinux=permissive quiet" \
    -net nic,model=virtio \
    -net user,hostfwd=tcp::5555-:5555 \
    -usb -device usb-tablet \
    -daemonize
else
  echo " Démarrage ISO Boot"
  qemu-system-x86_64 \
    $KVM_FLAG \
    -m 2048 \
    -smp 2 \
    -vga qxl \
    -vnc :0 \
    -boot d \
    -cdrom "$DATA_DIR/$ISO_NAME" \
    -drive file="$DATA_DIR/android8.qcow2",format=qcow2,if=virtio \
    -net nic,model=virtio \
    -net user,hostfwd=tcp::5555-:5555 \
    -usb -device usb-tablet \
    -daemonize
fi

# 7. Websockify sur le port VNC de QEMU (127.0.0.1:5900 -> 6080)
echo "=== Connexion websockify sur QEMU VNC (127.0.0.1:5900 -> 6080) ==="
sleep 2
websockify --web /usr/share/novnc 6080 127.0.0.1:5900 &
sleep 2

# 8. Bridge ADB pour le clavier direct et les commandes
CURRENT_DIR=$(pwd)
WORK_DIR="/home/runner/work/VM/VM"
if [ -d "$WORK_DIR" ]; then
  CURRENT_DIR="$WORK_DIR"
fi
node "$CURRENT_DIR/scripts/android-bridge.cjs" &
sleep 1

# 9. Configuration NGINX Reverse-Proxy
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

    # Interface Web Android 8.1 Oreo
    location / {
        root /var/www/android-web;
        index index.html;
        try_files $uri $uri/ @novnc_proxy;
    }

    # API Bridge Clavier direct ADB
    location /api/ {
        proxy_pass http://127.0.0.1:8080/api/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }

    # Flux noVNC WebSockets
    location /websockify {
        proxy_pass http://127.0.0.1:6080/websockify;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }

    # Proxy noVNC direct
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

# 10. Boucle de validation
for i in {1..20}; do
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:3000/ || echo "000")
  if [ "$HTTP_CODE" = "200" ]; then
    echo " Serveur Web Android 8.1 QEMU VNC opérationnel (HTTP 200) !"
    break
  fi
  sleep 2
done

echo "=================================================="
echo " Android 8.1 QEMU VNC Stream Prêt !"
echo "=================================================="
