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

# 1. Démarrage de l'image Kasm Desktop Ubuntu complète
echo "=== Téléchargement et lancement de Kasm Desktop Ubuntu ==="
docker pull kasmweb/ubuntu-jammy-desktop:1.16.0
docker run -d   --name kasm_desktop   --shm-size=2048m   -p 6901:6901   -e VNC_PW=vncpass   -v "$DATA_DIR":/home/kasm-user   kasmweb/ubuntu-jammy-desktop:1.16.0

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
  # Utilitaires de presse-papier X11
  apt-get update -qq && apt-get install -y -qq xclip xsel autocutsel wget curl ca-certificates gnupg > /dev/null 2>&1 || true
  
  # Synchronisation automatique du presse-papier X11 (PRIMARY <-> CLIPBOARD)
  su - kasm-user -c "autocutsel -fork >/dev/null 2>&1 || true"
  su - kasm-user -c "autocutsel -selection PRIMARY -fork >/dev/null 2>&1 || true"

  # ----------------------------------------------------
  # 1. APPLICATION PAR DÉFAUT : GOOGLE CHROME
  # ----------------------------------------------------
  echo "Vérification / Installation de Google Chrome officiel..."
  if ! command -v google-chrome &>/dev/null && ! command -v google-chrome-stable &>/dev/null; then
    curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | gpg --dearmor --yes -o /usr/share/keyrings/google-chrome.gpg 2>/dev/null || true
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" > /etc/apt/sources.list.d/google-chrome.list
    apt-get update -qq > /dev/null 2>&1 || true
    apt-get install -y -qq google-chrome-stable > /dev/null 2>&1 || {
      curl -sSL -o /tmp/google-chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
      apt-get install -y -qq /tmp/google-chrome.deb > /dev/null 2>&1 || true
      rm -f /tmp/google-chrome.deb
    }
  fi

  # Wrapper global pour Google Chrome adapté au conteneur Docker (sans crash sandbox)
  cat << "CHROME_WRAPPER_EOF" > /usr/local/bin/google-chrome
#!/usr/bin/env bash
CHROME_BIN="/usr/bin/google-chrome-stable"
exec "$CHROME_BIN" --no-sandbox --disable-dev-shm-usage --password-store=basic --no-default-browser-check "$@"
CHROME_WRAPPER_EOF
  chmod +x /usr/local/bin/google-chrome
  cp -f /usr/local/bin/google-chrome /usr/local/bin/chrome 2>/dev/null || true

  # Rétention des configurations Chrome
  mkdir -p /home/kasm-user/.config
  cat << "FLAGS_EOF" > /home/kasm-user/.config/chrome-flags.conf
--no-sandbox
--disable-dev-shm-usage
--password-store=basic
--no-default-browser-check
--disable-features=Translate
FLAGS_EOF
  cp /home/kasm-user/.config/chrome-flags.conf /home/kasm-user/.config/chromium-flags.conf 2>/dev/null || true

  # ----------------------------------------------------
  # 2. APPLICATION PAR DÉFAUT : GOOGLE ANTIGRAVITY 2.0
  # ----------------------------------------------------
  echo "Configuration de Google Antigravity 2.0..."
  # Installation du CLI officiel Antigravity (agy)
  export HOME=/home/kasm-user
  curl -fsSL https://antigravity.google/cli/install.sh | bash 2>/dev/null || true
  if [ -f /home/kasm-user/.local/bin/agy ]; then
    cp -f /home/kasm-user/.local/bin/agy /usr/local/bin/agy 2>/dev/null || true
    cp -f /home/kasm-user/.local/bin/agy /usr/local/bin/antigravity-cli 2>/dev/null || true
  fi
  # Wrapper exécutable CLI
  cat << "ANTIGRAVITY_WRAPPER_EOF" > /usr/local/bin/google-antigravity
