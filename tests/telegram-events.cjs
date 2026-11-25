// No browser or mini app runs in this test. Only authenticated CRM operations and the bot worker.
const assert=require('node:assert/strict');
const {randomInt,randomUUID}=require('node:crypto');
const {db,sql,rpc}=require('./local-workflow-db.cjs');

(async()=>{
 const owner=randomInt(10000000,80000000),manager=owner+1,other=owner+2,supplier=owner+3,slug=randomUUID();
 sql("insert into app_companies(slug,name) values(:'slug','Салон проверки'); insert into app_users(tg_id,name,role,company_id) select x.id,x.n,x.r,c.id from (values (:'owner'::bigint,'Владелец','owner'),(:'manager'::bigint,'Менеджер','manager'),(:'other'::bigint,'Другой менеджер','manager'),(:'supplier'::bigint,'Поставщик','supplier')) x(id,n,r),app_companies c where c.slug=:'slug';",{slug,owner,manager,other,supplier},true);
 const bot=await require('./local-workflow-bot.cjs')(db);
 const save=(id,version,data)=>rpc('crm_save_request',{p_actor:owner,p_id:id,p_version:version,p_data:data});
 const lead=save(null,0,{client_name:'Клиент проверки',phone:'79990000001',model:'Машина для теста',budget:2000000,consent_at:new Date().toISOString(),assigned_to:manager});
 const sent=(event)=>bot.messages.filter(m=>m.text.startsWith(event));
 const drain=async()=>{await bot.drain();await bot.drain();};
 save(lead.id,lead.version,{assigned_to:other,next_contact_at:new Date(Date.now()-60000).toISOString()});
 await drain();
 assert.deepEqual(sent('Вам назначена заявка').map(m=>Number(m.chat_id)),[other]);
 assert.deepEqual(sent('Пора связаться с клиентом').map(m=>Number(m.chat_id)),[other]);
 const card=new URL(sent('Вам назначена заявка')[0].reply_markup.inline_keyboard[0][0].web_app.url);
 assert.equal(card.searchParams.get('request'),lead.id);assert.equal(card.searchParams.get('section'),'client');
 const backend=(user,action,p)=>rpc('crm_backend',{p_actor:user,p_action:action,p:{request_id:lead.id,...p}});
 const offer=backend(other,'option.save',{title:'Вариант',description:'Белый автомобиль',scenario:'rf',currency:'RUB',input:{purchase:1000000,base_rate:1,logistics:0,duty:0,commission:0,documents:0,recycling:0},client_price:1001000,market_median:1500000});
 const option=offer.option;
 backend(other,'option.review',{id:option.id,version:option.version,decision:'requested'});
 await drain();assert.deepEqual(sent('Нужно согласовать цену').map(m=>Number(m.chat_id)),[owner]);
 backend(owner,'option.review',{id:option.id,version:option.version+1,decision:'rejected',note:'Уточните доставку'});
 await drain();assert.deepEqual(sent('Цена отклонена').map(m=>Number(m.chat_id)),[other]);
 assert.equal(new URL(sent('Цена отклонена')[0].reply_markup.inline_keyboard[0][0].web_app.url).searchParams.get('option'),option.id);
 assert(!bot.messages.some(m=>Number(m.chat_id)===supplier||Number(m.chat_id)===manager));
 console.log('PASS closed-app Telegram delivery, assignment, reassignment, contact reminder, approval/rejection, scoped links and duplicate drain');
})().catch(err=>{console.error(err);process.exitCode=1;});
