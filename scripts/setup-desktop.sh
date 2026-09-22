#!/usr/bin/env bash
set -e

echo "=================================================="
echo "    CONFIGURATION BI-ENVIRONNEMENT : LINUX & ANDROID "
echo "=================================================="

DATA_DIR="/home/runner/vm_data"

# 1. Préparation des répertoires de données persistantes
sudo mkdir -p "$DATA_DIR/Desktop" "$DATA_DIR/Downloads" "$DATA_DIR/Applications" "$DATA_DIR/.config" "$DATA_DIR/.local/bin" "$DATA_DIR/android_data"
sudo chown -R 1000:1000 "$DATA_DIR"
sudo chmod -R 775 "$DATA_DIR"

# Nettoyage des conteneurs précédents
docker rm -f kasm_desktop redroid ws_scrcpy 2>/dev/null || true

# 2. Démarrage de l'environnement 1 : Bureau Ubuntu Linux (Kasm)
echo "=== Démarrage du Bureau Virtuel Ubuntu Linux (Port 6901) ==="
docker pull kasmweb/ubuntu-jammy-desktop:1.16.0
docker run -d \
  --name kasm_desktop \
  --shm-size=2048m \
  -p 6901:6901 \
  -e VNC_PW=vncpass \
  -e VNC_RESOLUTION=1600x900 \
  -v "$DATA_DIR":/home/kasm-user \
  kasmweb/ubuntu-jammy-desktop:1.16.0

# 3. Démarrage de l'environnement 2 : Android 13 (Redroid) & Interface Web
echo "=== Démarrage de l'environnement Android 13 (Redroid) ==="
# Chargement des modules noyau Android si disponibles
sudo modprobe binder_linux 2>/dev/null || true
sudo modprobe ashmem_linux 2>/dev/null || true

# Lancement du conteneur Android 13 officiel
docker pull redroid/redroid:13.0.0-latest 2>/dev/null || docker pull redroid/redroid:11.0.0-latest 2>/dev/null || true
docker run -d \
  --name redroid \
  --privileged \
  -p 5555:5555 \
  -v "$DATA_DIR/android_data":/data \
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
  -v "$DATA_DIR/android_data":/data \
  redroid/redroid:11.0.0-latest \
  androidboot.use_memfd=1 2>/dev/null || true

# Lancement de la passerelle Web Android WS-Scrcpy (Port 8000)
docker pull sorcx/ws-scrcpy:latest 2>/dev/null || true
docker run -d \
  --name ws_scrcpy \
  --net=host \
  sorcx/ws-scrcpy:latest 2>/dev/null || true

# 4. Configuration du reverse-proxy NGINX pour les deux environnements
echo "=== Configuration du reverse-proxy NGINX (Desktop & Android) ==="
sudo apt-get update -qq && sudo apt-get install -y -qq nginx > /dev/null 2>&1

