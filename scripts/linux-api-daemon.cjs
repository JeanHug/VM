#!/usr/bin/env node
/**
 * Micro-Démon API REST d'interaction Linux pour JeanHug/VM
 * Écoute sur 127.0.0.1:3001 et pilote l'environnement X11 / Kasm Desktop.
 */

const http = require('http');
const { exec, spawn } = require('child_process');
const fs = require('fs');
const path = require('path');
const url = require('url');

const PORT = 3001;
const CONTAINER = 'kasm_desktop';
const VM_DATA_DIR = '/home/runner/vm_data';

// Helper pour exécuter une commande bash dans le conteneur Kasm
function execInKasm(cmd, options = {}) {
  const user = options.user || 'kasm-user';
  const cwd = options.cwd || '/home/kasm-user';
  const timeoutMs = (options.timeout || 30) * 1000;
  
  // Échappement des guillemets
  const dockerCmd = `docker exec -u ${user} -w "${cwd}" -i ${CONTAINER} bash -c ${JSON.stringify(cmd)}`;
  
  return new Promise((resolve) => {
    const start = Date.now();
    exec(dockerCmd, { timeout: timeoutMs, maxBuffer: 10 * 1024 * 1024 }, (err, stdout, stderr) => {
      resolve({
        ok: !err || err.code === 0,
        exit_code: err ? (err.code || 1) : 0,
        stdout: stdout || '',
        stderr: stderr || (err ? err.message : ''),
        execution_time_ms: Date.now() - start
      });
    });
  });
}

// Helper pour exécuter sur le runner hôte
function execHost(cmd, timeoutSec = 15) {
  return new Promise((resolve) => {
    exec(cmd, { timeout: timeoutSec * 1000 }, (err, stdout, stderr) => {
      resolve({
        ok: !err || err.code === 0,
        stdout: stdout ? stdout.trim() : '',
        stderr: stderr ? stderr.trim() : ''
      });
    });
  });
}

function parseBody(req) {
  return new Promise((resolve) => {
    let body = '';
    req.on('data', chunk => {
      body += chunk;
      if (body.length > 20 * 1024 * 1024) req.destroy(); // 20MB limit
    });
    req.on('end', () => {
      try {
        resolve(body ? JSON.parse(body) : {});
      } catch (e) {
        resolve({ _raw: body });
      }
    });
  });
}

function sendJson(res, statusCode, data) {
  res.writeHead(statusCode, {
    'Content-Type': 'application/json; charset=utf-8',
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type, Authorization'
  });
  res.end(JSON.stringify(data, null, 2));
}

