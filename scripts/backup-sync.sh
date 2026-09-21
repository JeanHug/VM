#!/usr/bin/env bash
set -e

PERSIST_DIR="/home/runner/vm_data"
mkdir -p "$PERSIST_DIR"

ACTION="${1:-backup}"

if [ "$ACTION" = "restore" ]; then
  echo "=== [PERSISTENCE] Restauration des données utilisateur ==="
  TMP_DIR=$(mktemp -d)
  
  # Tentative de clonage de la branche de persistance 'data-persist'
  if git clone --depth 1 --branch data-persist "https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git" "$TMP_DIR" 2>/dev/null; then
    if [ -f "$TMP_DIR/user_data.tar.gz" ]; then
      echo " Archive trouvée, décompression dans $PERSIST_DIR..."
      tar -xzf "$TMP_DIR/user_data.tar.gz" -C "$PERSIST_DIR"
      sudo chown -R 1000:1000 "$PERSIST_DIR"
      echo " Données restaurées avec succès !"
    else
      echo "Aucune archive trouvée dans la branche data-persist. Initialisation d'un profil vierge."
    fi
  else
    echo "Branche data-persist non trouvée. Elle sera automatiquement créée lors de la première sauvegarde."
  fi
  rm -rf "$TMP_DIR"

elif [ "$ACTION" = "backup" ]; then
  echo "=== [PERSISTENCE] Création d'une sauvegarde incrémentale ==="
  if [ ! -d "$PERSIST_DIR" ]; then
    echo "Répertoire $PERSIST_DIR introuvable, rien à sauvegarder."
    exit 0
  fi

  ARCHIVE_PATH="/tmp/user_data.tar.gz"
  # Exclure les caches lourds et temporaires de navigateur pour une synchro ultra-rapide
  tar --exclude='.cache' \
      --exclude='*/Cache/*' \
      --exclude='*/Crashpad/*' \
      --exclude='*/GPUCache/*' \
      --exclude='*.tmp' \
      -czf "$ARCHIVE_PATH" -C "$PERSIST_DIR" . 2>/dev/null || true

  TMP_GIT=$(mktemp -d)
  cd "$TMP_GIT"
  git init
  git config user.name "VM-Relay-Bot"
  git config user.email "bot@vm.relay.local"
  
  # Récupération de la branche distante si elle existe
  git remote add origin "https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
  git fetch --depth 1 origin data-persist 2>/dev/null || true
  git checkout -B data-persist
  
  mv "$ARCHIVE_PATH" ./user_data.tar.gz
  echo "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" > last_backup_timestamp.txt
  
  git add user_data.tar.gz last_backup_timestamp.txt
  git commit -m "chore(backup): snapshot data cycle ${RELAY_CYCLE:-1} [$(date -u +'%Y-%m-%d %H:%M:%S UTC')]" || true
  
  # Push forcé pour écraser l'ancien état par la dernière version propre
  git push --force origin data-persist 2>&1 | sed 's/'"$GH_TOKEN"'/REDACTED/g' || true
  
  cd /
  rm -rf "$TMP_GIT"
  echo " Sauvegarde de l'état enregistrée dans la branche data-persist !"
fi
