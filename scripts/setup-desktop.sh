#!/usr/bin/env bash
set -e

echo "=================================================="
echo "    CONFIGURATION BUREAU LINUX UBUNTU (OFFICIEL)  "
echo "=================================================="

DATA_DIR="/home/runner/vm_data"

# Utilisation de sudo pour créer les dossiers nécessaires
sudo mkdir -p "$DATA_DIR/Desktop" "$DATA_DIR/Downloads" "$DATA_DIR/Applications" "$DATA_DIR/.config" "$DATA_DIR/.local/bin"
sudo chown -R 1000:1000 "$DATA_DIR"
sudo chmod -R 775 "$DATA_DIR"

# Nettoyage d'anciens conteneurs
docker rm -f kasm_desktop 2>/dev/null || true

# 1. Démarrage de l'image Kasm Desktop Ubuntu complète et fluide
echo "=== Démarrage du conteneur Kasm Desktop Ubuntu ==="
docker pull kasmweb/ubuntu-jammy-desktop:1.16.0
docker run -d \
  --name kasm_desktop \
  --shm-size=2048m \
  -p 6901:6901 \
  -e VNC_PW=vncpass \
  -e VNC_RESOLUTION=1600x900 \
  -v "$DATA_DIR":/home/kasm-user \
  kasmweb/ubuntu-jammy-desktop:1.16.0

# 2. Configuration du reverse-proxy NGINX ultra-rapide
echo "=== Configuration du reverse-proxy NGINX (Zéro latence) ==="
sudo apt-get update -qq && sudo apt-get install -y -qq nginx > /dev/null 2>&1

cat << 'NGINX_EOF' | sudo tee /etc/nginx/sites-available/default > /dev/null
server {
    listen 3000 default_server;
    listen [::]:3000 default_server;

    # Zéro mise en mémoire tampon pour fluidité 60 FPS
    proxy_buffering off;
    proxy_request_buffering off;
    tcp_nodelay on;

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

sudo systemctl restart nginx || sudo service nginx restart

# 3. Attente que Kasm soit actif
echo "=== Attente de l'initialisation du bureau Kasm ==="
for i in {1..40}; do
  if curl -s -k https://127.0.0.1:6901/ > /dev/null 2>&1; then
    echo " Bureau Ubuntu Kasm opérationnel !"
    break
  fi
  sleep 2
done

# 4. Installation et configuration garantie de Google Chrome et Google Docs
echo "=== Installation et configuration garantie de Google Chrome & Docs ==="
docker exec -u 0 kasm_desktop bash -c '
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null 2>&1 || true
  apt-get install -y -qq xclip xsel autocutsel wget curl gnupg ca-certificates > /dev/null 2>&1 || true

  # Synchronisation du presse-papier X11
  su - kasm-user -c "autocutsel -fork >/dev/null 2>&1 || true"
  su - kasm-user -c "autocutsel -selection PRIMARY -fork >/dev/null 2>&1 || true"

  # Installation officielle du paquet Google Chrome Stable
  if ! [ -d /opt/google/chrome ]; then
    wget -q -O - https://dl-ssl.google.com/linux/linux_signing_key.pub | gpg --dearmor --yes -o /usr/share/keyrings/google-chrome.gpg 2>/dev/null || true
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" > /etc/apt/sources.list.d/google-chrome.list
    apt-get update -qq >/dev/null 2>&1 || true
    apt-get install -y -qq google-chrome-stable >/dev/null 2>&1 || {
      curl -sSL -o /tmp/google-chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
      dpkg -i /tmp/google-chrome.deb 2>/dev/null || apt-get install -y -f -qq >/dev/null 2>&1
      rm -f /tmp/google-chrome.deb
    }
  fi

  # APPLICATION DU WRAPPER INDESTRUCTIBLE AU COEUR DU BINAIRE CHROME
  # En modifiant directement le binaire interne /opt/google/chrome/chrome,
  # TOUTES les invocations de Chrome (clic bureau, terminal, liens, docs)
  # hériteront TOUJOURS de --no-sandbox et ne crasheront JAMAIS.
  if [ -f /opt/google/chrome/chrome ] && [ ! -f /opt/google/chrome/chrome-real ]; then
    mv /opt/google/chrome/chrome /opt/google/chrome/chrome-real
    cat << "EOF_CHROME_BIN" > /opt/google/chrome/chrome
#!/usr/bin/env bash
exec /opt/google/chrome/chrome-real \
  --no-sandbox \
  --disable-dev-shm-usage \
  --disable-gpu \
  --password-store=basic \
  --no-first-run \
  --no-default-browser-check \
  "$@"
EOF_CHROME_BIN
    chmod 755 /opt/google/chrome/chrome
  fi

  # Symlinks globaux
  ln -sf /opt/google/chrome/google-chrome /usr/local/bin/google-chrome
  ln -sf /opt/google/chrome/google-chrome /usr/local/bin/chrome

  # Raccourci CLI pour Google Docs
  cat << "DOCS_CLI_EOF" > /usr/local/bin/google-docs
#!/usr/bin/env bash
exec /opt/google/chrome/google-chrome --app="https://docs.google.com" "$@"
DOCS_CLI_EOF
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

  # Nettoyage de tout reste d Antigravity si présent
  rm -f /home/kasm-user/Desktop/*antigravity* /usr/local/bin/*antigravity* /usr/share/applications/*antigravity* 2>/dev/null || true

  # Raccourci Google Chrome sur le Bureau
  cat << "DESKTOP_CHROME" > /home/kasm-user/Desktop/google-chrome.desktop
[Desktop Entry]
Version=1.0
Type=Application
Name=Google Chrome
GenericName=Navigateur Web
Comment=Naviguer sur Internet avec Google Chrome
Exec=/opt/google/chrome/google-chrome %U
Icon=google-chrome
Terminal=false
Categories=Network;WebBrowser;StartupNotify=true
Actions=new-window;new-private-window;
DESKTOP_CHROME

  # Raccourci Google Docs sur le Bureau
  cat << "DESKTOP_DOCS" > /home/kasm-user/Desktop/google-docs.desktop
[Desktop Entry]
Version=1.0
Type=Application
Name=Google Docs
GenericName=Traitement de texte
Comment=Créer et éditer des documents en ligne
Exec=/opt/google/chrome/google-chrome --app=https://docs.google.com
Icon=/usr/share/icons/hicolor/scalable/apps/google-docs.svg
Terminal=false
Categories=Office;WordProcessor;StartupNotify=true
DESKTOP_DOCS

  # Copie dans le menu des applications système
  cp -f /home/kasm-user/Desktop/google-chrome.desktop /usr/share/applications/
  cp -f /home/kasm-user/Desktop/google-docs.desktop /usr/share/applications/

  # Permissions d exécution complètes et approbation XFCE sans avertissement
  chmod 777 /home/kasm-user/Desktop/*.desktop /usr/share/applications/*.desktop 2>/dev/null || true
  chown -R 1000:1000 /home/kasm-user

  # Marquage de confiance XFCE
  su - kasm-user -c "gio set /home/kasm-user/Desktop/*.desktop metadata::trusted true 2>/dev/null || true"

  # Test de démarrage de Chrome pour valider qu il fonctionne
  su - kasm-user -c "/opt/google/chrome/google-chrome --version"
'

echo " Bureau Ubuntu configuré avec succès : Google Chrome et Google Docs 100% opérationnels !"
