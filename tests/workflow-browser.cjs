// Run on a disposable local Postgres database with the project schemas installed.
const assert=require('node:assert/strict'), fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const {execFileSync}=require('node:child_process'),{randomUUID,randomInt,createHmac,webcrypto}=require('node:crypto');
const {stripTypeScriptTypes}=require('node:module'),{chromium}=require('playwright');
const root=path.resolve(__dirname,'..'), artifacts=process.env.WORKFLOW_ARTIFACTS;
if(!process.env.PGHOST?.startsWith('/tmp/podbor-pg-sock-'))throw Error('Use an isolated test cluster with a private podbor-pg-sock- directory.');
const actor=randomInt(100000000,900000000),supplier=actor+1,second=actor+2,slug=randomUUID();
function sql(statement,params={},setup=false){
  const args=['-XAtq','-v','ON_ERROR_STOP=1',...Object.entries(params).flatMap(([k,v])=>['-v',k+'='+(typeof v==='object'&&v!==null?JSON.stringify(v):String(v))])];
  return execFileSync('psql',args,{input:(setup?'':'set role service_role;\n')+statement,encoding:'utf8'}).trim();
}
function dbRead(stmt,data){const value=sql(stmt,data);return value?JSON.parse(value):null;}
function rpc(name,data){
  assert.match(name,/^(crm_|workflow_)\w+$/);
  for(const key of Object.keys(data))assert.match(key,/^p(?:_\w+)?$/);
  const args=Object.entries(data).map(([k,v])=>k+' => '+(v==null?'null':" :'"+k+"'"));
  return dbRead('select to_jsonb('+name+'('+args.join(',')+'));',data);
}
const secret='000000:synthetic-test-secret';
const init=new URLSearchParams({auth_date:Math.floor(Date.now()/1000),user:JSON.stringify({id:actor})});
init.set('hash',createHmac('sha256',createHmac('sha256','WebAppData').update(secret).digest()).update([...init].map(([k,v])=>k+'='+v).sort().join('\n')).digest('hex'));
let serve,browser;
const db={
  rpc:async(name,args)=>{try{return {data:rpc(name,args),error:null};}catch(e){return {data:null,error:{message:String(e.stderr||e.message)}};}},
  from(table){
    assert(['app_users','mocks','user_workspaces'].includes(table));
    const filters={},query={select(){return query;},eq(k,v){assert.match(k,/^\w+$/);filters[k]=v;return query;},order(){return query;},
    maybeSingle(){return rows().then(r=>({...r,data:r.data[0]}));},then(resolve,reject){return rows().then(resolve,reject);}};
    async function rows(){const where=Object.keys(filters).map(k=>k+"=:'"+k+"'").join(' and ');return {data:dbRead('select coalesce(jsonb_agg(to_jsonb(t)),\'[]\') from '+table+' t '+(where?'where '+where:'')+';',filters)};}
    return query;
  }
};
const source=fs.readFileSync(path.join(root,'supabase/functions/api/index.ts'),'utf8').replace(/^import .*createClient.*;\n/m,'');
vm.runInNewContext(stripTypeScriptTypes(source),{createClient:()=>db,Deno:{serve:f=>serve=f,env:{get:k=>k==='BOT_TOKEN'?secret:''}},Response,TextEncoder,URLSearchParams,crypto:webcrypto,Date,Number,console:{log(){},error(){}}});
async function pageAt(base){
 const page=await browser.newPage({viewport:{width:1440,height:940}});
 page.setDefaultTimeout(7500);page.on('pageerror',e=>{throw e;});page.on('dialog',d=>d.accept());
 await page.addInitScript(value=>{window.Telegram={WebApp:{initData:value}};},init.toString());
 await page.route('**/*',async route=>{
  const u=new URL(route.request().url());
  if(u.pathname==='/functions/v1/api'){
    const r=await serve(new Request(u,{method:'POST',body:route.request().postData()}));
    const body=await r.text();if(!r.ok)console.error(r.status,JSON.parse(route.request().postData()).action,body);
    return route.fulfill({status:r.status,contentType:'application/json',headers:{'Access-Control-Allow-Origin':'*'},body});
  }
  if(u.hostname!=='podbor.test')return route.abort();
  const file=path.join(base,u.pathname);if(!fs.existsSync(file))return route.fulfill({status:404,body:''});
  return route.fulfill({path:file});
 });
 return page;
}
const shot=(page,file)=>artifacts?page.screenshot({path:path.join(artifacts,file)}):Promise.resolve();
(async()=>{
 sql("insert into app_companies(slug,name) values(:'slug','Учебный автосалон'); insert into app_users(tg_id,name,role,company_id) select x.id,x.n,x.r,c.id from (values (:'actor'::bigint,'Менеджер приёмки','owner'),(:'supplier'::bigint,'Поставщик Япония','supplier'),(:'second'::bigint,'Поставщик склад','supplier')) x(id,n,r),app_companies c where c.slug=:'slug';",{slug,actor,supplier,second},true);
 browser=await chromium.launch();
 const page=await pageAt(root);await page.goto('https://podbor.test/admin.html');
 await page.getByRole('button',{name:'Поставщики',exact:true}).click();
 await page.locator('[data-flow="pick"][data-value="'+supplier+'"]').click();
 await page.locator('[data-wf="brands"]').fill('Toyota');await page.locator('[data-wf="enabled"]').check();
 await page.locator('[data-wf="currency"]').selectOption('JPY');
 await page.locator('[data-wf="logistics"]').fill('50000');await page.locator('[data-wf="duty"]').fill('80000');
 await page.getByRole('button',{name:'Сохранить тариф'}).click();await page.getByText('Тариф сохранён',{exact:true}).waitFor();
 await shot(page,'supplier-tariff.png');
 rpc('crm_workflow',{p_actor:actor,p_action:'terms.save',p:{id:String(second),revision:0,brands:['Toyota'],currency:'CNY',enabled:true,fees:{logistics:100000,duty:0,documents:0,recycling:0,commission:0}}});
 await page.getByRole('button',{name:'Заявки',exact:true}).click();await page.locator('[data-action="newRequest"]').first().click();
 await page.locator('#d-client_name').fill('Клиент проверки');await page.locator('#d-phone').fill('79991234567');await page.locator('#d-model').fill('Toyota Camry');await page.locator('#d-years').fill('2022');await page.locator('#d-color').fill('Белый');await page.locator('#d-budget').fill('3100000');
 await page.locator('#consent').check();await page.locator('#requestForm button[type="submit"]').click();await page.getByRole('button',{name:'Подбор и КП'}).click();
 const rid=dbRead("select to_jsonb(id) from crm_requests where created_by=:'actor';",{actor});
 const tid=dbRead("select to_jsonb(id) from bot_threads where request_id=:'rid' and supplier_id=:'supplier';",{rid,supplier});
 sql("update bot_outbox set state='sent' where thread_id=:'tid' and state='pending';",{tid});
 const first=randomInt(100000000,900000000);
 const jpeg=await page.evaluate(()=>{const canvas=document.createElement('canvas');canvas.width=320;canvas.height=160;const g=canvas.getContext('2d');g.fillStyle='#eee';g.fillRect(0,0,320,160);g.fillStyle='#225';g.font='20px sans-serif';g.fillText('Тестовое фото · Camry',30,86);return canvas.toDataURL('image/jpeg').split(',')[1];});
 sql("insert into bot_jobs(id,actor_id,payload) values(:'first',:'supplier','{}');",{first,supplier});
 rpc('workflow_receive',{p_actor:supplier,p_thread:tid,p_job:first,p_album:'album',p_text:'Toyota Camry 2022, 38 000 км',p_parsed:{model:'Toyota Camry',years:'2022',mileage:38000,purchase:1800000,currency:'JPY',term:'45 дней'},p_jpeg:jpeg});
 await page.getByRole('button',{name:'Обновить ответы'}).click();await page.locator('[data-wf="thread"]').selectOption(tid);
 await page.locator('[data-wf="reply"]').fill('Уточните срок поставки');await page.getByRole('button',{name:'Отправить поставщику'}).click();await page.locator('.wf-log').getByText('Уточните срок поставки',{exact:true}).waitFor();
 await page.getByRole('button',{name:'Проверить и рассчитать'}).click();
 assert.equal(await page.locator('#domain-logistics').inputValue(),'50000');assert.equal(await page.locator('#domain-currency').inputValue(),'JPY');
 await page.getByRole('button',{name:'Показать фото'}).click();await page.getByRole('checkbox',{name:'Включить в КП'}).check();await shot(page,'photo-review.png');
 await page.locator('#domain-base_rate').fill('0.60');await page.locator('#domain-client_price').fill('1600000');await page.locator('#domain-market_median').fill('1600000');
 await page.locator('#domainOptionForm button[type="submit"]').click();
 await page.getByText('Готов к КП',{exact:true}).waitFor();await page.locator('[data-domain-select]').check();await page.locator('[data-domain="offer"]').click();
 await page.locator('[data-domain="download"]').waitFor();const promise=page.waitForEvent('download');await page.locator('[data-domain="download"]').click();const pdf=await promise;
 if(artifacts){await pdf.saveAs(path.join(artifacts,'offer.pdf'));const imgs=execFileSync('pdfimages',['-list',path.join(artifacts,'offer.pdf')],{encoding:'utf8'});assert.match(imgs,/image\s+320\s+160/);}
 await page.locator('[data-domain="sent"]').click();await page.locator('tr[data-action="request"]').first().click();await page.getByRole('button',{name:'Подбор и КП'}).click();
 await page.locator('[data-wf="outcome"]').selectOption('won');await page.locator('[data-wf="note"]').fill('Клиент подтвердил заказ');await page.getByRole('button',{name:'Записать результат'}).click();
 await page.getByText('Результат сохранён в истории клиента').waitFor();
 assert.equal(dbRead("select to_jsonb(status) from crm_requests where id=:'rid';",{rid}),'won');
 await page.locator('[data-wf="thread"]').selectOption(tid);await page.locator('.detail').evaluate(e=>e.scrollTop=0);await shot(page,'request-after.png');
 if(process.env.WORKFLOW_BEFORE){
  const old=await pageAt(process.env.WORKFLOW_BEFORE);await old.goto('https://podbor.test/admin.html');await old.getByRole('button',{name:'Заявки',exact:true}).click();await old.locator('tr[data-action="request"]').first().click();await old.getByRole('button',{name:'Подбор и КП'}).click();await shot(old,'request-before.png');
 }
 console.log('PASS Chromium -> Edge handler -> Postgres: supplier tariff, create and route, partial reply, reviewed photo, price, PDF with JPEG, client outcome.');
})().catch(e=>{console.error(e.stack);process.exitCode=1;}).finally(async()=>{if(browser)await browser.close();});
