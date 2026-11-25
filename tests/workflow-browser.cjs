// Run on a disposable local Postgres database with the project schemas installed.
const assert=require('node:assert/strict'), fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const {execFileSync}=require('node:child_process'),{randomUUID,randomInt,createHmac,webcrypto}=require('node:crypto');
const {stripTypeScriptTypes}=require('node:module'),{chromium}=require('playwright');
const root=path.resolve(__dirname,'..'), artifacts=process.env.WORKFLOW_ARTIFACTS;
if(!process.env.PGHOST?.startsWith('/tmp/podbor-pg-sock-'))throw Error('Use an isolated test cluster with a private podbor-pg-sock- directory.');
const actor=randomInt(100000000,900000000),supplier=actor+1,second=actor+2,slug=randomUUID();
const admin=actor+3,manager=actor+4;
const {sql,dbRead,rpc,db}=require('./local-workflow-db.cjs');
const secret='000000:synthetic-test-secret';
function localInit(id){
 const init=new URLSearchParams({auth_date:Math.floor(Date.now()/1000),user:JSON.stringify({id})});
 init.set('hash',createHmac('sha256',createHmac('sha256','WebAppData').update(secret).digest()).update([...init].map(([k,v])=>k+'='+v).sort().join('\n')).digest('hex'));
 return init.toString();
}
let serve,browser;
const source=fs.readFileSync(path.join(root,'supabase/functions/api/index.ts'),'utf8').replace(/^import .*createClient.*;\n/m,'');
vm.runInNewContext(stripTypeScriptTypes(source),{createClient:()=>db,Deno:{serve:f=>serve=f,env:{get:k=>k==='BOT_TOKEN'?secret:''}},Response,TextEncoder,URLSearchParams,crypto:webcrypto,Date,Number,console:{log(){},error(){}}});
async function pageAt(base,id=actor,viewport={width:1440,height:940}){
 const page=await browser.newPage({viewport});
 page.setDefaultTimeout(12000);page.on('pageerror',e=>{throw e;});page.on('dialog',d=>d.accept());
 if(id)await page.addInitScript(value=>{window.Telegram={WebApp:{initData:value,initDataUnsafe:{user:JSON.parse(new URLSearchParams(value).get('user'))},ready(){},expand(){},close(){window.testChatReturned=true;}}};},localInit(id));
 await page.route('**/*',async route=>{
  const u=new URL(route.request().url());
  if(u.pathname==='/functions/v1/api'){
    const r=await serve(new Request(u,{method:'POST',body:route.request().postData()}));
    const body=await r.text();if(!r.ok && r.status!==403)console.error(r.status,JSON.parse(route.request().postData()).action,body);
    return route.fulfill({status:r.status,contentType:'application/json',headers:{'Access-Control-Allow-Origin':'*'},body});
  }
  if(u.hostname!=='podbor.test')return route.abort();
  const file=path.join(base,u.pathname==='/'?'index.html':u.pathname);if(!fs.existsSync(file))return route.fulfill({status:404,body:''});
  return route.fulfill({path:file});
 });
 return page;
}
const shot=(page,file)=>artifacts?page.screenshot({path:path.join(artifacts,file)}):Promise.resolve();
(async()=>{
 sql("insert into app_companies(slug,name) values(:'slug','Учебный автосалон'); insert into app_users(tg_id,name,role,company_id) select x.id,x.n,x.r,c.id from (values (:'actor'::bigint,'Владелец салона','owner'),(:'admin'::bigint,'Администратор салона','admin'),(:'second'::bigint,'Поставщик склад','supplier')) x(id,n,r),app_companies c where c.slug=:'slug';",{slug,actor,admin,second},true);
 browser=await chromium.launch();
 const phone={width:390,height:844},home='https://podbor.test/';
 const bot=await require('./local-workflow-bot.cjs')(db);
 const mobileAdmin=await pageAt(root,admin,phone);await mobileAdmin.goto(home);
 await mobileAdmin.getByRole('button',{name:'CRM и админка на компьютере'}).click();await mobileAdmin.locator('[data-a="desktopCode"]').click();
 const code=await mobileAdmin.getByText(/^[A-Z2-9]{4}-[A-Z2-9]{4}-[A-Z2-9]{4}$/).innerText();
 const desk=await pageAt(root,null);await desk.goto(home+'admin.html');await desk.locator('#loginCode').fill(code);await desk.locator('#loginForm button').click();
 await desk.getByRole('heading',{name:'Обзор',exact:true}).waitFor();await shot(desk,'admin-overview.png');
 for(const [id,name,role] of [[manager,'Анна Сергеева','manager'],[supplier,'Поставщик Япония','supplier']]){
  await desk.locator('[data-action="newUser"]').click();await desk.locator('#d-tg_id').fill(String(id));await desk.locator('#d-name').fill(name);await desk.locator('#d-role').selectOption(role);
  await desk.locator('#userForm button[type=submit]').click();await desk.locator('.data-table').getByText(name,{exact:true}).waitFor();
 }
 await shot(desk,'admin-team.png');
 const supplierMini=await pageAt(root,supplier,phone);await supplierMini.goto(home);await supplierMini.getByRole('heading',{name:'Кабинет поставщика'}).waitFor();
 await shot(supplierMini,'supplier-mobile.png');await supplierMini.getByRole('button',{name:'Вернуться в чат с ботом'}).click();assert(await supplierMini.evaluate(()=>window.testChatReturned));
 const page=await pageAt(root,actor);await page.goto(home+'admin.html');
 await page.getByRole('button',{name:'Поставщики',exact:true}).click();
 await page.locator('[data-flow="pick"][data-value="'+supplier+'"]').click();
 await page.locator('[data-wf="brands"]').fill('Toyota');await page.locator('[data-wf="enabled"]').check();
 await page.locator('[data-wf="currency"]').selectOption('JPY');
 await page.locator('[data-wf="logistics"]').fill('50000');await page.locator('[data-wf="duty"]').fill('80000');
 await page.getByRole('button',{name:'Сохранить тариф'}).click();await page.getByText('Тариф сохранён',{exact:true}).waitFor();
 await shot(page,'supplier-tariff.png');
 rpc('crm_workflow',{p_actor:actor,p_action:'terms.save',p:{id:String(second),revision:0,brands:['Toyota'],currency:'CNY',enabled:true,fees:{logistics:100000,duty:0,documents:0,recycling:0,commission:0}}});
 const managerPhone=await pageAt(root,manager,phone);await managerPhone.goto(home);
 await managerPhone.locator('[data-a="goLead"]').click();await managerPhone.locator('[data-a="leadMode"][data-v="quick"]').click();
 const clientText='Подберите белую Toyota Camry 2022 года до 3 100 000 рублей с доставкой в Казань.';
 await managerPhone.locator('#lt').fill(clientText);await managerPhone.locator('#fn').fill('Клиент проверки');await managerPhone.locator('#fp').fill('79991234567');await managerPhone.locator('#fm').fill('Toyota Camry');await managerPhone.locator('#fy').fill('2022');await managerPhone.locator('#fc').fill('Белый');await managerPhone.locator('#fb').fill('3100000');
 await managerPhone.locator('[data-a="leadConsent"]').click();await managerPhone.locator('[data-a="leadCreate"]').click();await managerPhone.locator('[data-a="openWorkCrm"]').waitFor();await shot(managerPhone,'manager-request-mobile.png');
 const rid=dbRead("select to_jsonb(id) from crm_requests where created_by=:'manager' and assigned_to=:'manager' and source_text=:'clientText';",{manager,clientText});assert(rid);
 const tid=dbRead("select to_jsonb(id) from bot_threads where request_id=:'rid' and supplier_id=:'supplier';",{rid,supplier});assert(tid);
 await managerPhone.locator('[data-a="openWorkCrm"]').click();await managerPhone.getByRole('button',{name:'Подбор и КП'}).waitFor();
 await managerPhone.getByRole('button',{name:'Обновить ответы'}).waitFor();await shot(managerPhone,'manager-sourcing-mobile.png');
 const managerDesk=await pageAt(root,manager);await managerDesk.goto(home+'admin.html?request='+rid);await managerDesk.getByRole('button',{name:'Обновить ответы'}).waitFor();
 assert.equal(await managerDesk.locator('[data-action="newUser"]').count(),0);
 await bot.drain();const original=bot.messages.find(m=>String(m.chat_id)===String(supplier)&&/Camry/i.test(m.text));assert(original);
 assert(!original.text.includes('Клиент проверки')&&!original.text.includes('9991234567')&&!original.text.includes('3 100 000'));
 sql("update bot_outbox set delivered_at=now()-interval '7 hours' where thread_id=:'tid' and state='sent';",{tid});
 await bot.drain();await bot.drain();
 assert.equal(bot.messages.filter(m=>String(m.chat_id)===String(supplier)&&/Есть ли подходящая машина/.test(m.text)).length,1);
 assert(bot.messages.some(m=>String(m.chat_id)===String(manager)&&/ещё не ответил/.test(m.text)));

 const jpeg=await page.evaluate(()=>{const canvas=document.createElement('canvas');canvas.width=320;canvas.height=160;const g=canvas.getContext('2d');g.fillStyle='#eee';g.fillRect(0,0,320,160);g.fillStyle='#225';g.font='20px sans-serif';g.fillText('Тестовое фото · Camry',30,86);return canvas.toDataURL('image/jpeg').split(',')[1];});
 bot.photo(Buffer.from(jpeg,'base64'));
 await bot.send(supplier,{reply_to_message:{message_id:original.message_id},caption:'Год: 2022\nПробег: 38000 км\nЦена: 1800000 JPY\nСрок: 45 дней',photo:[{width:320,height:160,file_size:Buffer.from(jpeg,'base64').length,file_id:'car'}]});
 assert(bot.messages.some(m=>String(m.chat_id)===String(supplier)&&m.text.includes('Ответ сохранён')));
 await managerDesk.getByRole('button',{name:'Обновить ответы'}).click();await managerDesk.locator('[data-wf="thread"]').selectOption(tid);
 await managerDesk.locator('[data-wf="reply"]').fill('Уточните срок поставки');await managerDesk.getByRole('button',{name:'Отправить поставщику'}).click();await managerDesk.locator('.wf-log').getByText('Уточните срок поставки',{exact:true}).waitFor();
 await managerDesk.getByRole('button',{name:'Проверить и рассчитать'}).click();
 assert.equal(await managerDesk.locator('#domain-logistics').inputValue(),'50000');assert.equal(await managerDesk.locator('#domain-currency').inputValue(),'JPY');
 await managerDesk.getByRole('button',{name:'Показать фото'}).click();await managerDesk.getByRole('checkbox',{name:'Включить в КП'}).check();await shot(managerDesk,'photo-review.png');
 await managerDesk.locator('#domain-base_rate').fill('0.60');await managerDesk.locator('#domain-client_price').fill('1600000');await managerDesk.locator('#domain-market_median').fill('2300000');await managerDesk.locator('#costEstimate').scrollIntoViewIfNeeded();assert.equal((await managerDesk.locator('#domainEstimate').innerText()).replace(/[^0-9]/g,''),'1231600');await shot(managerDesk,'manager-delivery.png');
 await managerDesk.locator('#domainOptionForm button[type="submit"]').click();
 assert.equal(dbRead("select to_jsonb(total_cost) from request_options where request_id=:'rid';",{rid}),1231600);
 await managerDesk.locator('[data-domain="review"][data-decision="requested"]').click();
 await page.goto(home+'admin.html?request='+rid);await page.locator('[data-domain="review"][data-decision="approved"]').click();await page.getByText('Готов к КП',{exact:true}).waitFor();await shot(page,'owner-approval.png');
 await managerDesk.locator('[data-domain="reload"]').click();
 await managerDesk.getByText('Готов к КП',{exact:true}).waitFor();const supplierOption=await managerDesk.locator('[data-domain-select]').getAttribute('data-domain-select');
 const sourcePanel=managerDesk.locator('details').filter({has:managerDesk.locator('#wf-listing')});
 async function openSources(){if(!await sourcePanel.evaluate(e=>e.open))await sourcePanel.locator('summary').click();}
 await openSources();assert.equal(await sourcePanel.getByText('Источник не подключён',{exact:true}).count(),2);
 const listing='https://auto.ru/cars/used/sale/toyota/camry/1132958207-3e2ca6e3/';
 await sourcePanel.locator('[data-wf="listingUrl"]').fill(listing);await sourcePanel.locator('[data-wf="listingTitle"]').fill('Camry в Москве');await sourcePanel.locator('[data-wf="listingPrice"]').fill('2450000');await sourcePanel.getByRole('button',{name:'Сохранить объявление'}).click();
 await managerDesk.locator('[data-flow="source"][data-value="manual:0"]').waitFor({state:'attached'});await openSources();await shot(managerDesk,'manager-sources.png');
 await sourcePanel.getByRole('button',{name:'В расчёт'}).click();assert.equal(await managerDesk.locator('#domain-purchase').inputValue(),'2450000');await managerDesk.locator('#domain-client_price').fill('2900000');await managerDesk.locator('#domain-market_median').fill('2900000');await managerDesk.locator('#domainOptionForm button[type=submit]').click();
 await managerDesk.waitForFunction(()=>document.querySelectorAll('[data-domain-select]').length===2);
 for(const box of await managerDesk.locator('[data-domain-select]').all())await box.check();
 await managerDesk.locator('[data-domain="offer"]').click();
 await managerDesk.locator('[data-domain="download"]').waitFor();const promise=managerDesk.waitForEvent('download');await managerDesk.locator('[data-domain="download"]').click();const pdf=await promise;
 if(artifacts){await pdf.saveAs(path.join(artifacts,'offer.pdf'));const imgs=execFileSync('pdfimages',['-list',path.join(artifacts,'offer.pdf')],{encoding:'utf8'});assert.match(imgs,/image\s+320\s+160/);}
 await managerDesk.locator('[data-domain="sent"]').click();await managerDesk.locator('tr[data-action="request"]').first().click();await managerDesk.getByRole('button',{name:'Подбор и КП'}).click();
 await managerDesk.locator('[data-wf="outcome"]').selectOption('won');await managerDesk.locator('[data-wf="car"]').selectOption({value:await managerDesk.locator('[data-wf="car"] option').evaluateAll((opts,id)=>opts.find(o=>o.value.endsWith('/'+id)).value,supplierOption)});await managerDesk.locator('[data-wf="note"]').fill('Клиент подтвердил заказ');await managerDesk.getByRole('button',{name:'Записать результат'}).click();
 await managerDesk.getByText('Результат сохранён в истории клиента').waitFor();
 await managerDesk.getByRole('heading',{name:'Выбор клиента'}).waitFor();
 const choice=dbRead("select data->'choice' from crm_activity where request_id=:'rid' and kind='car.chosen';",{rid});
 assert.equal(choice.option,supplierOption);assert.equal(choice.price,1600000);
 const submitted=dbRead("select data from crm_activity where request_id=:'rid' and kind='contact' order by id desc limit 1;",{rid});
 const same={request_id:rid,offer:choice.offer,option:choice.option,token:submitted.token,version:1,note:submitted.note};
 assert.deepEqual(rpc('crm_workflow',{p_actor:manager,p_action:'choose_car',p:same}).choice,choice);
 assert.equal(dbRead("select to_jsonb(count(*)) from crm_activity where request_id=:'rid' and kind='car.chosen';",{rid}),1);
 assert.equal(dbRead("select to_jsonb(status) from crm_requests where id=:'rid';",{rid}),'won');
 await managerDesk.locator('[data-wf="thread"]').selectOption(tid);await managerDesk.locator('.detail').evaluate(e=>e.scrollTop=0);await shot(managerDesk,'request-after.png');
 if(process.env.WORKFLOW_BEFORE){
  const old=await pageAt(process.env.WORKFLOW_BEFORE,supplier,phone);await old.goto(home);await old.getByText('Демосценарий поставщика',{exact:true}).waitFor();await shot(old,'supplier-before.png');
 }
 await desk.locator('tr[data-action="user"][data-id="'+manager+'"]').click();await desk.locator('#userActive').uncheck();await desk.locator('#userForm button[type=submit]').click();
 await desk.getByRole('table').getByText('Выключен',{exact:true}).waitFor();await managerDesk.reload();await managerDesk.locator('#loginCode').waitFor();
 for(const p of [desk,page,managerPhone,supplierMini])assert(await p.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),'Horizontal overflow '+p.url());
 console.log('PASS administrator access, owner approval, manager intake, supplier reply, reminders, delivery calculation, two cars in a PDF, client choice and disabled login');
})().catch(e=>{console.error(e.stack);process.exitCode=1;}).finally(async()=>{if(browser)await browser.close();});
