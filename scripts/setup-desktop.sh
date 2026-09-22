#!/usr/bin/env bash
set -e

echo "=================================================="
echo "    CONFIGURATION BUREAU LINUX UBUNTU MODERNE     "
echo "=================================================="

DATA_DIR="/home/runner/vm_data"

# Utilisation de sudo pour créer les dossiers afin d éviter toute erreur Permission Denied
sudo mkdir -p "$DATA_DIR/Desktop" "$DATA_DIR/Downloads" "$DATA_DIR/Applications" "$DATA_DIR/.config" "$DATA_DIR/.local/bin" "$DATA_DIR/.local/share/applications" "$DATA_DIR/.local/share/icons"
sudo chown -R 1000:1000 "$DATA_DIR"
sudo chmod -R 775 "$DATA_DIR"

# 1. Démarrage de l'image Kasm Desktop Ubuntu complète avec shm-size et seccomp unconfined
echo "=== Téléchargement et lancement de Kasm Desktop Ubuntu ==="
docker pull kasmweb/ubuntu-jammy-desktop:1.16.0
docker run -d   --name kasm_desktop   --shm-size=2048m   --security-opt seccomp=unconfined   -p 6901:6901   -e VNC_PW=vncpass   -v "$DATA_DIR":/home/kasm-user   kasmweb/ubuntu-jammy-desktop:1.16.0

