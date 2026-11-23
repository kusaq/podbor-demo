// Read-only by default. --apply is an explicit deployment step, never run by tests.
const apply=process.argv.includes('--apply');const url=process.env.TELEGRAM_WEBHOOK_URL;
if(!url||!/^https:\/\/[a-z0-9.-]+\/functions\/v1\/telegram-bot$/.test(url))throw Error('Set TELEGRAM_WEBHOOK_URL to the HTTPS Edge Function URL');
const payload={url,allowed_updates:['message','callback_query'],max_connections:1,drop_pending_updates:false};
if(!apply){console.log(JSON.stringify({...payload,secret_token:'[configured from TELEGRAM_WEBHOOK_SECRET]'},null,2));console.log('Dry run. Nothing changed.');process.exit(0)}
const token=process.env.BOT_TOKEN,secret=process.env.TELEGRAM_WEBHOOK_SECRET;
if(!token||!secret||!/^[A-Za-z0-9_-]{32,256}$/.test(secret))throw Error('Set BOT_TOKEN and TELEGRAM_WEBHOOK_SECRET in the environment');
async function telegram(method,body){const r=await fetch('https://api.telegram.org/bot'+token+'/'+method,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(body),signal:AbortSignal.timeout(20000)});const j=await r.json();if(!j.ok)throw Error('Telegram rejected operation: '+(j.error_code||r.status));return j.result}
const current=await telegram('getWebhookInfo',{});if(current.url&&current.url!==url&&!process.argv.includes('--replace-existing'))throw Error('Another webhook is configured. Review it before using --replace-existing.');
await telegram('setWebhook',{...payload,secret_token:secret});const actual=await telegram('getWebhookInfo',{});if(actual.url!==url)throw Error('Webhook verification failed');console.log('Webhook configured and verified. Pending updates were preserved.');
