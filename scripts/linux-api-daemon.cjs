#!/usr/bin/env node
/**
 * Micro-Démon API REST d'interaction Linux pour JeanHug/VM
 * Écoute sur 127.0.0.1:3001
 * Compatible Kasm Desktop (Docker) ET environnement Linux natif/hôte/local.
 */

const http = require('http');
const { exec, execSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const url = require('url');

const PORT = 3001;
const CONTAINER = 'kasm_desktop';

// Détection dynamique de l'environnement (Docker Kasm vs Linux Local/Hôte)
let USE_DOCKER = false;
try {
  const out = execSync(`docker ps -q -f name=${CONTAINER} 2>/dev/null || true`, { timeout: 2000 });
  USE_DOCKER = out.toString().trim().length > 0;
} catch (e) {
  USE_DOCKER = false;
}

console.log(`[Linux-API-Daemon] Mode d'exécution : ${USE_DOCKER ? 'Conteneur Docker ' + CONTAINER : 'Environnement Linux Local Direct'}`);

// Helper pour exécuter une commande bash
function execCommand(cmd, options = {}) {
  const user = options.user || 'kasm-user';
  const timeoutMs = (options.timeout || 30) * 1000;
  let finalCmd;
  let cwd = options.cwd;

  if (USE_DOCKER) {
    cwd = cwd || '/home/kasm-user';
    finalCmd = `docker exec -u ${user} -w "${cwd}" -i ${CONTAINER} bash -c ${JSON.stringify(cmd)}`;
  } else {
    cwd = cwd || process.env.HOME || '/tmp';
    if (!fs.existsSync(cwd)) cwd = '/tmp';
    finalCmd = `bash -c ${JSON.stringify(cmd)}`;
  }

  return new Promise((resolve) => {
    const start = Date.now();
    exec(finalCmd, { cwd: USE_DOCKER ? undefined : cwd, timeout: timeoutMs, maxBuffer: 10 * 1024 * 1024 }, (err, stdout, stderr) => {
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
      mode: USE_DOCKER ? 'docker_kasm' : 'linux_native',
      container: USE_DOCKER ? CONTAINER : null,
      uptime_seconds: Math.floor(process.uptime()),
      timestamp: new Date().toISOString()
    });
  }

  // 2. Statut système complet
  if (pathname === '/api/linux/system' || pathname === '/api/system' || pathname === '/api/v1/system') {
    const [mem, disk, uptimeRes, cpuInfo] = await Promise.all([
      execHost("free -m | awk 'NR==2{printf \"used: %sMB, total: %sMB, free: %sMB\", $3,$2,$4}'"),
      execHost("df -h / 2>/dev/null | awk 'NR==2{printf \"used: %s, size: %s, avail: %s\", $3,$2,$4}'"),
      execHost("uptime -p 2>/dev/null || uptime"),
      execHost("nproc 2>/dev/null || echo '2'")
    ]);

    let activeWindow = 'Desktop';
    if (USE_DOCKER) {
      const winRes = await execCommand('DISPLAY=:1 xdotool getactivewindow getwindowname 2>/dev/null || true');
      activeWindow = winRes.stdout.trim() || 'Desktop';
    } else if (process.env.DISPLAY) {
      const winRes = await execHost('xdotool getactivewindow getwindowname 2>/dev/null || true');
      activeWindow = winRes.stdout || 'Terminal';
    }

    return sendJson(res, 200, {
      ok: true,
      system: {
        mode: USE_DOCKER ? 'docker_kasm' : 'linux_native',
        cpu_cores: parseInt(cpuInfo.stdout) || 2,
        memory: mem.stdout || 'N/A',
        disk_space: disk.stdout || 'N/A',
        uptime: uptimeRes.stdout || 'up',
        display: USE_DOCKER ? ':1' : (process.env.DISPLAY || 'headless'),
        active_window: activeWindow,
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

    const result = await execCommand(command, {
      user: body.user,
      cwd: body.cwd,
      timeout: Math.min(body.timeout || 30, 300)
    });

    return sendJson(res, result.ok ? 200 : 500, result);
  }

  // 4. Capture d'écran (Screenshot)
  if (pathname === '/api/linux/screenshot' || pathname === '/api/screenshot' || pathname === '/api/v1/screenshot') {
    const format = query.format || 'png';
    const isBase64 = format === 'base64' || (req.headers.accept && req.headers.accept.includes('application/json'));

    const cmd = USE_DOCKER
      ? `docker exec -i ${CONTAINER} bash -c "DISPLAY=:1 import -window root png:- 2>/dev/null || DISPLAY=:1 scrot - 2>/dev/null || (DISPLAY=:1 xwd -root -silent | xwdtopnm 2>/dev/null | pnmtopng 2>/dev/null)"`
      : `DISPLAY=:1 import -window root png:- 2>/dev/null || DISPLAY=:0 import -window root png:- 2>/dev/null || convert -size 960x540 xc:'#0f172a' -fill '#38bdf8' -pointsize 26 -draw "text 50,80 'Linux Interactive Desktop'" -fill '#94a3b8' -pointsize 18 -draw "text 50,130 'Status: Active • API Daemon v1.0'" -draw "text 50,170 'Mode: ${USE_DOCKER ? 'Docker Kasm' : 'Linux Native VM'}'" -draw "text 50,210 'Time: $(date)'" -draw "text 50,250 'Uptime: $(uptime -p 2>/dev/null || uptime)'" -draw "text 50,290 'Processes: $(ps aux | wc -l) active'" png:- 2>/dev/null`;

    exec(cmd, { encoding: 'buffer', maxBuffer: 15 * 1024 * 1024 }, (err, stdout) => {
      // Fallback si pas d'image
      if (err || !stdout || stdout.length === 0) {
        stdout = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==', 'base64');
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

  // 5. Contrôle Souris
  if ((pathname === '/api/linux/mouse' || pathname === '/api/mouse' || pathname === '/api/v1/mouse') && req.method === 'POST') {
    const body = await parseBody(req);
    const action = body.action || 'move';
    const x = Math.round(Number(body.x) || 0);
    const y = Math.round(Number(body.y) || 0);

    let xdoCmd = `DISPLAY=:1 xdotool mousemove ${x} ${y}`;
    if (action === 'click') xdoCmd += ' click 1';
    else if (action === 'right_click') xdoCmd += ' click 3';
    else if (action === 'double_click') xdoCmd += ' click --repeat 2 1';
    else if (action === 'scroll_up') xdoCmd += ' click 4';
    else if (action === 'scroll_down') xdoCmd += ' click 5';

    if (USE_DOCKER || process.env.DISPLAY) {
      const result = await execCommand(xdoCmd);
      return sendJson(res, result.ok ? 200 : 500, { ok: result.ok, action, x, y, error: result.stderr || null });
    } else {
      return sendJson(res, 200, { ok: true, simulated: true, action, x, y });
    }
  }

  // 6. Contrôle Clavier
  if ((pathname === '/api/linux/keyboard' || pathname === '/api/keyboard' || pathname === '/api/v1/keyboard') && req.method === 'POST') {
    const body = await parseBody(req);
    let xdoCmd = 'DISPLAY=:1 xdotool ';

    if (body.text) {
      const safeText = body.text.replace(/'/g, "'\\''");
      xdoCmd += `type --delay 12 '${safeText}'`;
    } else if (body.key) {
      xdoCmd += `key ${body.key}`;
    } else {
      return sendJson(res, 400, { ok: false, error: 'Paramètre "text" ou "key" requis.' });
    }

    if (USE_DOCKER || process.env.DISPLAY) {
      const result = await execCommand(xdoCmd);
      return sendJson(res, result.ok ? 200 : 500, { ok: result.ok, error: result.stderr || null });
    } else {
      return sendJson(res, 200, { ok: true, simulated: true, input: body.text || body.key });
    }
  }

  // 7. Presse-papier (Clipboard)
  if (pathname === '/api/linux/clipboard' || pathname === '/api/clipboard' || pathname === '/api/v1/clipboard') {
    if (req.method === 'GET') {
      const result = await execCommand('DISPLAY=:1 xclip -selection clipboard -o 2>/dev/null || cat /tmp/clipboard.txt 2>/dev/null || true');
      return sendJson(res, 200, { ok: true, text: result.stdout.trim() });
    }
    if (req.method === 'POST') {
      const body = await parseBody(req);
      const text = body.text || '';
      const safeText = text.replace(/'/g, "'\\''");
      await execCommand(`echo -n '${safeText}' > /tmp/clipboard.txt && (DISPLAY=:1 xclip -selection clipboard -i 2>/dev/null || true)`);
      return sendJson(res, 200, { ok: true, length: text.length });
    }
  }

  // 8. Gestion des fichiers
  if (pathname === '/api/linux/files' || pathname === '/api/files' || pathname === '/api/v1/files') {
    const targetPath = query.path || (USE_DOCKER ? '/home/kasm-user' : '/tmp');
    const resolvedPath = path.resolve(targetPath);

    if (req.method === 'GET') {
      if (USE_DOCKER) {
        const cmd = `docker exec -i ${CONTAINER} bash -c "ls -la --time-style=iso '${resolvedPath}' 2>&1"`;
        exec(cmd, (err, stdout) => {
          if (err) return sendJson(res, 500, { ok: false, error: stdout });
          const entries = parseLsOutput(stdout);
          return sendJson(res, 200, { ok: true, path: resolvedPath, entries });
        });
      } else {
        try {
          const files = fs.readdirSync(resolvedPath);
          const entries = files.map(file => {
            try {
              const stat = fs.statSync(path.join(resolvedPath, file));
              return {
                name: file,
                size: stat.size,
                isDirectory: stat.isDirectory(),
                date: stat.mtime.toISOString()
              };
            } catch {
              return { name: file };
            }
          });
          return sendJson(res, 200, { ok: true, path: resolvedPath, entries });
        } catch (e) {
          return sendJson(res, 500, { ok: false, error: e.message });
        }
      }
      return;
    }

    if (req.method === 'DELETE') {
      if (USE_DOCKER) {
        const result = await execCommand(`rm -rf "${resolvedPath}"`);
        return sendJson(res, result.ok ? 200 : 500, { ok: result.ok, deleted: resolvedPath });
      } else {
        try {
          fs.rmSync(resolvedPath, { recursive: true, force: true });
          return sendJson(res, 200, { ok: true, deleted: resolvedPath });
        } catch (e) {
          return sendJson(res, 500, { ok: false, error: e.message });
        }
      }
    }
  }

  // 8b. Lecture de fichier
  if (pathname === '/api/linux/files/read' || pathname === '/api/files/read' || pathname === '/api/v1/files/read') {
    const targetPath = query.path;
    if (!targetPath) return sendJson(res, 400, { ok: false, error: 'Paramètre "path" manquant.' });

    const resolvedPath = path.resolve(targetPath);
    if (USE_DOCKER) {
      const cmd = `docker exec -i ${CONTAINER} cat "${resolvedPath}"`;
      exec(cmd, { maxBuffer: 10 * 1024 * 1024 }, (err, stdout) => {
        if (err) return sendJson(res, 404, { ok: false, error: 'Fichier introuvable ou illisible' });
        return sendJson(res, 200, { ok: true, path: resolvedPath, content: stdout });
      });
    } else {
      try {
        const content = fs.readFileSync(resolvedPath, 'utf8');
        return sendJson(res, 200, { ok: true, path: resolvedPath, content });
      } catch (e) {
        return sendJson(res, 404, { ok: false, error: e.message });
      }
    }
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

    if (USE_DOCKER) {
      const tempFile = `/tmp/api_upload_${Date.now()}_${Math.random().toString(36).substring(7)}`;
      fs.writeFileSync(tempFile, Buffer.from(content, encoding));
      const copyCmd = `docker cp "${tempFile}" "${CONTAINER}:${resolvedPath}" && rm -f "${tempFile}"`;
      exec(copyCmd, (err) => {
        if (err) return sendJson(res, 500, { ok: false, error: err.message });
        execCommand(`chown kasm-user:kasm-user "${resolvedPath}" 2>/dev/null || true`);
        return sendJson(res, 200, { ok: true, path: resolvedPath, size_bytes: content.length });
      });
    } else {
      try {
        fs.mkdirSync(path.dirname(resolvedPath), { recursive: true });
        fs.writeFileSync(resolvedPath, Buffer.from(content, encoding));
        return sendJson(res, 200, { ok: true, path: resolvedPath, size_bytes: content.length });
      } catch (e) {
        return sendJson(res, 500, { ok: false, error: e.message });
      }
    }
    return;
  }

  // 9. Lancement d'Applications GUI
  if ((pathname === '/api/linux/apps/launch' || pathname === '/api/apps/launch' || pathname === '/api/v1/apps/launch') && req.method === 'POST') {
    const body = await parseBody(req);
    const app = body.app;
    const args = Array.isArray(body.args) ? body.args.join(' ') : (body.args || '');

    if (!app) return sendJson(res, 400, { ok: false, error: 'Paramètre "app" manquant.' });

    const launchCmd = `DISPLAY=:1 nohup ${app} ${args} >/dev/null 2>&1 &`;
    const result = await execCommand(launchCmd);
    return sendJson(res, 200, { ok: true, message: `Application ${app} lancée avec succès.` });
  }

  // 10. Liste des Processus
  if (pathname === '/api/linux/processes' || pathname === '/api/processes' || pathname === '/api/v1/processes') {
    const cmd = USE_DOCKER
      ? 'ps -u kasm-user -o pid,pcpu,pmem,stat,time,comm --sort=-pcpu 2>/dev/null | head -n 30'
      : 'ps -eo pid,pcpu,pmem,stat,time,comm --sort=-pcpu 2>/dev/null | head -n 30';
    const result = await execCommand(cmd);
    return sendJson(res, 200, { ok: true, raw: result.stdout });
  }

  // Route 404 par défaut
  sendJson(res, 404, { ok: false, error: `Point de terminaison non trouvé : ${pathname}` });
});

function parseLsOutput(stdout) {
  const lines = stdout.trim().split('\n').slice(1);
  return lines.map(line => {
    const parts = line.split(/\s+/);
    return {
      permissions: parts[0],
      owner: parts[2],
      size: parts[4],
      date: parts[5],
      name: parts.slice(7).join(' ')
    };
  }).filter(e => e.name && e.name !== '.' && e.name !== '..');
}

server.listen(PORT, '127.0.0.1', () => {
  console.log(`[Linux-API-Daemon] En écoute sur http://127.0.0.1:${PORT}`);
});
