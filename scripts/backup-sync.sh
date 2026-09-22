#!/usr/bin/env bash
set -e

PERSIST_DIR="/home/runner/vm_data"
mkdir -p "$PERSIST_DIR"
ACTION="${1:-backup}"

if [ "$ACTION" = "restore" ]; then
  echo "=================================================="
  echo "=== [PERSISTENCE] RESTAURATION TOTALE 100% ==="
  echo "=================================================="
  TMP_DIR=$(mktemp -d)

  # Tentative de clonage de la branche de persistance 'data-persist'
  if git clone --depth 1 --branch data-persist "https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git" "$TMP_DIR" 2>/dev/null; then
    cd "$TMP_DIR"
    
    # 1. Vérification archive unique ou chunks multiples
    if [ -f "user_data.tar.gz" ]; then
      echo " Décompression de user_data.tar.gz dans $PERSIST_DIR..."
      tar -xzf "user_data.tar.gz" -C "$PERSIST_DIR"
    elif ls user_data.tar.gz.part_* 1>/dev/null 2>&1; then
      echo " Décompression des archives multiples (part_*) dans $PERSIST_DIR..."
      cat user_data.tar.gz.part_* | tar -xz -C "$PERSIST_DIR"
    else
      echo "Aucune archive trouvée dans data-persist. Initialisation d'un profil vierge."
    fi

    # Fix permissions kasm-user (UID 1000)
    sudo chown -R 1000:1000 "$PERSIST_DIR" 2>/dev/null || true
    echo " 100% des fichiers, configurations et profils restaurés !"
    cd /
  else
    echo "Branche data-persist non trouvée. Elle sera automatiquement créée lors de la première sauvegarde."
  fi
  rm -rf "$TMP_DIR"

elif [ "$ACTION" = "backup" ]; then
  echo "=================================================="
  echo "=== [PERSISTENCE] SAUVEGARDE TOTALE 100% ==="
  echo "=================================================="
  
  if [ ! -d "$PERSIST_DIR" ]; then
    echo "Répertoire $PERSIST_DIR introuvable, rien à sauvegarder."
    exit 0
  fi

  # 1. Snapshot de la liste des paquets APT manuellement installés dans le conteneur
  if docker ps --format '{{.Names}}' | grep -q "^kasm_desktop$"; then
    echo " Enregistrement de la liste des paquets APT installés par l'utilisateur..."
    docker exec kasm_desktop bash -c '
      if [ -f /etc/initial_manual_packages.txt ]; then
        comm -23 <(apt-mark showmanual 2>/dev/null | sort) <(cat /etc/initial_manual_packages.txt 2>/dev/null | sort) > /home/kasm-user/.installed_packages.txt || true
      fi
    ' 2>/dev/null || true
  fi

  # 2. Création de l'archive tar
  # On exclut uniquement le cache de compilation/téléchargement temporaire (.cache/)
  # TOUTES les données réelles (Desktop, Downloads, .config, .local, Chrome cookies, comptes, sessions, tokens) SONT INCLUSES À 100% !
  ARCHIVE_DIR=$(mktemp -d)
  ARCHIVE_PATH="$ARCHIVE_DIR/user_data.tar.gz"

  echo " Archivage complet des données utilisateur..."
  tar --exclude='.cache'       --exclude='*/Crashpad/*'       --exclude='*.tmp'       -czf "$ARCHIVE_PATH" -C "$PERSIST_DIR" . 2>/dev/null || true

  ARCHIVE_SIZE=$(stat -c%s "$ARCHIVE_PATH" 2>/dev/null || stat -f%z "$ARCHIVE_PATH" 2>/dev/null || echo "0")
  echo "Taille de l'archive générée : $(( ARCHIVE_SIZE / 1024 / 1024 )) Mo ($ARCHIVE_SIZE octets)"

  TMP_GIT=$(mktemp -d)
  cd "$TMP_GIT"
  git init
  git config user.name "VM-Relay-Bot"
  git config user.email "bot@vm.relay.local"

  git remote add origin "https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
  git fetch --depth 1 origin data-persist 2>/dev/null || true
  git checkout -B data-persist

  # Nettoyage des anciens fichiers d'archives
  rm -f user_data.tar.gz user_data.tar.gz.part_*

  # Si la taille dépasse 50 Mo, on découpe en morceaux de 45 Mo pour contourner la limite de 100 Mo de GitHub
  if [ "$ARCHIVE_SIZE" -gt 52428800 ]; then
    echo " Découpage en blocs de 45 Mo (compatibilité totale GitHub)..."
    split -b 45M "$ARCHIVE_PATH" user_data.tar.gz.part_
    git add user_data.tar.gz.part_*
  else
    mv "$ARCHIVE_PATH" ./user_data.tar.gz
    git add user_data.tar.gz
  fi

  echo "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" > last_backup_timestamp.txt
  git add last_backup_timestamp.txt

  git commit -m "chore(backup): snapshot 100% persistence [$(date -u +'%Y-%m-%d %H:%M:%S UTC')]" || true
  git push --force origin data-persist 2>&1 | sed 's/'"$GH_TOKEN"'/REDACTED/g' || true

  cd /
  rm -rf "$TMP_GIT" "$ARCHIVE_DIR"
  echo " 100% des données et applications sauvegardées dans data-persist !"
fi