# 2. Configuration du reverse-proxy NGINX avec Authentification transparente
echo "=== Configuration du reverse-proxy NGINX ==="
sudo apt-get update -qq && sudo apt-get install -y -qq nginx > /dev/null 2>&1
cat << 'NGINX_EOF' | sudo tee /etc/nginx/sites-available/default > /dev/null
server {
    listen 3000 default_server;
    listen [::]:3000 default_server;

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
sudo systemctl restart nginx

# 3. Attente que Kasm soit actif
echo "=== Attente de l'initialisation du bureau Kasm ==="
for i in {1..40}; do
  if curl -s -k https://127.0.0.1:6901/ > /dev/null 2>&1; then
    echo " Bureau moderne Ubuntu Kasm opérationnel !"
    break
  fi
  sleep 2
done

# 4. Installation des applications par défaut & optimisations conteneur
echo "=== Installation des applications par défaut & Presse-papier ==="
docker exec -u 0 kasm_desktop bash -c '
  # Utilitaires de presse-papier X11 et outils de base
  apt-get update -qq >/dev/null 2>&1 || true
  apt-get install -y -qq xclip xsel autocutsel wget curl ca-certificates gnupg libgbm1 libnss3 libasound2 fonts-liberation >/dev/null 2>&1 || true
  
  # Synchronisation automatique du presse-papier X11 (PRIMARY <-> CLIPBOARD)
  su - kasm-user -c "autocutsel -fork >/dev/null 2>&1 || true"
  su - kasm-user -c "autocutsel -selection PRIMARY -fork >/dev/null 2>&1 || true"

  # ----------------------------------------------------
  # 1. APPLICATION PAR DÉFAUT : GOOGLE CHROME OFFICIEL
  # ----------------------------------------------------
  echo "Vérification / Installation de Google Chrome officiel..."
  if ! [ -x /opt/google/chrome/google-chrome ] && ! [ -x /usr/bin/google-chrome-stable ]; then
    curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | gpg --dearmor --yes -o /usr/share/keyrings/google-chrome.gpg 2>/dev/null || true
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" > /etc/apt/sources.list.d/google-chrome.list
    apt-get update -qq >/dev/null 2>&1 || true
    apt-get install -y -qq google-chrome-stable >/dev/null 2>&1 || {
      curl -sSL -o /tmp/google-chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
      apt-get install -y -qq /tmp/google-chrome.deb >/dev/null 2>&1 || (apt-get install -y -qq -f >/dev/null 2>&1 && dpkg -i /tmp/google-chrome.deb >/dev/null 2>&1 || true)
      rm -f /tmp/google-chrome.deb
    }
  fi

  # Wrapper multi-fallback pour Google Chrome adapté au conteneur Docker (sans crash sandbox)
  cat << "CHROME_WRAPPER_EOF" > /usr/local/bin/google-chrome
#!/usr/bin/env bash
for bin in /opt/google/chrome/google-chrome /usr/bin/google-chrome-stable /usr/bin/google-chrome /usr/bin/chromium-browser /usr/bin/chromium; do
  if [ -x "$bin" ]; then
    exec "$bin" --no-sandbox --disable-dev-shm-usage --disable-gpu --password-store=basic --no-default-browser-check "$@"
  fi
done
echo "Navigateur Google Chrome non trouvé" >&2
exit 1
CHROME_WRAPPER_EOF
  chmod +x /usr/local/bin/google-chrome
  cp -f /usr/local/bin/google-chrome /usr/local/bin/chrome 2>/dev/null || true

  # Rétention des configurations Chrome
  mkdir -p /home/kasm-user/.config
  cat << "FLAGS_EOF" > /home/kasm-user/.config/chrome-flags.conf
--no-sandbox
--disable-dev-shm-usage
--disable-gpu
--password-store=basic
--no-default-browser-check
--disable-features=Translate
FLAGS_EOF
  cp /home/kasm-user/.config/chrome-flags.conf /home/kasm-user/.config/chromium-flags.conf 2>/dev/null || true

  # ----------------------------------------------------
  # 2. APPLICATION PAR DÉFAUT : GOOGLE ANTIGRAVITY (DERNIÈRE VERSION OFFICIELLE)
  # ----------------------------------------------------
  echo "Installation de la dernière version officielle Google Antigravity IDE & Hub..."
  mkdir -p /opt/google-antigravity /opt/antigravity-hub /home/kasm-user/Desktop

  # 1. Antigravity IDE (version 2.5.5 stable officielle Google)
  if [ ! -d /opt/google-antigravity/bin ] && [ ! -f /opt/google-antigravity/antigravity ]; then
    echo "Téléchargement d Antigravity IDE (2.5.5)..."
    curl -fsSL -o /tmp/antigravity-ide.tar.gz "https://edgedl.me.gvt1.com/edgedl/release2/j0qc3/antigravity/stable/2.5.5-4923483625488384/linux-x64/Antigravity%20IDE.tar.gz" || true
    if [ -f /tmp/antigravity-ide.tar.gz ]; then
      tar -xzf /tmp/antigravity-ide.tar.gz -C /opt/google-antigravity/ --strip-components=1 2>/dev/null || tar -xzf /tmp/antigravity-ide.tar.gz -C /opt/google-antigravity/ 2>/dev/null || true
      rm -f /tmp/antigravity-ide.tar.gz
    fi
  fi

  # 2. Antigravity Hub v2.15.1
  if [ ! -f /opt/antigravity-hub/antigravity ] && [ ! -d /opt/antigravity-hub/bin ]; then
    echo "Téléchargement d Antigravity Hub (v2.15.1)..."
    curl -fsSL -o /tmp/antigravity-hub.tar.gz "https://storage.googleapis.com/antigravity-public/antigravity-hub/2.15.1-5880727900913664/linux-x64/Antigravity.tar.gz" || true
    if [ -f /tmp/antigravity-hub.tar.gz ]; then
      tar -xzf /tmp/antigravity-hub.tar.gz -C /opt/antigravity-hub/ --strip-components=1 2>/dev/null || tar -xzf /tmp/antigravity-hub.tar.gz -C /opt/antigravity-hub/ 2>/dev/null || true
      rm -f /tmp/antigravity-hub.tar.gz
    fi
  fi

  # 3. Installation CLI officiel agy
  echo "Installation du CLI Antigravity officiel (agy)..."
  export HOME=/home/kasm-user
  curl -fsSL https://antigravity.google/cli/install.sh | bash 2>/dev/null || true
  if [ -f /home/kasm-user/.local/bin/agy ]; then
    cp -f /home/kasm-user/.local/bin/agy /usr/local/bin/agy 2>/dev/null || true
    cp -f /home/kasm-user/.local/bin/agy /usr/local/bin/antigravity-cli 2>/dev/null || true
  fi

  # 4. Création des wrappers d exécution optimisés pour conteneur Docker (--no-sandbox)
  cat << "ANTIGRAVITY_WRAPPER_EOF" > /usr/local/bin/antigravity
#!/usr/bin/env bash
for bin in   "/opt/google-antigravity/antigravity"   "/opt/google-antigravity/Antigravity"   "/opt/google-antigravity/Antigravity IDE/antigravity"   "/opt/google-antigravity/bin/antigravity"   "/opt/antigravity-hub/antigravity"   "/opt/antigravity-hub/Antigravity"   "/usr/local/bin/agy"
do
  if [ -x "$bin" ]; then
    exec "$bin" --no-sandbox --disable-dev-shm-usage --disable-gpu "$@"
  fi
done
exec /usr/local/bin/google-chrome --app="https://antigravity.google" "$@"
ANTIGRAVITY_WRAPPER_EOF
  chmod +x /usr/local/bin/antigravity
  cp -f /usr/local/bin/antigravity /usr/local/bin/google-antigravity 2>/dev/null || true

  # ----------------------------------------------------
  # 3. APPLICATION PAR DÉFAUT : GOOGLE DOCS
  # ----------------------------------------------------
  echo "Configuration de Google Docs..."
  cat << "DOCS_WRAPPER_EOF" > /usr/local/bin/google-docs
#!/usr/bin/env bash
exec /usr/local/bin/google-chrome --app="https://docs.google.com" --class="google-docs" "$@"
DOCS_WRAPPER_EOF
  chmod +x /usr/local/bin/google-docs

  # Icône SVG officielle Google Docs
  cat << "DOCS_SVG_EOF" > /usr/share/icons/hicolor/scalable/apps/google-docs.svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48" width="128" height="128">
  <path fill="#4285F4" d="M30 4H12C9.79 4 8 5.79 8 8v32c0 2.21 1.79 4 4 4h24c2.21 0 4-1.79 4-4V16L30 4z"/>
  <path fill="#A1C2FA" d="M30 4v12h12L30 4z"/>
  <path fill="#FFFFFF" d="M16 22h16v2.5H16zm0 6h16v2.5H16zm0 6h10v2.5H16z"/>
</svg>
DOCS_SVG_EOF
  cp -f /usr/share/icons/hicolor/scalable/apps/google-docs.svg /usr/share/pixmaps/google-docs.svg 2>/dev/null || true

  # ----------------------------------------------------
  # CRÉATION DES RACCOURCIS SUR LE BUREAU ET MENU SYSTÈME
  # ----------------------------------------------------
  mkdir -p /home/kasm-user/Desktop /usr/share/applications

  # Raccourci Google Chrome
  cat << "DESKTOP_CHROME_EOF" > /home/kasm-user/Desktop/google-chrome.desktop
[Desktop Entry]
Version=1.0
Type=Application
Name=Google Chrome
GenericName=Navigateur Web
Comment=Accéder à Internet et à vos applications web
Exec=/usr/local/bin/google-chrome %U
Icon=google-chrome
Terminal=false
Categories=Network;WebBrowser;StartupNotify=true
Actions=new-window;new-private-window;
DESKTOP_CHROME_EOF

  # Raccourci Google Antigravity
  cat << "DESKTOP_ANTIGRAVITY_EOF" > /home/kasm-user/Desktop/google-antigravity.desktop
[Desktop Entry]
Version=1.0
Type=Application
Name=Google Antigravity
GenericName=Plateforme IA Agentique & IDE
Comment=Plateforme de Développement Agentique & IA Autonome Google
Exec=/usr/local/bin/antigravity %U
Icon=/usr/share/icons/hicolor/scalable/apps/google-antigravity.svg
Terminal=false
Categories=Development;IDE;Utility;StartupNotify=true
DESKTOP_ANTIGRAVITY_EOF

  # Raccourci Google Docs
  cat << "DESKTOP_DOCS_EOF" > /home/kasm-user/Desktop/google-docs.desktop
[Desktop Entry]
Version=1.0
Type=Application
Name=Google Docs
GenericName=Traitement de texte en ligne
Comment=Créer et éditer des documents avec Google Docs
Exec=/usr/local/bin/google-docs %U
Icon=/usr/share/icons/hicolor/scalable/apps/google-docs.svg
Terminal=false
Categories=Office;WordProcessor;StartupNotify=true
DESKTOP_DOCS_EOF

  # Copie dans le menu des applications système XFCE
  cp -f /home/kasm-user/Desktop/google-chrome.desktop /usr/share/applications/
  cp -f /home/kasm-user/Desktop/google-antigravity.desktop /usr/share/applications/
  cp -f /home/kasm-user/Desktop/google-docs.desktop /usr/share/applications/

  # Rendre tous les raccourcis exécutables et approuvés pour XFCE
  chmod +x /home/kasm-user/Desktop/*.desktop /usr/share/applications/*.desktop 2>/dev/null || true
  chown -R 1000:1000 /home/kasm-user/Desktop /home/kasm-user/.config
  su - kasm-user -c "gio set /home/kasm-user/Desktop/*.desktop metadata::trusted true 2>/dev/null || true"

  chown -R 1000:1000 /home/kasm-user
'

echo " Bureau, Google Chrome, Google Antigravity et Google Docs configurés et prêts !"