#!/usr/bin/env bash
exec /usr/local/bin/google-chrome --app="https://antigravity.google" --class="google-antigravity" "$@"
ANTIGRAVITY_WRAPPER_EOF
  chmod +x /usr/local/bin/google-antigravity
  cp -f /usr/local/bin/google-antigravity /usr/local/bin/antigravity 2>/dev/null || true

  # Icône SVG moderne Antigravity 2.0 (Gemini / Antigravity Prism Star)
  mkdir -p /usr/share/icons/hicolor/scalable/apps /usr/share/pixmaps /home/kasm-user/.local/share/icons
  cat << "ANTIGRAVITY_SVG_EOF" > /usr/share/icons/hicolor/scalable/apps/google-antigravity.svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="128" height="128">
  <defs>
    <linearGradient id="bgGrad" x1="0%" y1="0%" x2="100%" y2="100%">
      <stop offset="0%" stop-color="#1B1C20"/>
      <stop offset="100%" stop-color="#0E0F12"/>
    </linearGradient>
    <linearGradient id="sparkGrad" x1="0%" y1="0%" x2="100%" y2="100%">
      <stop offset="0%" stop-color="#4285F4"/>
      <stop offset="30%" stop-color="#9B72CB"/>
      <stop offset="70%" stop-color="#D96570"/>
      <stop offset="100%" stop-color="#F4B400"/>
    </linearGradient>
    <linearGradient id="orbitGrad" x1="0%" y1="0%" x2="100%" y2="100%">
      <stop offset="0%" stop-color="#4285F4"/>
      <stop offset="50%" stop-color="#34A853"/>
      <stop offset="100%" stop-color="#FBBC04"/>
    </linearGradient>
  </defs>
  <rect width="64" height="64" rx="14" fill="url(#bgGrad)" stroke="#2D3035" stroke-width="1.5"/>
  <ellipse cx="32" cy="32" rx="25" ry="11" fill="none" stroke="url(#orbitGrad)" stroke-width="2.2" transform="rotate(-28 32 32)" stroke-dasharray="5 3"/>
  <path d="M32 10 C32 22 22 32 10 32 C22 32 32 42 32 54 C32 42 42 32 54 32 C42 32 32 22 32 10 Z" fill="url(#sparkGrad)"/>
  <circle cx="32" cy="32" r="3.5" fill="#FFFFFF"/>
</svg>
ANTIGRAVITY_SVG_EOF
  cp -f /usr/share/icons/hicolor/scalable/apps/google-antigravity.svg /usr/share/pixmaps/google-antigravity.svg
  cp -f /usr/share/icons/hicolor/scalable/apps/google-antigravity.svg /home/kasm-user/.local/share/icons/google-antigravity.svg 2>/dev/null || true

  # ----------------------------------------------------
  # 3. APPLICATION PAR DÉFAUT : GOOGLE DOCS
  # ----------------------------------------------------
  echo "Configuration de Google Docs..."
  # Wrapper exécutable CLI
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
  cp -f /usr/share/icons/hicolor/scalable/apps/google-docs.svg /usr/share/pixmaps/google-docs.svg
  cp -f /usr/share/icons/hicolor/scalable/apps/google-docs.svg /home/kasm-user/.local/share/icons/google-docs.svg 2>/dev/null || true

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
Categories=Network;WebBrowser;
StartupNotify=true
Actions=new-window;new-private-window;
DESKTOP_CHROME_EOF

  # Raccourci Google Antigravity 2.0
  cat << "DESKTOP_ANTIGRAVITY_EOF" > /home/kasm-user/Desktop/google-antigravity.desktop
