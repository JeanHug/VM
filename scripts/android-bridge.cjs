const http = require('http');
const { exec } = require('child_process');
const fs = require('fs');
const path = require('path');

const PORT = 8080;

function runAdb(cmd) {
  return new Promise((resolve) => {
    exec(`adb -s 127.0.0.1:5555 ${cmd}`, { timeout: 5000 }, (err, stdout, stderr) => {
      if (err) {
        resolve({ success: false, error: err.message, stderr });
      } else {
        resolve({ success: true, stdout: stdout.trim() });
      }
    });
  });
}

const server = http.createServer(async (req, res) => {
  // Set CORS headers
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

  if (req.method === 'OPTIONS') {
    res.writeHead(200);
    res.end();
    return;
  }

  const url = new URL(req.url, `http://${req.headers.host}`);

  // API: Health / Status
  if (url.pathname === '/api/status') {
    const boot = await runAdb('shell getprop sys.boot_completed');
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
      online: boot.stdout === '1',
      bootCompleted: boot.stdout === '1',
      timestamp: new Date().toISOString()
    }));
    return;
  }

  // API: Keyevent (Back: 4, Home: 3, AppSwitch: 187, Power: 26, VolUp: 24, VolDown: 25, Enter: 66, Tab: 61, Backspace: 67)
  if (url.pathname === '/api/key') {
    const key = url.searchParams.get('k') || '4';
    const keyMap = {
      'back': '4',
      'home': '3',
      'appswitch': '187',
      'power': '26',
      'volup': '24',
      'voldown': '25',
      'enter': '66',
      'tab': '61',
      'backspace': '67',
      'menu': '82',
      'esc': '111'
    };
    const keycode = keyMap[key.toLowerCase()] || key;
    const result = await runAdb(`shell input keyevent ${keycode}`);
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(result));
    return;
  }

  // API: Type text with full mobile keyboard support (spaces, characters, emojis)
  if (url.pathname === '/api/type') {
    let body = '';
    req.on('data', chunk => body += chunk);
    req.on('end', async () => {
      try {
        const data = body ? JSON.parse(body) : {};
        const text = data.text || url.searchParams.get('t') || '';
        
        if (text) {
          // Format text for ADB shell input text or clipboard
          // Using base64/escaped input or character by character
          const escaped = text.replace(/[%]/g, '%25')
                              .replace(/[ ]/g, '%s')
                              .replace(/[&]/g, '\\&')
                              .replace(/[<]/g, '\\<')
                              .replace(/[>]/g, '\\>')
                              .replace(/[(]/g, '\\(')
                              .replace(/[)]/g, '\\)')
                              .replace(/[']/g, "\\'")
                              .replace(/[""]/g, '\\"')
                              .replace(/[;]/g, '\\;');
          
          await runAdb(`shell input text "${escaped}"`);
          if (data.enter) {
            await runAdb('shell input keyevent 66');
          }
        }
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ success: true }));
      } catch (err) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ success: false, error: err.message }));
      }
    });
    return;
  }

  // API: Touch / Tap
  if (url.pathname === '/api/tap') {
    const x = parseInt(url.searchParams.get('x') || '0', 10);
    const y = parseInt(url.searchParams.get('y') || '0', 10);
    const result = await runAdb(`shell input tap ${x} ${y}`);
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(result));
    return;
  }

  // API: Swipe
  if (url.pathname === '/api/swipe') {
    const x1 = parseInt(url.searchParams.get('x1') || '0', 10);
    const y1 = parseInt(url.searchParams.get('y1') || '0', 10);
    const x2 = parseInt(url.searchParams.get('x2') || '0', 10);
    const y2 = parseInt(url.searchParams.get('y2') || '0', 10);
    const ms = parseInt(url.searchParams.get('ms') || '300', 10);
    const result = await runAdb(`shell input swipe ${x1} ${y1} ${x2} ${y2} ${ms}`);
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(result));
    return;
  }

  // Default fallback
  res.writeHead(404, { 'Content-Type': 'text/plain' });
  res.end('Not Found');
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`Android Bridge API running on 127.0.0.1:${PORT}`);
});