const server = http.createServer(async (req, res) => {
  // CORS Preflight
  if (req.method === 'OPTIONS') {
    res.writeHead(204, {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type, Authorization',
      'Access-Control-Max-Age': '86400'
    });
    res.end();
    return;
  }

  const parsedUrl = url.parse(req.url, true);
  const pathname = parsedUrl.pathname.replace(/\/+$/, '') || '/';
  const query = parsedUrl.query || {};

  // 1. Health check
  if (pathname === '/api/health' || pathname === '/api/v1/health') {
    return sendJson(res, 200, {
      status: 'ok',
      service: 'Linux VM Interaction Daemon',
      container: CONTAINER,
      uptime_seconds: Math.floor(process.uptime()),
      timestamp: new Date().toISOString()
    });
  }

  // 2. Statut système complet
  if (pathname === '/api/linux/system' || pathname === '/api/system' || pathname === '/api/v1/system') {
    const [mem, disk, uptimeRes, cpuInfo] = await Promise.all([
      execHost("free -m | awk 'NR==2{printf \"used: %sMB, total: %sMB, free: %sMB\", $3,$2,$4}'"),
      execHost("df -h /home/runner/vm_data 2>/dev/null | awk 'NR==2{printf \"used: %s, size: %s, avail: %s\", $3,$2,$4}'"),
      execHost("uptime -p"),
      execHost("nproc")
    ]);

    const activeWindow = await execInKasm('DISPLAY=:1 xdotool getactivewindow getwindowname 2>/dev/null || true');

    return sendJson(res, 200, {
      ok: true,
      system: {
        cpu_cores: parseInt(cpuInfo.stdout) || 2,
        memory: mem.stdout,
        disk_vm_data: disk.stdout,
        uptime: uptimeRes.stdout,
        display: ':1',
        active_window: activeWindow.stdout.trim() || 'Desktop',
        timestamp: new Date().toISOString()
      }
    });
  }

  // 3. Exécution de commande Shell
  if ((pathname === '/api/linux/exec' || pathname === '/api/exec' || pathname === '/api/v1/exec') && req.method === 'POST') {
    const body = await parseBody(req);
    const command = body.command;

    if (!command || typeof command !== 'string') {
      return sendJson(res, 400, { ok: false, error: 'Paramètre "command" (string) manquant.' });
    }

    const result = await execInKasm(command, {
      user: body.user === 'root' ? '0' : 'kasm-user',
      cwd: body.cwd || '/home/kasm-user',
      timeout: Math.min(body.timeout || 30, 300)
    });

    return sendJson(res, result.ok ? 200 : 500, result);
  }

  // 4. Capture d'écran (Screenshot)
  if (pathname === '/api/linux/screenshot' || pathname === '/api/screenshot' || pathname === '/api/v1/screenshot') {
    const format = query.format || 'png';
    const isBase64 = format === 'base64' || (req.headers.accept && req.headers.accept.includes('application/json'));

    const cmd = `docker exec -i ${CONTAINER} bash -c "DISPLAY=:1 import -window root png:- 2>/dev/null || DISPLAY=:1 scrot - 2>/dev/null || (DISPLAY=:1 xwd -root -silent | xwdtopnm 2>/dev/null | pnmtopng 2>/dev/null)"`;

    exec(cmd, { encoding: 'buffer', maxBuffer: 15 * 1024 * 1024 }, (err, stdout) => {
      if (err || !stdout || stdout.length === 0) {
        return sendJson(res, 500, { ok: false, error: 'Impossible de capturer l\'écran X11', details: err?.message });
      }

      if (isBase64) {
        return sendJson(res, 200, {
          ok: true,
          format: 'png',
          size_bytes: stdout.length,
          data: `data:image/png;base64,${stdout.toString('base64')}`
        });
      }

      res.writeHead(200, {
        'Content-Type': 'image/png',
        'Content-Length': stdout.length,
        'Access-Control-Allow-Origin': '*',
        'Cache-Control': 'no-cache, no-store, must-revalidate'
      });
      res.end(stdout);
    });
    return;
  }

  // 5. Contrôle Souris (xdotool)
  if ((pathname === '/api/linux/mouse' || pathname === '/api/mouse' || pathname === '/api/v1/mouse') && req.method === 'POST') {
    const body = await parseBody(req);
    const action = body.action || 'move'; // move, click, right_click, double_click, scroll_up, scroll_down
    const x = Math.round(Number(body.x) || 0);
    const y = Math.round(Number(body.y) || 0);

    let xdoCmd = `DISPLAY=:1 xdotool mousemove ${x} ${y}`;
    if (action === 'click') xdoCmd += ' click 1';
    else if (action === 'right_click') xdoCmd += ' click 3';
    else if (action === 'double_click') xdoCmd += ' click --repeat 2 1';
    else if (action === 'scroll_up') xdoCmd += ' click 4';
    else if (action === 'scroll_down') xdoCmd += ' click 5';

    const result = await execInKasm(xdoCmd);
    return sendJson(res, result.ok ? 200 : 500, { ok: result.ok, action, x, y, error: result.stderr || null });
  }

  // 6. Contrôle Clavier (xdotool)
  if ((pathname === '/api/linux/keyboard' || pathname === '/api/keyboard' || pathname === '/api/v1/keyboard') && req.method === 'POST') {
    const body = await parseBody(req);
    let xdoCmd = 'DISPLAY=:1 xdotool ';

    if (body.text) {
      // Type de texte direct avec temporisation fluide
      const safeText = body.text.replace(/'/g, "'\\''");
      xdoCmd += `type --delay 12 '${safeText}'`;
    } else if (body.key) {
      // Touche ou combinaison (ex: Return, BackSpace, Control_L+c, alt+Tab)
      xdoCmd += `key ${body.key}`;
    } else {
      return sendJson(res, 400, { ok: false, error: 'Paramètre "text" ou "key" requis.' });
    }

    const result = await execInKasm(xdoCmd);
    return sendJson(res, result.ok ? 200 : 500, { ok: result.ok, error: result.stderr || null });
  }

  // 7. Presse-papier (Clipboard)
  if (pathname === '/api/linux/clipboard' || pathname === '/api/clipboard' || pathname === '/api/v1/clipboard') {
    if (req.method === 'GET') {
      const result = await execInKasm('DISPLAY=:1 xclip -selection clipboard -o 2>/dev/null || true');
      return sendJson(res, 200, { ok: true, text: result.stdout });
    }
    if (req.method === 'POST') {
      const body = await parseBody(req);
      const text = body.text || '';
      const safeText = text.replace(/'/g, "'\\''");
      const result = await execInKasm(`echo -n '${safeText}' | DISPLAY=:1 xclip -selection clipboard -i`);
      return sendJson(res, 200, { ok: result.ok, length: text.length });
    }
  }

  // 8. Gestion des fichiers (/home/kasm-user)
  if (pathname === '/api/linux/files' || pathname === '/api/files' || pathname === '/api/v1/files') {
    const targetPath = query.path || '/home/kasm-user';

    // Sécurité élémentaire : empêcher de sortir du scope autorisé
    const resolvedPath = path.resolve(targetPath);
    if (!resolvedPath.startsWith('/home/kasm-user') && !resolvedPath.startsWith('/tmp') && !resolvedPath.startsWith('/home/runner/vm_data')) {
      return sendJson(res, 403, { ok: false, error: 'Accès restreint au dossier /home/kasm-user ou /tmp.' });
    }

    if (req.method === 'GET') {
      const cmd = `docker exec -i ${CONTAINER} bash -c "ls -la --time-style=iso '${resolvedPath}' 2>&1"`;
      exec(cmd, (err, stdout) => {
        if (err) return sendJson(res, 500, { ok: false, error: stdout });
        const lines = stdout.trim().split('\n').slice(1);
        const entries = lines.map(line => {
          const parts = line.split(/\s+/);
          return {
            permissions: parts[0],
            owner: parts[2],
            size: parts[4],
            date: parts[5],
            name: parts.slice(7).join(' ')
          };
        }).filter(e => e.name && e.name !== '.' && e.name !== '..');
        return sendJson(res, 200, { ok: true, path: resolvedPath, entries });
      });
      return;
    }

    if (req.method === 'DELETE') {
      const result = await execInKasm(`rm -rf "${resolvedPath}"`);
      return sendJson(res, result.ok ? 200 : 500, { ok: result.ok, deleted: resolvedPath });
    }
  }

  // 8b. Lecture de fichier
  if (pathname === '/api/linux/files/read' || pathname === '/api/files/read' || pathname === '/api/v1/files/read') {
    const targetPath = query.path;
    if (!targetPath) return sendJson(res, 400, { ok: false, error: 'Paramètre "path" manquant.' });

    const resolvedPath = path.resolve(targetPath);
    const cmd = `docker exec -i ${CONTAINER} cat "${resolvedPath}"`;
    exec(cmd, { maxBuffer: 10 * 1024 * 1024 }, (err, stdout) => {
      if (err) return sendJson(res, 404, { ok: false, error: 'Fichier introuvable ou illisible' });
      return sendJson(res, 200, { ok: true, path: resolvedPath, content: stdout });
    });
    return;
  }

  // 8c. Écriture de fichier
  if ((pathname === '/api/linux/files/write' || pathname === '/api/files/write' || pathname === '/api/v1/files/write') && req.method === 'POST') {
    const body = await parseBody(req);
    const targetPath = body.path;
    const content = body.content || '';
    const encoding = body.encoding || 'utf8';

    if (!targetPath) return sendJson(res, 400, { ok: false, error: 'Paramètre "path" manquant.' });

    const resolvedPath = path.resolve(targetPath);
    const tempFile = `/tmp/api_upload_${Date.now()}_${Math.random().toString(36).substring(7)}`;
    
    fs.writeFileSync(tempFile, Buffer.from(content, encoding));
    const copyCmd = `docker cp "${tempFile}" "${CONTAINER}:${resolvedPath}" && rm -f "${tempFile}"`;
    
    exec(copyCmd, (err) => {
      if (err) return sendJson(res, 500, { ok: false, error: err.message });
      execInKasm(`chown kasm-user:kasm-user "${resolvedPath}" 2>/dev/null || true`);
      return sendJson(res, 200, { ok: true, path: resolvedPath, size_bytes: content.length });
    });
    return;
  }

  // 9. Lancement d'Applications GUI
  if ((pathname === '/api/linux/apps/launch' || pathname === '/api/apps/launch' || pathname === '/api/v1/apps/launch') && req.method === 'POST') {
    const body = await parseBody(req);
    const app = body.app; // ex: google-chrome, xfce4-terminal, mousepad, thunar
    const args = Array.isArray(body.args) ? body.args.join(' ') : (body.args || '');

    if (!app) return sendJson(res, 400, { ok: false, error: 'Paramètre "app" manquant.' });

    const launchCmd = `DISPLAY=:1 nohup ${app} ${args} >/dev/null 2>&1 &`;
    const result = await execInKasm(launchCmd);
    return sendJson(res, 200, { ok: true, message: `Application ${app} lancée avec succès.` });
  }

  // 10. Liste des Processus
  if (pathname === '/api/linux/processes' || pathname === '/api/processes' || pathname === '/api/v1/processes') {
    const result = await execInKasm('ps -u kasm-user -o pid,pcpu,pmem,stat,time,comm --sort=-pcpu | head -n 30');
    return sendJson(res, 200, { ok: true, raw: result.stdout });
  }

  // Route 404 par défaut
  sendJson(res, 404, { ok: false, error: `Point de terminaison non trouvé : ${pathname}` });
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`[Linux-API-Daemon] En écoute sur http://127.0.0.1:${PORT}`);
});
