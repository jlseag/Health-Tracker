// Supabase Edge Function: analyze-meal
// Proxies calls to DeepSeek so the API key never touches the browser.
// Deploy via Supabase dashboard → Edge Functions → Create function
//   name: analyze-meal
//   paste this whole file into the editor → Deploy
// Set secret: Edge Functions → Secrets → add DEEPSEEK_API_KEY

// deno-lint-ignore-file no-explicit-any
Deno.serve(async (req) => {
  const corsHeaders = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
  };
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) {
    return new Response(JSON.stringify({ error: "Missing Authorization header" }), {
      status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const DS_KEY = Deno.env.get("DEEPSEEK_API_KEY");
  if (!DS_KEY) {
    return new Response(JSON.stringify({ error: "DEEPSEEK_API_KEY not configured on server" }), {
      status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  let body: any;
  try { body = await req.json(); }
  catch { return new Response(JSON.stringify({ error: "Invalid JSON body" }), { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }); }

  const items = Array.isArray(body?.items) ? body.items : null;
  if (!items || !items.length) {
    return new Response(JSON.stringify({ error: "items array required" }), {
      status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const itemList = items.map((it: any) => `- ${it.name} (${it.grams}g)`).join("\n");
  const systemPrompt = `You are a nutrition expert. Given a list of foods with their weights in grams, return the estimated macronutrients for each item. Reply ONLY with valid JSON in this exact shape, no other text:
{"items":[{"name":"...","grams":<number>,"calories":<number>,"protein_g":<number>,"carbs_g":<number>,"fat_g":<number>,"fiber_g":<number>}]}
Round values to ONE decimal place (e.g. 4.6, not 5). Use standard USDA-style estimates for common foods.
IMPORTANT: Assume all foods are COOKED/PREPARED (ready to eat) unless the item name explicitly contains "raw" or "uncooked". Rice, pasta, chicken, beef, fish, vegetables — all default to cooked weights and macros. Only treat as raw when the user writes something like "raw tuna", "uncooked rice", or "raw broccoli".`;
  const userPrompt = `Analyze these foods:\n${itemList}\n\nReturn the JSON.`;

  const dsRes = await fetch("https://api.deepseek.com/v1/chat/completions", {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${DS_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: "deepseek-chat",
      messages: [
        { role: "system", content: systemPrompt },
        { role: "user", content: userPrompt },
      ],
      response_format: { type: "json_object" },
      temperature: 0.2,
      max_tokens: 800,
    }),
  });

  if (!dsRes.ok) {
    const errText = await dsRes.text();
    return new Response(JSON.stringify({ error: `DeepSeek: ${errText.slice(0, 200)}` }), {
      status: 502, headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const dsJson = await dsRes.json();
  const content = dsJson?.choices?.[0]?.message?.content;
  if (!content) {
    return new Response(JSON.stringify({ error: "Empty response from DeepSeek" }), {
      status: 502, headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  let parsed: any;
  try { parsed = JSON.parse(content); }
  catch {
    return new Response(JSON.stringify({ error: "Model returned invalid JSON", raw: content }), {
      status: 502, headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  return new Response(JSON.stringify(parsed), {
    status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
});
