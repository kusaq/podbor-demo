const fs=require('fs'),path=require('path'),http=require('http'),os=require('os'),assert=require('assert'),{randomUUID}=require('crypto'),{chromium}=require('playwright');
const root=process.env.PODBOR_SOURCE||path.resolve(__dirname,'..'),output=fs.mkdtempSync(path.join(os.tmpdir(),'podbor-crm-'));
const users=new Map([
 ['100000001',{tg_id:100000001,name:'Администратор',role:'admin',active:true,company_id:'a',created_at:new Date().toISOString()}],
 ['100000002',{tg_id:100000002,name:'Первый менеджер',role:'manager',active:true,company_id:'a'}],
 ['100000003',{tg_id:100000003,name:'Второй менеджер',role:'manager',active:true,company_id:'a'}]
]);const sessions=new Map([['a'.repeat(64),'100000001'],['b'.repeat(64),'100000002'],['c'.repeat(64),'100000003']]);
const options=new Map(),offers=new Map();let settings={revision:1,dealer:{name:'',inn:'',phone:'',address:''},pricing:{median_enabled:true,median_pct:5,margin_enabled:true,margin_pct:3},exchange:{mode:'percent',percent:2,add:0,fixed:1},valid_days:7,letterhead_id:null};
const rows=new Map(),activity=new Map(),errors=[];let server,browser;
const me=id=>users.get(String(id));
async function setup(page,mode){
 page.on('pageerror',e=>errors.push(e.message));page.on('dialog',d=>d.accept());
 if(mode==='mobile')await page.addInitScript(()=>{window.Telegram={WebApp:{initData:'fake:100000001',initDataUnsafe:{user:{id:100000001}},ready(){},expand(){}}}});
 if(mode==='manager')await page.addInitScript(()=>sessionStorage.setItem('podbor-desktop-session',JSON.stringify({token:'b'.repeat(64)})));
 await page.route('https://telegram.org/**',r=>r.fulfill({status:200,body:''}));await page.route('https://fonts.googleapis.com/**',r=>r.abort());
 await page.route('**/functions/v1/api',async route=>{const b=route.request().postDataJSON();const p=b.payload||{};let id=sessions.get(b.desktopSession)||String(b.initData||'').split(':')[1],u=me(id),out={},status=200;
 if(b.action==='desktop.exchange'){if(p.code==='2345-6789-ABCD')out={sessionToken:'a'.repeat(64),expiresAt:new Date(Date.now()+3600000).toISOString()};else{status=401;out={error:'desktop_bad_code'}}}
 else if(!u||!u.active){status=403;out={error:'no_access'}}
 else if(b.action==='me')out={me:u,mocks:[]};
 else if(b.action==='desktop.logout'){sessions.delete(b.desktopSession);out={ok:true}}
 else if(b.action==='desktop.code')out={code:'2345-6789-ABCD',expiresAt:new Date(Date.now()+300000).toISOString()};
 else if(b.action==='users.list')out={users:[...users.values()].filter(x=>x.company_id===u.company_id)};
 else if(b.action==='users.save'){const value={...me(p.orig),tg_id:Number(p.tg_id),name:p.name,role:p.role,active:p.active,company_id:u.company_id,created_at:new Date().toISOString()};users.set(String(value.tg_id),value);out={user:value}}
 else if(b.action==='users.delete'){users.delete(String(p.tg_id));rows.forEach(r=>{if(String(r.assigned_to)===String(p.tg_id))r.assigned_to=null});out={ok:true}}
 else if(b.action.startsWith('backend.')){
  const action=b.action.slice(8),record=rows.get(p.request_id);
  const evalOption=o=>{const margin=(o.client_price-o.total_cost)/o.purchase_rub*100;const need=settings.pricing.median_enabled&&(!o.market_median||o.client_price<o.market_median*(1-settings.pricing.median_pct/100))||settings.pricing.margin_enabled&&margin<settings.pricing.margin_pct;return {margin_pct:margin,reasons:need?['Требуется проверка цены']:[],needs_approval:need,can_send:!o.archived&&(!need||o.approval==='approved')}};
  if(action==='settings.get')out={settings};
  else if(action==='settings.save'){settings={...p,revision:settings.revision+1};out={settings};}
  else if(action==='request.get')out={options:[...options.values()].filter(o=>o.request_id===p.request_id).map(o=>({...o,evaluation:evalOption(o)})),offers:[...offers.values()].filter(o=>o.request_id===p.request_id),offer_count:offers.size,settings};
  else if(action==='option.save'){const cost=Number(p.input.purchase)+Number(p.input.logistics)+Number(p.input.commission);if(p.client_price<cost){status=400;out={error:'backend_price_below_cost'}}else{const old=options.get(p.id),o={...p,id:p.id||randomUUID(),version:(old?.version||0)+1,approval:'none',archived:false,total_cost:cost,purchase_rub:p.input.purchase,calculation:{effective_rate:1},evaluation:{}};options.set(o.id,o);out={option:o,evaluation:evalOption(o)}}}
  else if(action==='option.review'){const o=options.get(p.id);o.approval=p.decision==='requested'?'pending':p.decision;o.version++;out={option:o,evaluation:evalOption(o)}}
  else if(action==='option.archive'){const o=options.get(p.id);o.archived=p.archived;o.version++;out={option:o};}
  else if(action==='offer.create'){const selected=p.option_ids.map(id=>options.get(id));if(selected.some(o=>!evalOption(o).can_send)){status=400;out={error:'backend_approval_required'}}else{const o={id:randomUUID(),request_id:p.request_id,number:offers.size+1,created_at:new Date().toISOString(),model:{createdAt:new Date().toISOString(),validUntil:new Date(Date.now()+604800000).toISOString(),client:record.client_name,manager:u.name,dealer:settings.dealer,cars:selected.map(o=>({title:o.title,description:o.description,price:o.client_price,term:o.term}))},letterhead_id:null};offers.set(o.id,o);out={offer:o}}}
  else if(action==='offer.get')out={offer:offers.get(p.id)};
  else if(action==='offer.sent'){const f=offers.get(p.id);f.sent_at=new Date().toISOString();const r=rows.get(f.request_id);r.status='think';r.version++;out={offer:f};}
 }
 else if(b.action==='workspace.get')out={state:null,revision:0};
 else if(b.action==='workspace.save')out={revision:Number(p.revision)+1};
 else if(b.action==='crm.import')out={imported:0};
 else if(b.action==='crm.list'){
  let base=[...rows.values()].filter(r=>r.company_id===u.company_id&&(u.role!=='manager'||String(r.assigned_to)===String(u.tg_id))&&(p.archived?!!r.archived_at:!r.archived_at));const summary={total:base.length,search:base.filter(r=>r.status==='search').length,think:base.filter(r=>r.status==='think').length,lost:base.filter(r=>r.status==='lost').length,won:base.filter(r=>r.status==='won').length,unassigned:base.filter(r=>!r.assigned_to).length,overdue:base.filter(r=>r.next_contact_at&&new Date(r.next_contact_at)<new Date()&&['search','think'].includes(r.status)).length};
  const workload=[...new Set(base.map(r=>String(r.assigned_to)))].map(k=>({assigned_to:k==='null'?null:Number(k),assigned_name:me(k)?.name,assigned_active:me(k)?.active,total:base.filter(r=>String(r.assigned_to)===k).length,active_count:base.filter(r=>String(r.assigned_to)===k&&['search','think'].includes(r.status)).length}));
  let result=base.filter(r=>(!p.query||(r.client_name+' '+r.phone+' '+r.model).toLowerCase().includes(p.query.toLowerCase()))&&(!p.status||r.status===p.status||p.status==='overdue'&&r.next_contact_at&&new Date(r.next_contact_at)<new Date()&&['search','think'].includes(r.status))&&(!p.assignee||String(r.assigned_to)===String(p.assignee)||p.assignee==='unassigned'&&!r.assigned_to));
  out={requests:result.slice((p.page||0)*100,(p.page||0)*100+100).map(r=>({...r,assigned_name:me(r.assigned_to)?.name,assigned_active:me(r.assigned_to)?.active})),total:result.length,summary,workload};
 }
 else if(b.action==='crm.save'){
  const old=p.id?rows.get(p.id):null,d=p.data;
  if(old&&Number(p.version)!==old.version){status=409;out={error:'crm_conflict'}}
  else if(!old&&[...rows.values()].some(r=>r.phone===d.phone&&['search','think'].includes(r.status)&&!r.archived_at)){status=409;out={error:'crm_duplicate'}}
  else{const record={id:p.id||randomUUID(),version:(old?.version||0)+1,company_id:u.company_id,status:'search',reasons:[],note:'',main_reason:'',...old,...d,phone:String(d.phone||old?.phone).replace(/\D/g,''),created_at:old?.created_at||new Date().toISOString(),updated_at:new Date().toISOString()};if(!('assigned_to' in d)&&!old)record.assigned_to=u.tg_id;if('archived'in d)record.archived_at=d.archived?new Date().toISOString():null;rows.set(record.id,record);out={request:record};const list=activity.get(record.id)||[];list.unshift({kind:old?'updated':'created',actor_name:u.name,created_at:new Date().toISOString(),data:{status:record.status,from_status:old?.status,assigned_to:record.assigned_to,from_assigned_to:old?.assigned_to}});activity.set(record.id,list)}
 }
 else if(b.action==='crm.client'){const list=activity.get(p.id)||[];const last=list.find(a=>a.kind==='contact'&&a.data.result==='connected');out={request:rows.get(p.id),activity:list,last_contact:last?{at:last.created_at,note:last.data.note}:null};}
 else if(b.action==='crm.contact.save'){const r=rows.get(p.id);if(page.failContact){page.failContact=false;status=500;out={error:'crm_db'}}else if(r.version!==p.version){status=409;out={error:'crm_conflict'}}else{r.version++;Object.assign(r,p.data);const event={kind:'contact',actor_name:u.name,created_at:new Date().toISOString(),data:{result:p.result,note:p.note,status:r.status,token:p.token}};activity.get(r.id).unshift(event);out={request:r,contact:event}}}
 else if(b.action==='crm.detail')out={request:rows.get(p.id),activity:activity.get(p.id)||[]};
 else if(b.action==='crm.comment'){const item={kind:'comment',data:{text:p.text},actor_name:u.name,created_at:new Date().toISOString()};activity.get(p.id).unshift(item);out={activity:item}}
 return route.fulfill({status,contentType:'application/json',headers:{'access-control-allow-origin':'*'},body:JSON.stringify(out)});
 });
}
(async()=>{
 server=http.createServer((req,res)=>{let file=path.join(root,decodeURIComponent(req.url.split('?')[0]));if(req.url.split('?')[0]==='/')file=path.join(root,'index.html');if(!file.startsWith(root+'/')){res.writeHead(403).end();return}try{const bytes=fs.readFileSync(file);res.setHeader('Content-Type',({'.html':'text/html','.js':'application/javascript','.css':'text/css'})[path.extname(file)]||'application/octet-stream');res.end(bytes)}catch{res.writeHead(404).end()}});await new Promise(r=>server.listen(0,'127.0.0.1',r));const url='http://127.0.0.1:'+server.address().port;

 browser=await chromium.launch({headless:true,executablePath:process.env.PODBOR_CHROMIUM});const page=await browser.newPage({viewport:{width:390,height:844}});await setup(page,'mobile');await page.addInitScript(()=>document.addEventListener('click',e=>{if(e.target.closest('a[href^="tel:"]'))e.preventDefault()},true));
 const id=randomUUID();rows.set(id,{id,company_id:'a',client_name:'Клиент проверки',phone:'79991234567',model:'Toyota проверка',spec:'Белый, до 60000 км',budget:3500000,purchase_time:'В течение месяца',status:'search',reasons:[],version:1,assigned_to:'100000002',updated_at:new Date().toISOString()});activity.set(id,[{kind:'created',created_at:new Date().toISOString(),actor_name:'Менеджер',data:{status:'search'}}]);
 await page.goto(url+'/');await page.locator('[data-a="viewCabinet"][data-v="manager"]').click();await page.locator('[data-a="tab"][data-v="feedback"]').click();await page.locator('[data-a="'+(process.env.BASELINE?'openStatus':'openClient')+'"]').first().click();
 if(process.env.BASELINE){await page.screenshot({path:path.join(output,'before-client.png'),fullPage:true});console.log('BEFORE',output);return}
 await page.getByText('История клиента',{exact:true}).waitFor();await page.getByText('Создана заявка',{exact:true}).waitFor();await page.getByText('Белый, до 60000 км',{exact:true}).waitFor();await page.screenshot({path:path.join(output,'after-client.png'),fullPage:true});assert.equal(await page.locator('a[data-customer-call]').getAttribute('href'),'tel:+79991234567');
 await page.locator('a[data-customer-call]').click();await page.getByText('Как прошёл звонок?',{exact:true}).waitFor();await page.locator('[data-a="stSave"]').click();await page.getByRole('alert').getByText('Выберите результат звонка',{exact:true}).waitFor();assert.equal(activity.get(id).filter(a=>a.kind==='contact').length,0);
 await page.locator('[data-a="contactResult"][data-v="no_answer"]').click();await page.locator('#contactNote').fill('Перезвонить вечером');await page.locator('[data-a="stSave"]').click();await page.getByText('История клиента',{exact:true}).waitFor();await page.getByText('Разговоров пока не зафиксировано',{exact:true}).waitFor();assert.equal(activity.get(id).filter(a=>a.kind==='contact').length,1);
 await page.locator('a[data-customer-call]').click();await page.locator('[data-a="contactResult"][data-v="connected"]').click();await page.locator('#contactNote').fill('Согласовали комплектацию');await page.locator('#contactNext').fill('2026-12-01T10:30');await page.locator('[data-a="stPick"][data-v="won"]').click();page.failContact=true;await page.locator('[data-a="stSave"]').click();await page.getByRole('alert').waitFor();assert.equal(await page.locator('#contactNote').inputValue(),'Согласовали комплектацию');assert.equal(rows.get(id).status,'search');await page.screenshot({path:path.join(output,'after-result.png'),fullPage:true});await page.locator('[data-a="stSave"]').click();await page.getByText('История клиента',{exact:true}).waitFor();await page.getByText('В заявке отмечен статус «Заказ»',{exact:true}).waitFor();assert.equal(activity.get(id).filter(a=>a.kind==='contact').length,2);assert.equal(rows.get(id).next_contact_at,new Date('2026-12-01T10:30').toISOString());await page.screenshot({path:path.join(output,'after-summary.png'),fullPage:true});
 await page.getByText('История клиента',{exact:true}).scrollIntoViewIfNeeded();await page.screenshot({path:path.join(output,'after-history.png'),fullPage:true});await page.locator('[data-a="back"]').click();await page.locator('[data-a="openClient"]').first().click();await page.getByText('Разговор состоялся',{exact:true}).waitFor();await page.locator('a[data-customer-call]').click();await page.getByText('Как прошёл звонок?',{exact:true}).waitFor();await page.locator('[data-a="back"]').click();await page.getByText('История клиента',{exact:true}).waitFor();assert.equal(activity.get(id).filter(a=>a.kind==='contact').length,2);assert.deepEqual(errors,[]);console.log('PASS client history, request info, dial prompt, explicit result, no-answer semantics, failed save recovery and reload');console.log('AFTER',output);
})().catch(e=>{console.error(e.stack);process.exitCode=1}).finally(async()=>{if(browser)await browser.close();if(server)server.close()});
