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
      ((network.suppliers||[]).map(s=>'<button type="button" class="supplier-row" data-flow="pick" data-value="'+esc(s.id)+'" aria-pressed="'+(String(s.id)===selected)+'"><b>'+esc(s.name)+'</b><small>'+esc((s.brands||[]).join(', ')||'Марки не указаны')+'</small><small>'+(!s.active?'Доступ отключён':s.enabled&&s.routing_enabled!==false?'Принимает запросы':'Рассылка выключена')+'</small></button>').join('')||'<p>Добавьте участника с ролью «Поставщик» в разделе «Команда».</p>')+
      '</section><section class="surface detail-body">'+(d?'<form id="wf-terms"><h2 class="section-title">'+esc(d.name)+'</h2><fieldset class="fields">'+
      (d.owned?input('brands','Марки через запятую',d.brands)+'<label class="check field"><input data-wf="enabled" type="checkbox" '+(d.enabled?'checked':'')+'>Получает запросы</label>':'')+
      '<label class="check field"><input data-wf="routing_enabled" type="checkbox" '+(d.routing_enabled!==false?'checked':'')+'>Включить в рассылки этого салона</label>'+
      '<label class="field">Валюта закупки<select data-wf="currency">'+currencies.map(c=>'<option '+(c===d.currency?'selected':'')+'>'+c+'</option>').join('')+'</select></label>'+
      Object.entries(fees).map(([k,label])=>input(k,label+', ₽',d.fees[k]??0,'number','min="0" max="1000000000" step="0.01" required')).join('')+'</fieldset><p class="footnote">Суммы подставляются в новые расчёты этого поставщика. Менеджер проверяет расходы и курс перед сохранением варианта.</p><button class="btn primary">Сохранить тариф</button></form>':'<p>Выберите поставщика для настройки тарифов.</p>')+'</section></div>'+
      (p?'<form id="wf-policy" class="surface detail-body"><h2 class="section-title">Сроки напоминаний</h2><fieldset class="fields">'+input('supplier_hours','Поставщику, часов',p.supplier_hours,'number','min="1" max="168" required')+input('escalation_hours','Ответственному менеджеру, часов',p.escalation_hours,'number','min="1" max="336" required')+input('client_days','После отправки КП, дней',p.client_days,'number','min="1" max="30" required')+'</fieldset>'+(network.manager_flow?'<h3>Допуски при сравнении с заявкой</h3><fieldset class="fields">'+input('year_slack','Отклонение по году, лет',p.year_slack??0,'number','min="0" max="10" required')+input('km_slack','Превышение пробега, км',p.km_slack??0,'number','min="0" max="1000000" required')+input('budget_pct','Превышение бюджета, %',p.budget_pct??0,'number','min="0" max="100" step="0.1" required')+'</fieldset>':'')+'<button class="btn">Сохранить сроки</button></form>':'');
  }
  function orderHtml(o){
    if(!o)return '';
    const s=o.snapshot||{},car=s.car||{},chosen=s.choice||{};
    const fields=[['Клиент',s.client],['Телефон',s.phone],['Город доставки',s.city],['Менеджер при оформлении',s.manager],['Из КП',chosen.number?'№ '+chosen.number:null],
      ['Автомобиль',car.title||chosen.title||'Клиентский выбор ещё не записан'],['Описание',car.description],['Срок',car.term],['Цена клиенту',chosen.price!=null?Number(chosen.price).toLocaleString('ru-RU')+' ₽':null],
      ['Источник',s.source],['Расчёт стороны',s.quote?.purchase?Number(s.quote.purchase).toLocaleString('ru-RU')+' '+s.currency+(s.quote.quote_mode==='turnkey'?' под ключ':''):null],
      ['Себестоимость с доставкой',s.cost!=null?Number(s.cost).toLocaleString('ru-RU')+' ₽':null]];
    return '<section class="domain-box order-card"><h3>Карточка заказа</h3><span class="sub">№ '+esc(o.id.slice(0,8))+' · '+esc(new Date(o.created_at).toLocaleString('ru-RU'))+'</span><dl>'+fields.filter(([,v])=>v).map(([k,v])=>'<div><dt>'+esc(k)+'</dt><dd>'+esc(v)+'</dd></div>').join('')+'</dl></section>';
  }
  function listingFields(v){
    if(!inbox?.manager_flow)return '';
    return input('listingPhone','Телефон продавца',v.listingPhone,'tel','placeholder="+7"')+
      '<label class="field">Расчёт стороны<select data-wf="listingMode"><option value="itemized">Цена закупки</option><option value="turnkey" '+(v.listingMode==='turnkey'?'selected':'')+'>Под ключ</option></select></label>'+
      '<details><summary>Характеристики объявления</summary><div class="fields">'+Object.entries(window.PodborLots.attrs).map(([key,label])=>input('listing_'+key,label,v['listing_'+key],['year','mileage'].includes(key)?'number':'text')).join('')+'</div></details>';
  }
  function inboxHtml(){
    const alert=error?'<p role="alert" class="error">'+esc(error)+'</p>':'';
    if(!inbox)return alert+action('refresh','Загрузить ответы');
    const spec=inbox.spec||{},threads=inbox.threads||[],t=threads.find(t=>t.id===thread);
    const v=formValues;
    const writable=!request()?.archived_at&&['search','think'].includes(request()?.status);
    const search='<details class="domain-box"><summary>Параметры запроса поставщикам</summary><form id="wf-dispatch"><div class="fields">'+
      input('brand','Марка',v.brand??spec.brand??'')+input('color','Цвет',v.color??spec.color)+input('trim','Комплектация',v.trim??spec.trim)+'</div><p class="footnote">Запрос получат только новые подходящие поставщики. Уже открытые диалоги сохранятся.</p><button class="btn small">Выбрать получателей</button></form></details>';
    const channels=[...(inbox.sources||[])];if(inbox.listings?.length)channels.push({source:'manual',state:'ready',results:inbox.listings});
    const sources=channels.map(s=>'<div class="domain-box"><b>'+(s.source==='stock'?'МойСклад':s.source==='manual'?'Сохранённые объявления':'Объявления')+'</b><span class="sub">'+esc(states[s.state]||s.state)+(s.state==='ready'?' · '+s.results.length:'')+'</span>'+
      (s.results||[]).map((r,i)=>'<div class="row between"><span>'+esc(r.title)+' · '+esc(r.purchase??'Цена по запросу')+' '+esc(r.currency)+(r.link&&/^https:\/\//i.test(r.link)?' · <a target="_blank" rel="noreferrer" href="'+esc(r.link)+'">Объявление</a>':'')+'</span>'+action('source','В расчёт',s.source+':'+i)+'</div>').join('')+'</div>').join('');
    const messages=(t?.messages||[]).map(m=>'<li class="wf-message"><small>'+ (m.incoming?'Поставщик':'Менеджер')+' · '+esc(new Date(m.at).toLocaleString('ru-RU'))+(m.delivery?' · '+esc(states[m.delivery]||m.delivery):'')+'</small><p>'+esc(m.text||'Фото автомобиля')+'</p>'+
      ((m.photos||[]).length?'<div class="wf-photos">'+m.photos.map((key,i)=>images.has(key)?'<img alt="Фото автомобиля" src="'+esc(images.get(key))+'">':action('photo','Фото '+(i+1),key)).join('')+'</div>':'')+
      (m.incoming?(m.option_id?'<span class="status won">В подборе</span>':writable?action('use','Проверить и рассчитать',m.id):''):'')+'</li>').join('');
    const sentCars=inbox.sent_cars||[];
    const chosen=inbox.choice;
    const selection=!inbox.order&&chosen&&request()?.status==='won'?'<section class="domain-box"><h3>Выбор клиента</h3><b>'+esc(chosen.title)+'</b><span class="sub">КП № '+esc(chosen.number)+' · '+esc(Number(chosen.price).toLocaleString('ru-RU'))+' ₽</span></section>':'';
    const carPicker=sentCars.length?'<label class="field">Какую машину выбрал клиент<select data-wf="car" required><option value="">Выберите из отправленных КП</option>'+sentCars.map(c=>'<option value="'+esc(c.offer+'/'+c.option)+'" '+(v.car===c.offer+'/'+c.option?'selected':'')+'>'+esc(c.title)+' · '+esc(Number(c.price).toLocaleString('ru-RU'))+' ₽ · КП № '+esc(c.number)+'</option>').join('')+'</select></label>':'';
    const unlinked=request()?.status==='won'&&!request()?.archived_at&&!chosen&&sentCars.length;
    const feedback=unlinked?'<form class="domain-box" id="wf-link-car">'+carPicker+'<button class="btn small">Записать выбранную машину</button></form>':request()?.status==='think'?'<form class="domain-box" id="wf-feedback"><h3>Реакция клиента на КП</h3><label class="field">Итог<select data-wf="outcome">'+
      [['think','Продолжает выбирать'],['won','Заказ оформлен'],['lost','Отказ'],['no_answer','Не дозвонились']].map(([key,title])=>'<option value="'+key+'" '+((v.outcome||'think')===key?'selected':'')+'>'+title+'</option>').join('')+
      '</select></label>'+(v.outcome==='won'?carPicker:'')+input('note','Комментарий, при отказе укажите причину',v.note)+input('next','Следующий контакт',v.next,'datetime-local')+'<button class="btn small">Записать результат</button></form>':'';
    const sourcePanel='<details class="domain-box"><summary>МойСклад, Авто.ру и Авито</summary>'+sources+(writable?action('retry','Обновить поиск')+
      '<div class="row wrap"><a class="btn small ghost" target="_blank" rel="noreferrer" href="https://auto.ru/cars/all/">Открыть Авто.ру</a><a class="btn small ghost" target="_blank" rel="noreferrer" href="https://www.avito.ru/rossiya/avtomobili?q='+encodeURIComponent(request()?.model||'')+'">Найти на Авито</a></div><form id="wf-listing"><h4>Добавить объявление по ссылке</h4>'+input('listingUrl','Ссылка на объявление',v.listingUrl,'url','required')+input('listingTitle','Автомобиль',v.listingTitle,'text','required')+input('listingPrice','Цена объявления, ₽',v.listingPrice,'number','min="1"')+listingFields(v)+'<button class="btn small">Сохранить объявление</button></form>':'')+'</details>';
    const answered=threads.filter(t=>t.messages?.some(m=>m.incoming)).length;
    const filterPanel=inbox.lot_media&&writable?'<details class="domain-box"><summary>Фильтры подбора'+(Object.keys(spec.filters||{}).length?' · '+Object.keys(spec.filters).length:'')+'</summary><form id="wf-filters"><div class="lot-filter-fields">'+window.PodborLotTools.inputs(spec.filters)+'</div><button class="btn small" type="submit">Применить фильтры</button></form></details>':'';
    return orderHtml(inbox.order)+selection+feedback+filterPanel+(inbox.manager_flow?window.PodborLots.comparison(request()||{},inbox,domain().options()):'')+sourcePanel+(inbox.manager_flow?window.PodborLots.callQueue(inbox.listings,writable):'')+'<section class="wf-inbox"><div class="row between"><h3>Ответили '+answered+' из '+threads.length+'</h3>'+action('refresh','Обновить ответы')+'</div>'+alert+(writable?search:'')+
      (threads.length?'<label class="field">Диалог<select data-wf="thread">'+threads.map(t=>'<option value="'+esc(t.id)+'" '+(t.id===thread?'selected':'')+'>'+esc(t.name)+' · '+esc(t.code)+'</option>').join('')+'</select></label>':'<p class="footnote">Диалогов пока нет. Проверьте марку и включённые профили поставщиков.</p>')+
      (t?'<p class="footnote">Первый запрос · '+esc(states[t.delivery]||'Подготовлен')+'</p><ol class="wf-log">'+messages+'</ol>'+(writable?'<form id="wf-reply"><label class="field">Ответ через бота<textarea data-wf="reply" required maxlength="2500" placeholder="Уточните состояние, цену или срок">'+esc(v.reply||'')+'</textarea></label><button class="btn small">Отправить поставщику</button></form>':''):'')+
      '</section>';
  }
  function photoPicker(d){
    const upload=inbox?.lot_media?'<div class="lot-drop"><label>Добавить фото<input type="file" accept="image/*" multiple data-upload-photos></label><small>Можно выбрать несколько снимков или перетащить их сюда. До 10 фото в КП.</small><span role="status" data-upload-status></span></div>':'';
    const candidates=[...new Set([...(d.candidates||[]),...(d.photo_ids||[]),...(d.uploads||[]).map(x=>x.id)])];
    if(!candidates.length&&!upload)return '';
    return '<div class="field full"><b>Фото для клиента</b><span class="footnote">Отметьте просмотренные снимки без контактов и водяных знаков поставщика.</span>'+upload+'<div class="wf-photos">'+
      candidates.map(key=>{const src=d.uploads?.find(x=>x.id===key)?.src||images.get(key);return src?'<label><img alt="Фото автомобиля" src="'+esc(src)+'"><span><input type="checkbox" data-wf-photo="'+esc(key)+'" '+((d.photos||d.photo_ids||[]).includes(key)?'checked':'')+'> Включить в КП</span></label>':action('photo','Показать фото',key);}).join('')+'</div></div>';
  }
  async function addPhotos(files){
    const d=domain().getDraft();if(!d||!files?.length||d.loadingPhotos)return;
    d.loadingPhotos=true;const status=root.querySelector('[data-upload-status]');let errorText='';
    try{
      const current=d.photos||d.photo_ids||[];if(current.length+files.length>10)throw Error('Можно выбрать до 10 фото. Снимите отметки с лишних.');
      if(status)status.textContent='Подготовка фото…';
      const items=[];for(const f of files)items.push(await window.PodborLotTools.imageFile(f));
      if(domain().getDraft()!==d)return;
      d.uploads=[...(d.uploads||[]).filter(x=>current.includes(x.id)),...items];d.photos=[...current,...items.map(x=>x.id)];domain().markDirty();
    }catch(e){errorText=e.name==='EncodingError'?'Браузер не открыл этот снимок. Выберите JPEG, PNG или WebP.':e.message;}
    finally{d.loadingPhotos=false;if(domain().getDraft()===d){render();if(errorText)flash(errorText);}}
  }
  root.addEventListener('change',e=>{if(e.target.matches('[data-upload-photos]'))addPhotos([...e.target.files]);});
  root.addEventListener('dragover',e=>{if(e.target.closest('.lot-drop'))e.preventDefault();});
  root.addEventListener('drop',e=>{if(e.target.closest('.lot-drop')){e.preventDefault();addPhotos([...e.dataTransfer.files]);}});
  async function savePhotos(d,option){
    if(!inbox?.lot_media)return false;
    const photos=d.photos||d.photo_ids||[],uploads=(d.uploads||[]).filter(x=>photos.includes(x.id)).map(x=>({id:x.id,jpeg:x.src.split(',')[1]}));
    if(!photos.length&&!d.photo_ids?.length&&!d.message_id)return false;
    const fields={request_id:id,option,message_id:d.message_id||null,terms_revision:d.terms_revision||0,photos};
    const key=JSON.stringify(fields);if(d.photoWriteKey!==key){d.photoWriteKey=key;d.photoToken=crypto.randomUUID();}
    await op('option.withPhotos',{...fields,uploads,token:d.photoToken});return true;
  }
  async function previewPhotos(d){
    const current=id,keys=[...new Set([...(d.candidates||[]),...(d.photo_ids||[])])].filter(key=>!images.has(key)).slice(0,10);
    for(let i=0;i<keys.length;i+=3){
      if(current!==id||domain().getDraft()!==d)return;
      await Promise.all(keys.slice(i,i+3).map(async key=>{
        try{const photo=await op('photo',{request_id:current,id:key});if(current===id)images.set(key,photo.data);}catch{/* The thumbnail button allows a retry. */}
      }));
    }
    if(keys.length&&current===id&&domain().getDraft()===d)render();
  }
  function draftFrom(t,m){
    const f=m.parsed||{},terms=t.terms||{},currency=f.currency||terms.currency||'RUB';
    const photos=m.photos||[];
    return {message_id:m.id,terms_revision:terms.revision||0,title:f.model||'',description:[f.years,f.mileage!=null?f.mileage+' км':'',f.spec].filter(Boolean).join(', '),
      purchase:f.purchase||'',term:f.term||'',currency,scenario:currency==='RUB'?'rf':'import',base_rate:currency==='RUB'?1:'',...(f.quote_mode==='turnkey'?{}:terms.fees),...Object.fromEntries(Object.keys(fees).filter(k=>f[k]!=null).map(k=>[k,f[k]])),quote_mode:f.quote_mode||'itemized',vehicle:{year:f.years,mileage:f.mileage,generation:f.generation,color:f.color,trim:f.trim,body:f.body,gearbox:f.gearbox,fuel:f.fuel,drive:f.drive},photos:[],candidates:photos,source_name:'Запрос '+t.code};
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
    if(el.matches('[data-show-outside]')){el.closest('#lot-comparison').classList.toggle('show-all-lots',el.checked);return;}
    if(el.dataset.wfPhoto){const d=domain().getDraft();if(!d)return;const current=d.photos||d.photo_ids||[];if(el.checked&&current.length>=10){el.checked=false;flash('В КП можно включить до 10 фото');return;}d.photos=el.checked?[...new Set([...current,el.dataset.wfPhoto])]:current.filter(x=>x!==el.dataset.wfPhoto);domain().markDirty();return;}
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
        if(row)draft={title:row.title,quote_mode:row.quote_mode||'itemized',vehicle:{...row.vehicle,listing_url:row.link||undefined},purchase:row.calls?.find(c=>c.actual_price!=null)?.actual_price??row.purchase??'',term:row.term,currency:row.currency,scenario:row.currency==='RUB'?'rf':'import',base_rate:row.currency==='RUB'?1:'',source_name:name==='stock'?'МойСклад':String(row.link||'Объявление').slice(0,200),client_price:''};
      }
      if(draft&&domain().startDraft(draft)){previewPhotos(domain().getDraft());requestAnimationFrame(()=>document.querySelector('#domainOptionForm')?.scrollIntoView({block:'start'}));}
    });
  });
  root.addEventListener('submit',event=>{
    const form=event.target;if(form.matches('[data-lot-call]')){
      event.preventDefault();if(busy||isBusy())return;
      const button=form.querySelector('button[type="submit"]');button.disabled=true;busy=true;
      (async()=>{try{if(await window.PodborLots.saveCall(form,inbox.listings,id,api)){await refresh();render();flash('Звонок сохранён');}}
        catch(e){flash(formatError(e));}finally{busy=false;button.disabled=false;}})();return;
    }if(!form.id.startsWith('wf-'))return;event.preventDefault();
    run(async()=>{
      if(form.id==='wf-filters'){
        const f=window.PodborLotTools.values(form);if(!window.PodborLotTools.ranges(f)){flash('Проверьте границы диапазонов');return;}
        const s=inbox.spec||{};await op('dispatch',{request_id:id,brand:s.brand||'',color:s.color||'',trim:s.trim||'',filters:f,recipients:[]});
        await refresh();flash('Фильтры сохранены');return;
      }
      if(form.id==='wf-policy'){
        const p=policyDraft;if(+p.escalation_hours<+p.supplier_hours){flash('Срок уведомления менеджера должен быть не меньше срока поставщика');return;}
        await op('policy.save',p);await networkLoad();flash('Сроки сохранены');return;
      }
      if(form.id==='wf-terms'){
        const d=networkDraft;await op('terms.save',{id:d.id,revision:d.revision,enabled:d.enabled,routing_enabled:d.routing_enabled!==false,currency:d.currency,
          brands:d.brands.split(',').map(s=>s.trim()).filter(Boolean),fees:Object.fromEntries(Object.keys(fees).map(k=>[k,Number(d.fees[k]||0)]))});
        await networkLoad();flash('Тариф сохранён');return;
      }
      if(form.id==='wf-listing'){
        const v=formValues,phone=(v.listingPhone||'').replace(/[^\d+]/g,'').replace(/^8(?=\d{10}$)/,'+7');
        if(phone&&!/^\+?\d{10,15}$/.test(phone)){flash('Проверьте телефон продавца');return;}
        const vehicle=Object.fromEntries(Object.keys(window.PodborLots.attrs).filter(k=>v['listing_'+k]).map(k=>[k,v['listing_'+k]]));
        await op('listing.save',{request_id:id,url:v.listingUrl,title:v.listingTitle,purchase:v.listingPrice||null,phone,vehicle,quote_mode:v.listingMode||'itemized'});
        Object.keys(v).filter(k=>k.startsWith('listing')).forEach(k=>delete v[k]);
        delete formValues.listingUrl;delete formValues.listingTitle;delete formValues.listingPrice;flash('Объявление сохранено');
      }
      if(form.id==='wf-feedback'||form.id==='wf-link-car'){
        const d=request(), outcome=form.id==='wf-link-car'?'won':formValues.outcome||'think', note=String(formValues.note||'').trim();
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
        const q={request_id:id,model:request()?.model,brand:formValues.brand??spec.brand??'',color:formValues.color??spec.color??'',trim:formValues.trim??spec.trim??'',filters:spec.filters||{}};
        const picked=await window.PodborLotTools.route(api,q,false);if(!picked)return;
        const j=await op('dispatch',{...q,...picked});flash('Новых запросов в очереди: '+j.queued);
      }
      edited=false;await refresh();
    });
  });
  function existingPhotos(d){
    queueMicrotask(()=>{const draft=domain().getDraft();if(draft)previewPhotos(draft);});
    if(!d.id||!inbox)return d;
    for(const t of inbox.threads||[]){
      const m=t.messages.find(m=>m.option_id===d.id);if(!m)continue;
      return {...d,message_id:m.id,terms_revision:0,photos:d.photo_ids||[],candidates:[...new Set([...(d.photo_ids||[]),...draftFrom(t,m).candidates])]};
    }
    return d;
  }
  return {savePhotos,extended:()=>!!inbox?.manager_flow,reset,load,networkLoad,networkHtml,inboxHtml,photoPicker,existingPhotos,dirty:()=>edited,busy:()=>busy};
};