cat << 'NGINX_EOF' | sudo tee /etc/nginx/sites-available/default > /dev/null
server {
    listen 3000 default_server;
    listen [::]:3000 default_server;

    proxy_buffering off;
    proxy_request_buffering off;
    tcp_nodelay on;

    # 1. Bureau Linux Ubuntu (Racine /)
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
        proxy_set_header Authorization "Basic a2FzbV91c2VyOnZuY3Bhc3M=";
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }

    # 2. Téléphone Android 13 (/android/)
    location /android/ {
        proxy_pass http://127.0.0.1:8000/;
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

# 5. Attente de démarrage des services
echo "=== Attente de l'initialisation des conteneurs ==="
for i in {1..35}; do
  if curl -s -k https://127.0.0.1:6901/ > /dev/null 2>&1; then
    echo " Bureau Ubuntu opérationnel !"
    break
  fi
  sleep 2
done

# 6. Installation et validation de Google Chrome & Google Docs sur le bureau Linux
echo "=== Configuration des applications sur le Bureau Linux ==="
docker exec -u 0 kasm_desktop bash -c '
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null 2>&1 || true
  apt-get install -y -qq xclip xsel autocutsel wget curl gnupg ca-certificates > /dev/null 2>&1 || true

  # Synchronisation du presse-papier X11
  su - kasm-user -c "autocutsel -fork >/dev/null 2>&1 || true"
  su - kasm-user -c "autocutsel -selection PRIMARY -fork >/dev/null 2>&1 || true"

  # Installation officielle de Google Chrome Stable
  if ! [ -x /usr/bin/google-chrome-stable ]; then
    wget -q -O - https://dl-ssl.google.com/linux/linux_signing_key.pub | gpg --dearmor --yes -o /usr/share/keyrings/google-chrome.gpg 2>/dev/null || true
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" > /etc/apt/sources.list.d/google-chrome.list
    apt-get update -qq >/dev/null 2>&1 || true
    apt-get install -y -qq google-chrome-stable >/dev/null 2>&1 || true
  fi

  # Nettoyage de tout reste d Antigravity si présent
  rm -f /home/kasm-user/Desktop/*antigravity* /usr/local/bin/*antigravity* /usr/share/applications/*antigravity* 2>/dev/null || true

  # Lanceur officiel Google Chrome (sans boucle, direct et compatible conteneur)
  cat << "CHROME_EOF" > /usr/local/bin/google-chrome
#!/usr/bin/env bash
exec /usr/bin/google-chrome-stable \
  --no-sandbox \
  --disable-dev-shm-usage \
  --disable-gpu \
  --password-store=basic \
  --no-first-run \
  --no-default-browser-check \
  "$@"
CHROME_EOF
  chmod 755 /usr/local/bin/google-chrome
  cp -f /usr/local/bin/google-chrome /usr/local/bin/chrome 2>/dev/null || true

  # Lanceur officiel Google Docs
  cat << "DOCS_EOF" > /usr/local/bin/google-docs
#!/usr/bin/env bash
exec /usr/bin/google-chrome \
  --app="https://docs.google.com" \
  --class="google-docs" \
  "$@"
DOCS_EOF
  chmod 755 /usr/local/bin/google-docs

  # Icône SVG officielle Google Docs
  mkdir -p /usr/share/icons/hicolor/scalable/apps /usr/share/pixmaps
  cat << "SVG_DOCS" > /usr/share/icons/hicolor/scalable/apps/google-docs.svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48" width="128" height="128">
  <path fill="#4285F4" d="M30 4H12C9.79 4 8 5.79 8 8v32c0 2.21 1.79 4 4 4h24c2.21 0 4-1.79 4-4V16L30 4z"/>
  <path fill="#A1C2FA" d="M30 4v12h12L30 4z"/>
  <path fill="#FFFFFF" d="M16 22h16v2.5H16zm0 6h16v2.5H16zm0 6h10v2.5H16z"/>
</svg>
SVG_DOCS
  cp -f /usr/share/icons/hicolor/scalable/apps/google-docs.svg /usr/share/pixmaps/google-docs.svg 2>/dev/null || true

  # Raccourcis sur le Bureau XFCE
  mkdir -p /home/kasm-user/Desktop /usr/share/applications

  # Raccourci Google Chrome
  cat << "DESKTOP_CHROME" > /home/kasm-user/Desktop/google-chrome.desktop
[Desktop Entry]
Version=1.0
Type=Application
Name=Google Chrome
GenericName=Navigateur Web
Comment=Naviguer sur Internet avec Google Chrome
Exec=/usr/local/bin/google-chrome %U
Icon=google-chrome
Terminal=false
Categories=Network;WebBrowser;StartupNotify=true
Actions=new-window;new-private-window;
DESKTOP_CHROME

  # Raccourci Google Docs
  cat << "DESKTOP_DOCS" > /home/kasm-user/Desktop/google-docs.desktop
[Desktop Entry]
Version=1.0
Type=Application
Name=Google Docs
GenericName=Traitement de texte
Comment=Créer et éditer des documents en ligne
Exec=/usr/local/bin/google-docs %U
Icon=/usr/share/icons/hicolor/scalable/apps/google-docs.svg
Terminal=false
Categories=Office;WordProcessor;StartupNotify=true
DESKTOP_DOCS

  # Copie dans le menu des applications système
  cp -f /home/kasm-user/Desktop/google-chrome.desktop /usr/share/applications/
  cp -f /home/kasm-user/Desktop/google-docs.desktop /usr/share/applications/

  # Permissions d exécution et validation de confiance XFCE
  chmod 755 /home/kasm-user/Desktop/*.desktop /usr/share/applications/*.desktop 2>/dev/null || true
  chown -R 1000:1000 /home/kasm-user

  # Validation de sécurité pour ouverture immédiate au double-clic
  su - kasm-user -c "gio set /home/kasm-user/Desktop/*.desktop metadata::trusted true 2>/dev/null || true"
'

echo " Configuration terminée : Bureau Ubuntu et Android 13 opérationnels !"
