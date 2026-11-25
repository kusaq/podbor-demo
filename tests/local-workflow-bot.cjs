// Run the actual Edge handler with an in-memory Telegram transport and a local-only DB.
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const assert=require('node:assert/strict'),{webcrypto,randomInt}=require('node:crypto');
const {stripTypeScriptTypes}=require('node:module');
module.exports=async function localBot(db) {
 const base='../supabase/functions/telegram-bot/',core=await import(base+'core.mjs');
 const {searchSource}=await import(base+'sources.mjs');
 const env={BOT_TOKEN:'600:local-test',BOT_WORKER_SECRET:'local-worker-'.repeat(4),TELEGRAM_WEBHOOK_SECRET:'local-webhook-'.repeat(4)};
 const messages=[],pending=[];let handler,updateId=randomInt(10000000,90000000),photo;
 async function transport(input,options){
  const u=new URL(input);assert.equal(u.hostname,'api.telegram.org');
  if(u.pathname==='/file/bot600:local-test/photos/car.jpg')return new Response(photo);
  const method=u.pathname.split('/').pop(),body=JSON.parse(options.body);
  if(method==='getFile')return Response.json({ok:true,result:{file_path:'photos/car.jpg'}});
  assert.equal(method,'sendMessage');const message_id=messages.length+1;
  messages.push({...body,message_id});return Response.json({ok:true,result:{message_id}});
 }
 const code=fs.readFileSync(path.join(__dirname,base,'index.ts'),'utf8').replace(/^import .*;\n/gm,'');
 vm.runInNewContext(stripTypeScriptTypes(code,{mode:'transform'}),{...core,searchSource,createClient:()=>db,
  Deno:{serve:f=>handler=f,env:{get:k=>env[k]}},EdgeRuntime:{waitUntil:p=>pending.push(p)},crypto:webcrypto,
  URL,Request,Response,Blob,FormData,TextEncoder,TextDecoder,AbortSignal,Uint8Array,btoa,fetch:transport});
 async function invoke(path,headers,body){
  const response=await handler(new Request('https://podbor.test/telegram-bot'+path,{method:'POST',headers,body:JSON.stringify(body)}));
  assert.equal(response.status,200);await Promise.all(pending.splice(0));
 }
 return {messages,drain:()=>invoke('/drain',{'x-worker-secret':env.BOT_WORKER_SECRET},{}),
  photo(bytes){photo=bytes;},
  async send(user,content){
   const id=++updateId;
   await invoke('',{'x-telegram-bot-api-secret-token':env.TELEGRAM_WEBHOOK_SECRET},{update_id:id,message:{...content,message_id:id,chat:{type:'private',id:user},from:{id:user}}});
  }};
};
