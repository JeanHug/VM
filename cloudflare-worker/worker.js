/**
 * Cloudflare Worker: Relais Sécurisé d'Accès VM & Authentification
 * Passerelle sécurisée pour JeanHug/VM
 * Déployé sous le nom "vm" (https://vm.hugdu77777.workers.dev)
 */

const GITHUB_RAW_BASE = "https://raw.githubusercontent.com/JeanHug/VM/tunnel-url/";

export default {
  async fetch(request, env, ctx) {
    // Gestion des requêtes CORS pre-flight
    if (request.method === "OPTIONS") {
      return new Response(null, {
        headers: {
          "Access-Control-Allow-Origin": "*",
          "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
          "Access-Control-Allow-Headers": "Content-Type, Authorization",
          "Access-Control-Max-Age": "86400",
        },
      });
    }

    const url = new URL(request.url);
    const corsHeaders = {
      "Access-Control-Allow-Origin": "*",
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store, no-cache, must-revalidate",
    };

    // Endpoint de statut / santé public (ne divulgue aucun secret ni tunnel)
    if (url.pathname === "/api/health" || url.pathname === "/health") {
      return new Response(JSON.stringify({ status: "ok", service: "VM Secure Relay Worker", script: "vm" }), {
        headers: corsHeaders,
      });
    }

    // Récupération du mot de passe fourni par le client
    let userPassword = url.searchParams.get("password") || url.searchParams.get("pin");
    
    // Vérification de l'en-tête Authorization (Bearer <pwd>)
    const authHeader = request.headers.get("Authorization");
    if (authHeader) {
      const match = authHeader.match(/^Bearer\s+(.*)$/i);
      if (match) {
        userPassword = match[1].trim();
      } else if (!userPassword) {
        userPassword = authHeader.trim();
      }
    }

    // Si méthode POST, analyse du corps JSON
    if (request.method === "POST") {
      try {
        const body = await request.json();
        userPassword = body.password || body.pin || userPassword;
      } catch (e) {
        // Corps non-JSON, on garde la valeur des paramètres
      }
    }

    // Mot de passe secret attendu configuré dans l'environnement Cloudflare Worker (secret PASS)
    const expectedPassword = env.PASS || env.ACCESS_PIN;

    // Validation stricte du mot de passe
    if (!expectedPassword || !userPassword || userPassword !== expectedPassword) {
      return new Response(
        JSON.stringify({
          authenticated: false,
          error: "Mot de passe incorrect",
        }),
        { status: 401, headers: corsHeaders }
      );
    }

    // Authentification réussie : Récupération sécurisée des tunnels depuis GitHub
    try {
      const timestamp = Date.now();
      const fetchJson = async (filename) => {
        try {
          const res = await fetch(`${GITHUB_RAW_BASE}${filename}?_t=${timestamp}`, {
            headers: { "User-Agent": "Cloudflare-VM-Relay" },
            cf: { cacheTtl: 0, cacheEverything: false }
          });
          if (res.ok) {
            return await res.json();
          }
        } catch (err) {
          console.error(`Failed to fetch ${filename}:`, err);
        }
        return null;
      };

      const [dataLinux, dataAndroid, dataGeneric] = await Promise.all([
        fetchJson("tunnels-linux.json"),
        fetchJson("tunnels-android.json"),
        fetchJson("tunnels.json")
      ]);

      const primaryLinux = dataLinux?.cloudflare || dataLinux?.primary || dataLinux?.lhrLife || dataGeneric?.cloudflare || dataGeneric?.primary || null;
      const primaryAndroid = dataAndroid?.cloudflare || dataAndroid?.primary || dataAndroid?.lhrLife || null;

      // Redirection directe si demandée via ?target=linux ou ?target=android
      const target = url.searchParams.get("target")?.toLowerCase();
      if (target === "linux" && primaryLinux) {
        return Response.redirect(primaryLinux, 302);
      }
      if (target === "android" && primaryAndroid) {
        const androidUrl = primaryAndroid.replace(/\/+$/, "") + "/#!action=stream&udid=127.0.0.1:5555&player=mse";
        return Response.redirect(androidUrl, 302);
      }

      return new Response(
        JSON.stringify({
          authenticated: true,
          status: "online",
          linux: dataLinux || (dataGeneric ? { ...dataGeneric, name: "Ubuntu Linux Desktop" } : null),
          android: dataAndroid || null,
          primary: primaryLinux,
          cloudflare: primaryLinux,
          updated_at: dataLinux?.updated_at || dataAndroid?.updated_at || dataGeneric?.updated_at || new Date().toISOString(),
        }),
        { headers: corsHeaders }
      );
    } catch (err) {
      return new Response(
        JSON.stringify({
          authenticated: true,
          status: "error",
          error: "Impossible de récupérer les tunnels: " + err.message,
        }),
        { status: 500, headers: corsHeaders }
      );
    }
  },
};

