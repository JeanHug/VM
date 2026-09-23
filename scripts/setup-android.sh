#!/usr/bin/env bash
set -e

echo "=================================================="
echo "    CONFIGURATION ANDROID 13 OFFICIEL (BUDTMO)    "
echo "  Mode Normal par Défaut + Injection Auto-Detect  "
echo "=================================================="

DATA_DIR="/home/runner/android_vm_data"
sudo mkdir -p "$DATA_DIR/data"
sudo chown -R 1000:1000 "$DATA_DIR" 2>/dev/null || true
sudo chmod -R 777 "$DATA_DIR" 2>/dev/null || true

# 1. Nettoyage complet
docker rm -f android_vm redroid13 ws_scrcpy 2>/dev/null || true
pkill -9 -f nginx 2>/dev/null || true

# 2. Activation KVM
sudo chmod 666 /dev/kvm 2>/dev/null || true

# 3. Démarrage de l'émulateur officiel avec skin & contrôles d'origine
echo "=== Démarrage du conteneur budtmo/docker-android ==="
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

# 4. Configuration NGINX Reverse-Proxy
# - Par défaut : Affiche l'écran normal complet avec le cadre / boutons comme avant
# - Injection du script & bouton "Mode Détecté / Plein Écran" et détection du clavier
echo "=== Configuration du reverse-proxy NGINX ==="
sudo apt-get update -qq && sudo apt-get install -y -qq nginx > /dev/null 2>&1

cat << 'NGINX_EOF' | sudo tee /etc/nginx/sites-available/default > /dev/null
server {
    listen 3000 default_server;
    listen [::]:3000 default_server;

    proxy_buffering off;
    proxy_request_buffering off;
    tcp_nodelay on;

    # Injection HTML/JS dynamique dans noVNC
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

        sub_filter_types text/html;
        sub_filter '</head>' '
        <style>
          /* Bouton de bascule Mode Détecté / Normal */
          #detectModeToggleBtn {
            position: fixed;
            top: 14px;
            right: 14px;
            z-index: 999999;
            background: rgba(16, 185, 129, 0.95);
            color: #ffffff;
            border: 1px solid rgba(255, 255, 255, 0.3);
            border-radius: 30px;
            padding: 8px 16px;
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
            font-size: 13px;
            font-weight: 600;
            display: flex;
            align-items: center;
            gap: 8px;
            cursor: pointer;
            box-shadow: 0 4px 20px rgba(0,0,0,0.5);
            backdrop-filter: blur(8px);
            transition: all 0.25s ease;
          }
          #detectModeToggleBtn:hover {
            background: rgba(5, 150, 105, 1);
            transform: scale(1.03);
          }
          /* Mode Détecté / Plein Écran Automatique */
          body.detected-fullscreen-mode {
            margin: 0 !important;
            padding: 0 !important;
            overflow: hidden !important;
            background: #000000 !important;
          }
          body.detected-fullscreen-mode #noVNC_control_bar_anchor,
          body.detected-fullscreen-mode #noVNC_control_bar {
            display: none !important;
          }
          body.detected-fullscreen-mode #noVNC_container,
          body.detected-fullscreen-mode #noVNC_canvas {
            width: 100vw !important;
            height: 100vh !important;
            object-fit: contain !important;
          }
        </style>
        <script>
          document.addEventListener("DOMContentLoaded", function() {
            var btn = document.createElement("button");
            btn.id = "detectModeToggleBtn";
            btn.innerHTML = "🔍 Auto-Détection / Plein Écran";
            btn.onclick = function() {
              var isDetected = document.body.classList.toggle("detected-fullscreen-mode");
              if (isDetected) {
                btn.innerHTML = "📱 Mode Normal (Cadre)";
                btn.style.background = "rgba(59, 130, 246, 0.95)";
                if (document.documentElement.requestFullscreen) {
                  document.documentElement.requestFullscreen().catch(function(){});
                }
              } else {
                btn.innerHTML = "🔍 Auto-Détection / Plein Écran";
                btn.style.background = "rgba(16, 185, 129, 0.95)";
                if (document.fullscreenElement && document.exitFullscreen) {
                  document.exitFullscreen().catch(function(){});
                }
              }
            };
            document.body.appendChild(btn);

            // Gestion de sortie du plein écran via touche Échap
            document.addEventListener("fullscreenchange", function() {
              if (!document.fullscreenElement && document.body.classList.contains("detected-fullscreen-mode")) {
                document.body.classList.remove("detected-fullscreen-mode");
                btn.innerHTML = "🔍 Auto-Détection / Plein Écran";
                btn.style.background = "rgba(16, 185, 129, 0.95)";
              }
            });
          });
        </script>
        </head>';
        sub_filter_once on;
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
echo " VM Android prête et accessible en mode normal !"
echo "=================================================="
