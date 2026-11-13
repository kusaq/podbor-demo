const fs=require('fs'),path=require('path'),http=require('http'),assert=require('assert');
const {chromium}=require('playwright');
const output=fs.mkdtempSync(path.join(require('os').tmpdir(),'podbor-test-'));
const root=path.resolve(__dirname,'..'), state=new Map(),crm=new Map();let conflicts=0;let browser,server;const errors=[];
const user={tg_id:123456789,name:'Проверка',role:'admin',active:true};
async function setup(page,id=123456789){
 page.on('pageerror',e=>errors.push(e.message));
 await page.addInitScript(({id})=>{window.Telegram={WebApp:{initData:'synthetic-test-'+id,initDataUnsafe:{user:{id,first_name:'Проверка'}},ready(){},expand(){}}}},{id});
 await page.route('https://telegram.org/**',r=>r.fulfill({status:200,body:''}));
 await page.route('https://fonts.googleapis.com/**',r=>r.abort());
 await page.route('**/functions/v1/api',async route=>{const req=route.request();if(req.method()==='OPTIONS')return route.fulfill({status:200,headers:{'access-control-allow-origin':'*','access-control-allow-headers':'*'}});const b=req.postDataJSON(),p=b.payload||{},key=b.initData;let result={},status=200;
 if(b.action==='me')result={me:{...user,tg_id:id},mocks:[]};
 else if(b.action==='users.list')result={users:[user]};
 else if(b.action==='crm.import')result={imported:0};
 else if(b.action==='crm.list') {const rows=[...crm.values()].filter(x=>x.company_id===(id===123456789?'a':'b'));result={requests:rows,total:rows.length};}
 else if(b.action==='crm.save'){const old=p.id?crm.get(p.id):null;const row={...(old||{}),...p.data,id:p.id||require('crypto').randomUUID(),version:(old?.version||0)+1,company_id:id===123456789?'a':'b',assigned_to:old?.assigned_to||id,assigned_name:'Проверка',status:p.data.status||old?.status||'search',reasons:p.data.reasons||[],main_reason:p.data.main_reason||'',note:p.data.note||'',updated_at:new Date().toISOString()};crm.set(row.id,row);result={request:row};}

 else if(b.action==='workspace.get')result=state.get(key)||{revision:0,state:null};
 else if(b.action==='workspace.save'){let old=state.get(key);if((old?.revision||0)!==p.revision){status=409;conflicts++;result={error:'workspace_conflict'}}else{result={revision:p.revision+1};state.set(key,{revision:p.revision+1,state:p.state})}}
 return route.fulfill({status,contentType:'application/json',headers:{'access-control-allow-origin':'*'},body:JSON.stringify(result)});
 });
}
(async()=>{
 server=http.createServer((req,res)=>{const file=path.join(root,decodeURIComponent(req.url.split('?')[0]==='/'?'index.html':req.url.split('?')[0]));if(!file.startsWith(root+'/')){res.writeHead(403).end();return;}try{const b=fs.readFileSync(file);const ext=path.extname(file);res.setHeader('Content-Type',({'.html':'text/html','.js':'application/javascript','.ttf':'font/ttf'})[ext]||'application/octet-stream');res.end(b)}catch{res.writeHead(404).end()}});await new Promise(r=>server.listen(0,'127.0.0.1',r));const url='http://127.0.0.1:'+server.address().port;
 browser=await chromium.launch({headless:true});const c1=await browser.newContext({viewport:{width:390,height:844},acceptDownloads:true});const p1=await c1.newPage();await setup(p1);await p1.goto(url);await p1.getByText('Рабочие кабинеты',{exact:true}).waitFor();await p1.locator('[data-a="viewCabinet"][data-v="manager"]').click();
 await p1.locator('[data-a="goLead"]').click();await p1.locator('#fn').fill('Тестовый клиент');await p1.locator('#fp').fill('89991234567');await p1.locator('#fm').fill('Kia Test');await p1.locator('#fb').fill('4000000');await p1.locator('[data-a="leadConsent"]').click();await p1.locator('[data-a="leadCreate"]').click();await p1.getByRole('heading',{name:'Kia Test',exact:true}).waitFor();await p1.waitForFunction(()=>document.querySelector('#syncState')?.textContent.includes('Сохранено в Supabase'));
 assert.equal([...crm.values()][0].model,'Kia Test');
 const c2=await browser.newContext({viewport:{width:390,height:844}}),p2=await c2.newPage();await setup(p2);await p2.goto(url);await p2.locator('[data-a="viewCabinet"][data-v="owner"]').click();await p2.getByText('Kia Test',{exact:true}).waitFor();
 await p2.locator('#requestSearch').fill('невстречается');assert.equal(await p2.locator('[data-a="openRequest"]').count(),0);await p2.locator('#requestSearch').fill('Kia Test');assert.equal(await p2.locator('[data-a="openRequest"]').count(),1);
 await p2.locator('[data-a="tab"][data-v="settings"]').click();await p2.locator('[data-a="stab"][data-v="kp"]').click();await p2.locator('#dealer-name').fill('Проверочный дилер');const {PDFDocument}=require('../assets/pdf-lib.min.js');const sample=await PDFDocument.create();sample.addPage([595,842]);const samplePath=path.join(output,'letterhead-test.pdf');fs.writeFileSync(samplePath,await sample.save());await p2.locator('#letterhead').setInputFiles(samplePath);await p2.getByText('letterhead-test.pdf',{exact:true}).waitFor();await p2.waitForFunction(()=>document.querySelector('#syncState')?.textContent.includes('Сохранено в Supabase'));
 // First device tries to save an old revision and must not overwrite the second device.
 await p1.locator('[data-a="back"]').click();await p1.locator('[data-a="back"]').click();await p1.locator('[data-a="cabinets"]').first().click();await p1.locator('[data-a="viewCabinet"][data-v="owner"]').click();await p1.locator('[data-a="tab"][data-v="settings"]').click();await p1.locator('[data-a="stab"][data-v="price"]').click();await p1.locator('[data-a="togglePriceRule"]').first().click();await p1.locator('[data-a="loadServerState"]').waitFor();assert(conflicts>0);
 // Restore server copy explicitly, preserving a local backup.
 p1.once('dialog',d=>d.accept());await p1.locator('[data-a="loadServerState"]').click();await p1.waitForFunction(()=>document.querySelector('#syncState')?.textContent.includes('Сохранено в Supabase'));
 await p1.locator('[data-a="tab"][data-v="cabinets"]').count().then(async n=>{if(n)await p1.locator('[data-a="tab"][data-v="cabinets"]').click();else await p1.locator('[data-a="cabinets"]').first().click()});
 await p1.locator('[data-a="viewCabinet"][data-v="manager"]').click();await p1.locator('[data-a="openCard"]').click();await p1.locator('[data-a="pick"][data-v="s1"]').click();await p1.locator('[data-a="toClient"]').click();await p1.locator('[data-a="sendMode"][data-v="kp"]').click();await p1.locator('[data-a="saveOfferVersion"]').click();await p1.locator('[data-a="offerArchive"]').click();await p1.locator('[data-a="savedOffer"]').first().click();
 const downloading=p1.waitForEvent('download',{timeout:30000});await p1.locator('[data-a="downloadSavedOffer"]').click();const download=await downloading;await download.saveAs(path.join(output,'browser-offer.pdf'));assert(fs.readFileSync(path.join(output,'browser-offer.pdf')).subarray(0,5).equals(Buffer.from('%PDF-')));
 await p1.screenshot({path:path.join(output,'mobile-offer.png'),fullPage:true});
 // Another Telegram account starts with an empty personal workspace.
 const p3=await browser.newPage({viewport:{width:1280,height:900}});await setup(p3,987654321);await p3.goto(url);await p3.locator('[data-a="viewCabinet"][data-v="manager"]').click();assert.equal(await p3.getByText('Kia Test',{exact:true}).count(),0); await p3.locator('[data-a="cabinets"]').first().click(); await p3.locator('[data-a="viewCabinet"][data-v="owner"]').click(); await p3.locator('[data-a="tab"][data-v="settings"]').click(); await p3.locator('[data-a="stab"][data-v="kp"]').click(); assert.equal(await p3.locator('#dealer-name').inputValue(),'');
 assert.deepEqual(errors,[]);console.log('PASS browser: mobile navigation, create lead, cloud save, second device reload, search, letterhead upload, conflict protection and recovery, saved offer PDF download, account isolation; no JS errors');
})().catch(e=>{console.error(e.stack);process.exitCode=1}).finally(async()=>{if(browser)await browser.close();if(server)server.close()});
