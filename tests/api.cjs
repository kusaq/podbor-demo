const assert=require('assert'),fs=require('fs'),vm=require('vm'),{stripTypeScriptTypes}=require('node:module'),{webcrypto}=require('node:crypto');
let code=fs.readFileSync(require('path').join(__dirname, '..', 'supabase/functions/api/index.ts'),'utf8').replace(/^import .*createClient.*;\n/m,'');
code=stripTypeScriptTypes(code); let handler; const calls=[];let stored=null;
const user={tg_id:123456789,name:'Test',role:'manager',active:true};
function query(table){let op='select',data,filters={};const q={select(){return q},eq(k,v){filters[k]=v;return q},order(){return q},insert(d){op='insert';data=d;return q},update(d){op='update';data=d;return q},async maybeSingle(){return result()},async single(){return result()}};function result(){calls.push({table,op,filters,data});if(table==='app_users')return {data:user,error:null};if(table==='user_workspaces'){if(op==='select')return {data:stored,error:null};if(op==='insert'){if(stored)return {data:null,error:{code:'23505'}};stored=data;return {data:{revision:data.revision},error:null}}if(op==='update'){if(stored?.revision!==filters.revision)return {data:null,error:null};stored={...stored,...data};return {data:{revision:data.revision},error:null}}}return {data:[],error:null}}return q}
const token='000000000:synthetic-test-value-not-a-real-bot-token';
const ctx={console:{log(){},error(){}},URLSearchParams,TextEncoder,crypto:webcrypto,Response,Number,Date,Deno:{env:{get:k=>k==='BOT_TOKEN'?token:'unused'},serve:fn=>handler=fn},createClient:()=>({from:query})};vm.createContext(ctx);vm.runInContext(code,ctx);
async function signed(){const params=new URLSearchParams({auth_date:String(Math.floor(Date.now()/1000)),user:JSON.stringify({id:user.tg_id,first_name:'Test'})});const check=[...params.entries()].sort(([a],[b])=>a<b?-1:1).map(([k,v])=>`${k}=${v}`).join('\n');const h=(key,data)=>webcrypto.subtle.importKey('raw',key,{name:'HMAC',hash:'SHA-256'},false,['sign']).then(k=>webcrypto.subtle.sign('HMAC',k,new TextEncoder().encode(data)));const secret=await h(new TextEncoder().encode('WebAppData'),token);const hash=Buffer.from(await h(secret,check)).toString('hex');params.set('hash',hash);return params.toString()}
(async()=>{const initData=await signed();async function run(action,payload={},init=initData){return handler(new Request('https://test.local/',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({initData:init,action,payload})}))}
assert.equal((await run('workspace.get',{},'forged')).status,401);
const state={version:1,settings:{},requests:[],clients:{},offers:[]};
let r=await run('workspace.save',{revision:0,state,user_id:'another'});assert.equal(r.status,200);assert.equal(stored.user_id,String(user.tg_id));
r=await run('workspace.get',{user_id:'another'});assert.equal(r.status,200);assert.equal((await r.json()).revision,1);
r=await run('workspace.save',{revision:0,state});assert.equal(r.status,409);
r=await run('workspace.save',{revision:1,state});assert.equal(r.status,200);
r=await run('workspace.save',{revision:1,state});assert.equal(r.status,409);
r=await run('workspace.save',{revision:2,state:{...state,role:'admin'}});assert.equal(r.status,400);
r=await run('users.list');assert.equal(r.status,403);
console.log('PASS API: HMAC validation, verified identity isolation, workspace read/save, insert/update conflicts, unexpected state rejection, manager access guard');})();
