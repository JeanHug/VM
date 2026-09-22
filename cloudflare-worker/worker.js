/**
 * Cloudflare Worker: Relais Sécurisé d'Accès VM & Authentification
 * Déployable gratuitement sur Cloudflare Workers (workers.cloudflare.com)
 */

const VALID_PIN = "1234"; // Mot de passe par défaut modifiable
const GITHUB_TUNNELS_URL = "https://raw.githubusercontent.com/JeanHug/VM/tunnel-url/tunnels.json";

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

    // Endpoint de statut / vérification
    if (url.pathname === "/api/health") {
      return new Response(JSON.stringify({ status: "ok", service: "VM Relay Worker" }), {
        headers: corsHeaders,
      });
    }

    // Récupération du mot de passe (POST body ou query param pin)
    let userPassword = url.searchParams.get("pin") || url.searchParams.get("password");
    if (request.method === "POST") {
      try {
        const body = await request.json();
        userPassword = body.pin || body.password || userPassword;
      } catch (e) {
        // format non-JSON
      }
    }

    const expectedPin = env.ACCESS_PIN || VALID_PIN;

    // Validation du mot de passe
    if (!userPassword || userPassword !== expectedPin) {
      return new Response(
        JSON.stringify({
          authenticated: false,
          error: "Mot de passe incorrect",
        }),
        { status: 401, headers: corsHeaders }
      );
    }

    // Mot de passe correct : Récupération en direct de l'URL du tunnel GitHub
    try {
      const ghRes = await fetch(`${GITHUB_TUNNELS_URL}?_t=${Date.now()}`, {
        headers: { "User-Agent": "Cloudflare-VM-Relay" },
      });

      if (!ghRes.ok) {
        return new Response(
          JSON.stringify({
            authenticated: true,
            status: "starting",
            message: "VM en cours d'initialisation ou de relai...",
            primary: null,
          }),
          { headers: corsHeaders }
        );
      }

      const tunnelsData = await ghRes.json();
      return new Response(
        JSON.stringify({
          authenticated: true,
          status: tunnelsData.status || "online",
          primary: tunnelsData.primary || tunnelsData.lhrLife || tunnelsData.cloudflare,
          lhrLife: tunnelsData.lhrLife,
          cloudflare: tunnelsData.cloudflare,
          updated_at: tunnelsData.updated_at,
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