[Desktop Entry]
Version=1.0
Type=Application
Name=Google Antigravity 2.0
GenericName=Plateforme IA Agentique
Comment=Plateforme de Développement Agentique & IA Autonome
Exec=/usr/local/bin/google-antigravity %U
Icon=/usr/share/icons/hicolor/scalable/apps/google-antigravity.svg
Terminal=false
Categories=Development;IDE;Utility;
StartupNotify=true
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
Categories=Office;WordProcessor;
StartupNotify=true
DESKTOP_DOCS_EOF

  # Copie dans le menu des applications système XFCE
  cp -f /home/kasm-user/Desktop/google-chrome.desktop /usr/share/applications/
  cp -f /home/kasm-user/Desktop/google-antigravity.desktop /usr/share/applications/
  cp -f /home/kasm-user/Desktop/google-docs.desktop /usr/share/applications/

  # Rendre tous les raccourcis exécutables et approuvés pour XFCE
  chmod +x /home/kasm-user/Desktop/*.desktop /usr/share/applications/*.desktop 2>/dev/null || true
  chown -R 1000:1000 /home/kasm-user/Desktop

  # Autorisation de sécurité sans avertissement dans XFCE Desktop
  su - kasm-user -c "gio set /home/kasm-user/Desktop/*.desktop metadata::trusted true 2>/dev/null || true"

  # Snapshot des paquets initiaux pour détecter les nouveaux paquets installés
  if [ ! -f /etc/initial_manual_packages.txt ]; then
    apt-mark showmanual 2>/dev/null > /etc/initial_manual_packages.txt || true
  fi

  # Guide clair sur le Bureau avec explications copier/coller
  cat << "README_EOF" > /home/kasm-user/Desktop/INSTALLER_DES_APPLICATIONS.txt
=====================================================
 GUIDE RAPIDE VM LINUX & APPLICATIONS PAR DÉFAUT
=====================================================

1. APPLICATIONS PRÉ-INSTALLÉES PAR DÉFAUT :
   - Google Chrome (Navigateur web officiel complet)
   - Google Antigravity 2.0 (Plateforme agentique & IA)
   - Google Docs (Suite bureautique & traitement de texte)
   --> Tous les raccourcis sont directement sur votre Bureau !

2. COMMENT COLLER DES COMMANDES DANS LA VM :
   - DANS LE TERMINAL LINUX : Utilisez CLIC DROIT -> COLLER
     ou faites CTRL + MAJ + V (car sous Linux, Ctrl+V dans
     un terminal est un caractère spécial).
   - VIA LE PANNEAU KASM (Très pratique) :
     Cliquez sur la petite flèche au milieu du bord gauche
     de votre écran pour ouvrir le menu Kasm, puis cliquez
     sur l icône Presse-papier (Clipboard) pour coller n importe
     quel texte immédiatement dans la VM !
   - EN PLEIN ÉCRAN : Ouvrez le lien dans un nouvel onglet
     pour autoriser l accès direct au presse-papier du navigateur.

3. INSTALLATION DE NOUVELLES APPLICATIONS (APT) :
   Ouvrez le Terminal et tapez simplement :
   sudo apt update && sudo apt install -y <nom_du_paquet>
   Exemples :
   - VLC : sudo apt install -y vlc
   - GIMP : sudo apt install -y gimp
   - Geany (Éditeur) : sudo apt install -y geany
   - Python 3 : sudo apt install -y python3-pip
   - Node.js : sudo apt install -y nodejs npm
   --> Toutes vos applications sont 100% conservées entre les relais !
=====================================================
README_EOF

  # Script raccourci install-app
  cat << "INSTALLER_SCRIPT" > /usr/local/bin/install-app
#!/usr/bin/env bash
if [ -z "$1" ]; then
  echo "Usage: install-app <nom_du_paquet>"
  exit 1
fi
sudo apt-get update && sudo apt-get install -y "$@"
INSTALLER_SCRIPT
  chmod +x /usr/local/bin/install-app

  # Réinstallation automatique des paquets précédemment installés si la liste existe
  if [ -f /home/kasm-user/.installed_packages.txt ] && [ -s /home/kasm-user/.installed_packages.txt ]; then
    echo "Réinstallation automatique des paquets..."
    apt-get update -qq && xargs -r -a /home/kasm-user/.installed_packages.txt apt-get install -y --no-install-recommends || true
  fi

  chown -R 1000:1000 /home/kasm-user
'

echo " Bureau, Google Chrome, Antigravity 2.0 et Google Docs configurés !"
