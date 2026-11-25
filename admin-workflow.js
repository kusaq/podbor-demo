'use strict';
window.PodborWorkflow = function({api,esc,render,flash,request,domain,isBusy,formatError,refreshCard}) {
  const root=document.getElementById('admin');
  const op=(name,data={})=>api('workflow.'+name,data);
  const fees={logistics:'Доставка до клиента',commission:'Комиссия',duty:'Пошлина',recycling:'Утильсбор',documents:'Оформление'};
  const currencies=['RUB','CNY','JPY','USD','EUR'];
  const states={pending:'В очереди',running:'Идёт поиск',ready:'Поиск завершён',unconfigured:'Источник не подключён',failed:'Ошибка',sent:'Доставлен',sending:'Отправляется',uncertain:'Проверить доставку'};
  let id='',inbox=null,network=null,networkDraft=null,policyDraft=null,selected='',thread='',revision=0,busy=false,error='',tokens={},formValues={},edited=false;
  const images=new Map();
  function reset(){
    revision++; id=''; inbox=network=networkDraft=policyDraft=null; selected=thread=error=''; formValues={};tokens={}; edited=false;images.clear();
  }
  async function load(requestId){
    const ticket=++revision;
    if(id!==requestId){inbox=null;thread='';formValues={};tokens={};edited=false;images.clear();}
    id=requestId; error='';
    try{const data=await op('inbox',{request_id:id});if(ticket===revision){inbox=data;if(!thread)thread=data.threads?.[0]?.id||'';}}
    catch(e){if(ticket===revision)error=formatError(e);}
  }
  async function networkLoad(){
    const ticket=++revision;
    try{const data=await op('network');if(ticket!==revision)return;network=data;policyDraft={...data.policy};pickSupplier(selected||data.suppliers?.[0]?.id);error='';}
    catch(e){if(ticket===revision)error=formatError(e);}
  }
  function pickSupplier(value){
    const row=network?.suppliers?.find(s=>String(s.id)===String(value));
    selected=row?String(row.id):'';networkDraft=row?{...row,brands:(row.brands||[]).join(', '),fees:{...row.fees}}:null;edited=false;
  }
  const action=(act,label,value='',style='small ghost')=>'<button type="button" class="btn '+style+'" data-flow="'+act+'" data-value="'+esc(value)+'">'+esc(label)+'</button>';
  function input(key,label,value,type='text',extra=''){
    return '<label class="field">'+esc(label)+'<input data-wf="'+key+'" type="'+type+'" value="'+esc(value??'')+'" '+extra+'></label>';
  }
  function networkHtml(){
    const d=networkDraft,p=policyDraft;
    const alert=error?'<p role="alert" class="error">'+esc(error)+'</p>':'';
    const title='<div class="heading"><h1 class="page-title">Поставщики</h1>'+action('network','Обновить')+'</div>';
    if(!network)return title+alert+'<p class="muted">Загрузка сети поставщиков…</p>';
    return title+alert+'<div class="supplier-layout"><section class="surface detail-body"><h2 class="section-title">Сеть поставщиков</h2>'+
      ((network.suppliers||[]).map(s=>'<button type="button" class="supplier-row" data-flow="pick" data-value="'+esc(s.id)+'" aria-pressed="'+(String(s.id)===selected)+'"><b>'+esc(s.name)+'</b><small>'+esc((s.brands||[]).join(', ')||'Марки не указаны')+'</small><small>'+(!s.active?'Доступ отключён':s.enabled?'Принимает запросы':'Рассылка выключена')+'</small></button>').join('')||'<p>Добавьте участника с ролью «Поставщик» в разделе «Команда».</p>')+
      '</section><section class="surface detail-body">'+(d?'<form id="wf-terms"><h2 class="section-title">'+esc(d.name)+'</h2><fieldset class="fields">'+
      (d.owned?input('brands','Марки через запятую',d.brands)+'<label class="check field"><input data-wf="enabled" type="checkbox" '+(d.enabled?'checked':'')+'>Получает запросы</label>':'')+
      '<label class="field">Валюта закупки<select data-wf="currency">'+currencies.map(c=>'<option '+(c===d.currency?'selected':'')+'>'+c+'</option>').join('')+'</select></label>'+
      Object.entries(fees).map(([k,label])=>input(k,label+', ₽',d.fees[k]??0,'number','min="0" max="1000000000" step="0.01" required')).join('')+'</fieldset><p class="footnote">Суммы подставляются в новые расчёты этого поставщика. Менеджер проверяет расходы и курс перед сохранением варианта.</p><button class="btn primary">Сохранить тариф</button></form>':'<p>Выберите поставщика для настройки тарифов.</p>')+'</section></div>'+
      (p?'<form id="wf-policy" class="surface detail-body"><h2 class="section-title">Сроки напоминаний</h2><fieldset class="fields">'+input('supplier_hours','Поставщику, часов',p.supplier_hours,'number','min="1" max="168" required')+input('escalation_hours','Ответственному менеджеру, часов',p.escalation_hours,'number','min="1" max="336" required')+input('client_days','После отправки КП, дней',p.client_days,'number','min="1" max="30" required')+'</fieldset><button class="btn">Сохранить сроки</button></form>':'');
  }
  function inboxHtml(){
    const alert=error?'<p role="alert" class="error">'+esc(error)+'</p>':'';
    if(!inbox)return alert+action('refresh','Загрузить ответы');
    const spec=inbox.spec||{},threads=inbox.threads||[],t=threads.find(t=>t.id===thread);
    const v=formValues;
    const writable=!request()?.archived_at&&['search','think'].includes(request()?.status);
    const search='<details class="domain-box"><summary>Параметры запроса поставщикам</summary><form id="wf-dispatch"><div class="fields">'+
      input('brand','Марка',v.brand??spec.brand??'')+input('color','Цвет',v.color??spec.color)+input('trim','Комплектация',v.trim??spec.trim)+'</div><p class="footnote">Запрос получат только новые подходящие поставщики. Уже открытые диалоги сохранятся.</p><button class="btn small">Найти поставщиков</button></form></details>';
    const channels=[...(inbox.sources||[])];if(inbox.listings?.length)channels.push({source:'manual',state:'ready',results:inbox.listings});
    const sources=channels.map(s=>'<div class="domain-box"><b>'+(s.source==='stock'?'МойСклад':s.source==='manual'?'Сохранённые объявления':'Объявления')+'</b><span class="sub">'+esc(states[s.state]||s.state)+(s.state==='ready'?' · '+s.results.length:'')+'</span>'+
      (s.results||[]).map((r,i)=>'<div class="row between"><span>'+esc(r.title)+' · '+esc(r.purchase??'Цена по запросу')+' '+esc(r.currency)+(r.link&&/^https:\/\//i.test(r.link)?' · <a target="_blank" rel="noreferrer" href="'+esc(r.link)+'">Объявление</a>':'')+'</span>'+action('source','В расчёт',s.source+':'+i)+'</div>').join('')+'</div>').join('');
    const messages=(t?.messages||[]).map(m=>'<li class="wf-message"><small>'+ (m.incoming?'Поставщик':'Менеджер')+' · '+esc(new Date(m.at).toLocaleString('ru-RU'))+(m.delivery?' · '+esc(states[m.delivery]||m.delivery):'')+'</small><p>'+esc(m.text||'Фото автомобиля')+'</p>'+
      ((m.photos||[]).length?'<div class="wf-photos">'+m.photos.map((key,i)=>images.has(key)?'<img alt="Фото автомобиля" src="'+esc(images.get(key))+'">':action('photo','Фото '+(i+1),key)).join('')+'</div>':'')+
      (m.incoming?(m.option_id?'<span class="status won">В подборе</span>':writable?action('use','Проверить и рассчитать',m.id):''):'')+'</li>').join('');
    const sentCars=inbox.sent_cars||[];
    const chosen=inbox.choice;
    const selection=chosen&&request()?.status==='won'?'<section class="domain-box"><h3>Выбор клиента</h3><b>'+esc(chosen.title)+'</b><span class="sub">КП № '+esc(chosen.number)+' · '+esc(Number(chosen.price).toLocaleString('ru-RU'))+' ₽</span></section>':'';
    const carPicker=sentCars.length?'<label class="field">Какую машину выбрал клиент<select data-wf="car" required><option value="">Выберите из отправленных КП</option>'+sentCars.map(c=>'<option value="'+esc(c.offer+'/'+c.option)+'" '+(v.car===c.offer+'/'+c.option?'selected':'')+'>'+esc(c.title)+' · '+esc(Number(c.price).toLocaleString('ru-RU'))+' ₽ · КП № '+esc(c.number)+'</option>').join('')+'</select></label>':'';
    const feedback=request()?.status==='think'?'<form class="domain-box" id="wf-feedback"><h3>Реакция клиента на КП</h3><label class="field">Итог<select data-wf="outcome">'+
      [['think','Продолжает выбирать'],['won','Заказ оформлен'],['lost','Отказ'],['no_answer','Не дозвонились']].map(([key,title])=>'<option value="'+key+'" '+((v.outcome||'think')===key?'selected':'')+'>'+title+'</option>').join('')+
      '</select></label>'+(v.outcome==='won'?carPicker:'')+input('note','Комментарий, при отказе укажите причину',v.note)+input('next','Следующий контакт',v.next,'datetime-local')+'<button class="btn small">Записать результат</button></form>':'';
    const sourcePanel='<details class="domain-box"><summary>МойСклад, Авто.ру и Авито</summary>'+sources+(writable?action('retry','Обновить поиск')+
      '<div class="row wrap"><a class="btn small ghost" target="_blank" rel="noreferrer" href="https://auto.ru/cars/all/">Открыть Авто.ру</a><a class="btn small ghost" target="_blank" rel="noreferrer" href="https://www.avito.ru/rossiya/avtomobili?q='+encodeURIComponent(request()?.model||'')+'">Найти на Авито</a></div><form id="wf-listing"><h4>Добавить объявление по ссылке</h4>'+input('listingUrl','Ссылка на объявление',v.listingUrl,'url','required')+input('listingTitle','Автомобиль',v.listingTitle,'text','required')+input('listingPrice','Цена объявления, ₽',v.listingPrice,'number','min="1"')+'<button class="btn small">Сохранить объявление</button></form>':'')+'</details>';
    const answered=threads.filter(t=>t.messages?.some(m=>m.incoming)).length;
    return selection+feedback+sourcePanel+'<section class="wf-inbox"><div class="row between"><h3>Ответили '+answered+' из '+threads.length+'</h3>'+action('refresh','Обновить ответы')+'</div>'+alert+(writable?search:'')+
      (threads.length?'<label class="field">Диалог<select data-wf="thread">'+threads.map(t=>'<option value="'+esc(t.id)+'" '+(t.id===thread?'selected':'')+'>'+esc(t.name)+' · '+esc(t.code)+'</option>').join('')+'</select></label>':'<p class="footnote">Диалогов пока нет. Проверьте марку и включённые профили поставщиков.</p>')+
      (t?'<p class="footnote">Первый запрос · '+esc(states[t.delivery]||'Подготовлен')+'</p><ol class="wf-log">'+messages+'</ol>'+(writable?'<form id="wf-reply"><label class="field">Ответ через бота<textarea data-wf="reply" required maxlength="2500" placeholder="Уточните состояние, цену или срок">'+esc(v.reply||'')+'</textarea></label><button class="btn small">Отправить поставщику</button></form>':''):'')+
      '</section>';
  }
  function photoPicker(d){
    if(!d.candidates?.length)return '';
    return '<div class="field full"><b>Фото для клиента</b><span class="footnote">Отметьте просмотренные снимки без контактов и водяных знаков поставщика.</span><div class="wf-photos">'+
      d.candidates.map(key=>{const src=images.get(key);return src?'<label><img alt="Фото автомобиля" src="'+esc(src)+'"><span><input type="checkbox" data-wf-photo="'+esc(key)+'" '+(d.photos.includes(key)?'checked':'')+'> Включить в КП</span></label>':action('photo','Показать фото',key);}).join('')+'</div></div>';
  }
  function draftFrom(t,m){
    const f=m.parsed||{},terms=t.terms||{},currency=f.currency||terms.currency||'RUB';
    const photos=[...new Set([...(m.photos||[]),...t.messages.filter(x=>x.incoming&&!x.option_id&&!x.text).flatMap(x=>x.photos||[])])];
    return {message_id:m.id,terms_revision:terms.revision||0,title:f.model||'',description:[f.years,f.mileage!=null?f.mileage+' км':'',f.spec].filter(Boolean).join(', '),
      purchase:f.purchase||'',term:f.term||'',currency,scenario:currency==='RUB'?'rf':'import',base_rate:currency==='RUB'?1:'',...terms.fees,photos:[],candidates:photos,source_name:'Запрос '+t.code};
  }
  async function run(fn){
    if(busy||isBusy()||domain().isBusy())return;
    busy=true;const ticket=revision;
    try{await fn();}catch(e){if(ticket===revision){error=formatError(e);flash(error);}}
    finally{busy=false;render();}
  }
  function refresh(){return load(id);}
  root.addEventListener('input',event=>{
    const el=event.target,k=el.dataset.wf;if(!k||k==='thread')return;
    const val=el.type==='checkbox'?el.checked:el.value;
    if(el.closest('#wf-policy'))policyDraft[k]=val;
    else if(el.closest('#wf-terms')){if(k in fees)networkDraft.fees[k]=val;else networkDraft[k]=val;}
    else formValues[k]=val;
    edited=true;
  });
  root.addEventListener('change',event=>{
    const el=event.target;
    if(el.dataset.wfPhoto){const d=domain().getDraft();if(!d)return;d.photos=el.checked?[...new Set([...d.photos,el.dataset.wfPhoto])]:d.photos.filter(x=>x!==el.dataset.wfPhoto);return;}
    if(el.dataset.wf==='outcome'){formValues.outcome=el.value;render();return;}
    if(el.dataset.wf==='thread'){if(formValues.reply?.trim()&&!confirm('Закрыть черновик ответа?')){el.value=thread;return;}thread=el.value;delete formValues.reply;delete tokens.reply;render();}
  });
  root.addEventListener('click',event=>{
    const el=event.target.closest('[data-flow]');if(!el)return;
    const act=el.dataset.flow,val=el.dataset.value;
    run(async()=>{
      if(act==='network'){if(!edited||confirm('Загрузить сохранённые настройки?'))await networkLoad();return;}
      if(act==='pick'){if(!edited||confirm('Закрыть несохранённые настройки?'))pickSupplier(val);return;}
      if(act==='refresh'){await refresh();return;}
      if(act==='retry'){await op('search.retry',{request_id:id});await refresh();return;}
      if(act==='photo'){const current=id;const photo=await op('photo',{request_id:id,id:val});if(current===id)images.set(val,photo.data);return;}
      let draft;
      if(act==='use'){const t=inbox.threads.find(t=>t.id===thread);const m=t?.messages.find(m=>m.id===val);if(m)draft=draftFrom(t,m);}
      if(act==='source'){
        const [name,index]=val.split(':');const row=name==='manual'?inbox.listings?.[index]:inbox.sources.find(s=>s.source===name)?.results[index];
        if(row)draft={title:row.title,purchase:row.purchase||'',term:row.term,currency:row.currency,scenario:row.currency==='RUB'?'rf':'import',base_rate:row.currency==='RUB'?1:'',source_name:name==='stock'?'МойСклад':String(row.link||'Объявление').slice(0,200),client_price:''};
      }
      if(draft&&domain().startDraft(draft))requestAnimationFrame(()=>document.querySelector('#domainOptionForm')?.scrollIntoView({block:'start'}));
    });
  });
  root.addEventListener('submit',event=>{
    const form=event.target;if(!form.id.startsWith('wf-'))return;event.preventDefault();
    run(async()=>{
      if(form.id==='wf-policy'){
        const p=policyDraft;if(+p.escalation_hours<+p.supplier_hours){flash('Срок уведомления менеджера должен быть не меньше срока поставщика');return;}
        await op('policy.save',p);await networkLoad();flash('Сроки сохранены');return;
      }
      if(form.id==='wf-terms'){
        const d=networkDraft;await op('terms.save',{id:d.id,revision:d.revision,enabled:d.enabled,currency:d.currency,
          brands:d.brands.split(',').map(s=>s.trim()).filter(Boolean),fees:Object.fromEntries(Object.keys(fees).map(k=>[k,Number(d.fees[k]||0)]))});
        await networkLoad();flash('Тариф сохранён');return;
      }
      if(form.id==='wf-listing'){
        await op('listing.save',{request_id:id,url:formValues.listingUrl,title:formValues.listingTitle,purchase:formValues.listingPrice||null});
        delete formValues.listingUrl;delete formValues.listingTitle;delete formValues.listingPrice;flash('Объявление сохранено');
      }
      if(form.id==='wf-feedback'){
        const d=request(), outcome=formValues.outcome||'think', note=String(formValues.note||'').trim();
        if(outcome==='lost'&&!note){flash('Укажите причину отказа');return;}
        if(outcome==='no_answer'&&!formValues.next){flash('Укажите время следующего звонка');return;}
        const next=['no_answer','think'].includes(outcome)&&formValues.next?new Date(formValues.next).toISOString():null;
        const data={status:outcome==='no_answer'?'think':outcome,next_contact_at:next,...(outcome==='lost'?{reasons:['Другое'],main_reason:'Другое',note}:{})};
        const payload={id,version:d.version,result:outcome==='no_answer'?'no_answer':'connected',note,data};
        const key=JSON.stringify([payload,formValues.car]);if(tokens.feedbackKey!==key){tokens.feedbackKey=key;tokens.feedback=crypto.randomUUID();}
        if(outcome==='won'&&inbox.sent_cars?.length){
          const car=inbox.sent_cars.find(c=>c.offer+'/'+c.option===formValues.car);
          if(!car){flash('Выберите автомобиль из отправленного КП');return;}
          await op('choose_car',{request_id:id,version:d.version,offer:car.offer,option:car.option,note,token:tokens.feedback});
        }else await api('crm.contact.save',{...payload,token:tokens.feedback});formValues={};edited=false;await refreshCard(id);flash('Результат сохранён в истории клиента');return;
      }
      if(form.id==='wf-reply'){
        const text=(formValues.reply||'').trim();if(!text)return;
        if(!confirm('Отправить это сообщение поставщику?\n\n'+text))return;
        if(tokens.text!==text){tokens.reply=crypto.randomUUID();tokens.text=text;}
        await op('reply',{request_id:id,thread_id:thread,text,token:tokens.reply});delete formValues.reply;tokens={};flash('Ответ в очереди на отправку');
      }
      if(form.id==='wf-dispatch'){
        const spec=inbox.spec||{};
        const j=await op('dispatch',{request_id:id,brand:formValues.brand??spec.brand??'',color:formValues.color??spec.color??'',trim:formValues.trim??spec.trim??''});flash('Новых запросов в очереди: '+j.queued);
      }
      edited=false;await refresh();
    });
  });
  function existingPhotos(d){
    if(!d.id||!inbox)return d;
    for(const t of inbox.threads||[]){
      const m=t.messages.find(m=>m.option_id===d.id);if(!m)continue;
      return {...d,message_id:m.id,terms_revision:0,photos:d.photo_ids||[],candidates:[...new Set([...(d.photo_ids||[]),...draftFrom(t,m).candidates])]};
    }
    return d;
  }
  return {reset,load,networkLoad,networkHtml,inboxHtml,photoPicker,existingPhotos,dirty:()=>edited,busy:()=>busy};
};
