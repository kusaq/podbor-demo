'use strict';
(() => {
  const clean = value => String(value || '').toLocaleLowerCase('ru').replace(/ё/g,'е').replace(/[^\p{L}\p{N}]+/gu,' ').trim();
  const esc = value => String(value ?? '').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  let loading, snapshot, makes, entries, active, ticket = 0, generation = 0, tenantApi, extraRequest, companyKey;
  function connect(api,key){
    if(companyKey===key&&tenantApi===api)return;
    companyKey=key;tenantApi=api;++generation;extraRequest=null;loading=null;
  }
  function extras(){
    if(!tenantApi)return Promise.resolve([]);
    if(!extraRequest){const version=generation;extraRequest=tenantApi('workflow.catalog').then(data=>data.models||[]).catch(error=>{if(generation===version)extraRequest=null;throw error;});}
    return extraRequest;
  }
  const sort = (a,b) => a.localeCompare(b,'ru',{numeric:true});
  async function load(){
    const version=generation;
    if(!snapshot)snapshot=fetch(new URL('assets/vehicle-catalog.json',document.baseURI)).then(response=>{if(!response.ok)throw Error();return response.json();}).catch(error=>{snapshot=null;throw error;});
    if(!loading) loading = Promise.all([snapshot,extras().catch(()=>[])]).then(([rows,additional])=>{
      if(version!==generation)return load();
      makes=rows.map(([country,name,alias,models])=>({country,name,alias,models:[...models]}));
      for(const row of additional){
        let make=makes.find(m=>clean(m.name)===clean(row.make));
        if(!make){make={country:row.country,name:row.make,alias:'',models:[]};makes.push(make);}
        if(!make.models.some(([name])=>clean(name)===clean(row.model)))make.models.push([row.model,'']);
      }
      entries=makes.flatMap(make=>make.models.map(([model,alias])=>{
        const title=make.name+' '+model;
        return {make,model,title,terms:[title,make.alias+' '+alias,make.name+' '+alias,make.alias+' '+model,alias,model].map(clean)};
      }));
    }).catch(error=>{loading=null;throw error;});
    return loading;
  }
  function search(query,brand,country){
    const words=clean(query).split(' ').filter(Boolean);
    if(!words.length)return [];
    return entries.filter(e=>(!brand||e.make.name===brand)&&(!country||country===e.make.country)).map(e=>{
      const score=Math.min(...e.terms.map(term=>term===words.join(' ')?0:term.startsWith(words.join(' '))?1:
        words.every(w=>term.split(' ').some(t=>t.startsWith(w)))?2:9));
      return {e,score};
    }).filter(x=>x.score<9).sort((a,b)=>a.score-b.score||sort(a.e.title,b.e.title)).slice(0,12).map(x=>x.e);
  }
  function clear(){
    ++ticket;
    if(active){active.input.setAttribute('aria-expanded','false');active.input.removeAttribute('aria-activedescendant');active.box.remove();active=null;}
  }
  function pick(input,make,model){
    clear();
    input.value=make+' '+model;
    input.dispatchEvent(new Event('input',{bubbles:true}));
    input.dispatchEvent(new CustomEvent('vehicle-picked',{bubbles:true,detail:{make,model}}));
    clear();input.focus();
  }
  const mainField = el => el.matches('#fm,#d-model');
  async function suggest(input){
    clear();const value=input.value.trim();if(!value)return;
    const version=ticket;
    try{await load();}catch{return;}
    if(ticket!==version||!input.isConnected||input!==document.activeElement)return;
    const found=search(value);
    const box=document.createElement('div');box.className='vehicle-hits';box.id='vehicle-hits';box.setAttribute('role','listbox');box.setAttribute('aria-label','Подходящие модели');
    box.innerHTML=found.length?found.map((e,i)=>'<button type="button" tabindex="-1" role="option" aria-selected="false" id="vehicle-hit-'+i+'">'+esc(e.title)+'<small>'+esc(e.make.country)+'</small></button>').join(''):'<small>Совпадений нет. Можно сохранить своё название.</small>';
    input.insertAdjacentElement('afterend',box);input.setAttribute('aria-expanded','true');
    active={input,box,found,index:-1};
    box.addEventListener('pointerdown',e=>e.preventDefault());
    box.addEventListener('click',e=>{const btn=e.target.closest('button');if(btn){const row=found[Array.from(box.children).indexOf(btn)];pick(input,row.make.name,row.model);}});
  }
  function prepare(input){
    input.setAttribute('role','combobox');input.setAttribute('aria-autocomplete','list');input.setAttribute('aria-controls','vehicle-hits');input.setAttribute('aria-expanded','false');input.autocomplete='off';
  }
  document.addEventListener('focusin',e=>{if(mainField(e.target))prepare(e.target);else if(active&&!active.box.contains(e.target))clear();});
  document.addEventListener('focusout',e=>{if(active?.input===e.target)clear();});
  document.addEventListener('input',e=>{if(mainField(e.target))suggest(e.target);});
  document.addEventListener('keydown',e=>{
    if(!active||active.input!==e.target)return;
    const a=active;
    if(e.key==='Escape'){e.preventDefault();e.stopPropagation();clear();return;}
    if(!a.found.length)return;
    if(e.key==='Enter'&&a.index>=0){e.preventDefault();const row=a.found[a.index];pick(a.input,row.make.name,row.model);return;}
    if(!['ArrowDown','ArrowUp'].includes(e.key))return;e.preventDefault();
    a.index=e.key==='ArrowDown'?(a.index+1)%a.found.length:(a.index<=0?a.found.length-1:a.index-1);
    Array.from(a.box.children).forEach((el,i)=>el.setAttribute('aria-selected',String(i===a.index)));
    const option=a.box.children[a.index];a.input.setAttribute('aria-activedescendant',option.id);option.scrollIntoView({block:'nearest'});
  },true);
  function open(trigger,onChoose,allowMake){
    clear();
    const dlg=document.createElement('dialog');dlg.className='vehicle-dialog';dlg.setAttribute('aria-labelledby','vehicle-title');
    dlg.innerHTML='<header><h2 id="vehicle-title">'+(allowMake?'Специализация поставщика':'Каталог автомобилей')+'</h2><button type="button" aria-label="Закрыть каталог">×</button></header><label>Поиск по марке или модели<input type="search" autocomplete="off" placeholder="Например, Камри"></label><label>Страна производителя<select name="country"><option value="">Все страны</option></select></label><label>Марка<select name="make"><option value="">Все марки</option></select></label><div class="vehicle-results" aria-live="polite">Загружаем каталог…</div>';
    document.body.append(dlg);dlg.showModal();
    const [country,brand]=dlg.querySelectorAll('select'), query=dlg.querySelector('input'), list=dlg.querySelector('.vehicle-results');
    dlg.querySelector('header button').onclick=()=>dlg.close();
    dlg.addEventListener('close',()=>{dlg.remove();if(trigger.isConnected)trigger.focus();},{once:true});
    const options=values=>values.map(v=>'<option>'+esc(v)+'</option>').join('');
    function choices(){
      brand.innerHTML='<option value="">Все марки</option>'+options(makes.filter(m=>!country.value||m.country===country.value).map(m=>m.name).sort(sort));
    }
    function render(){
      const make=makes.find(m=>m.name===brand.value);
      let rows=[];
      if(query.value.trim()){
        const allowed=country.value;
        rows=search(query.value,brand.value,allowed);
      }else if(make)rows=entries.filter(e=>e.make===make).sort((a,b)=>sort(a.model,b.model));
      const possible=makes.filter(m=>(!country.value||m.country===country.value)&&(!make||m===make)&&[m.name,m.alias].some(v=>clean(v).startsWith(clean(query.value))));
      const brands=allowMake&&(query.value.trim()||make)?possible.slice(0,12):[];
      list.innerHTML=brands.map((m,i)=>'<button type="button" data-make="'+i+'"><b>'+esc(m.name)+'</b><small>Все модели</small></button>').join('')+
        rows.map((r,i)=>'<button type="button" data-model="'+i+'">'+esc(r.title)+'<small>'+esc(r.make.country)+'</small></button>').join('')||
        (query.value.trim()?'<p>Совпадений нет. Можно ввести название вручную.</p>':'<p>Выберите марку или начните вводить модель.</p>');
      list.onclick=e=>{const btn=e.target.closest('button');if(!btn)return;const row=rows[Number(btn.dataset.model)],m=brands[Number(btn.dataset.make)];
        dlg.close();if(m)onChoose(m.name,'');else if(row)onChoose(row.make.name,row.model);};
    }
    async function init(){
      try{await load();if(!dlg.open)return;country.innerHTML='<option value="">Все страны</option>'+options([...new Set(makes.map(m=>m.country))].sort(sort));choices();render();
        country.onchange=()=>{choices();render();};brand.onchange=query.oninput=render;
      }catch{list.innerHTML='<p>Не удалось загрузить каталог.</p><button type="button">Повторить</button>';list.querySelector('button').onclick=init;}
    }
    init();
  }
  document.addEventListener('click',e=>{const btn=e.target.closest('[data-vehicle-field]');if(!btn)return;const input=document.getElementById(btn.dataset.vehicleField);if(input)open(btn,(make,model)=>pick(input,make,model),false);});
  class DealerCatalog extends HTMLElement{
    connectedCallback(){
      this.innerHTML='<details class="surface detail-body"><summary>Каталог автомобилей салона</summary><p>Добавьте модель, которой нет в общем справочнике. Она появится в заявках и специализациях поставщиков.</p><form class="fields"><label class="field">Страна производителя<input name="country" required maxlength="100" list="catalog-countries"></label><label class="field">Марка<input name="make" required maxlength="80" list="catalog-makes"></label><label class="field">Модель<input name="model" required maxlength="140"></label><datalist id="catalog-countries"></datalist><datalist id="catalog-makes"></datalist><button class="btn" type="submit">Добавить модель</button></form><p role="status"></p><div data-added></div></details>';
      const form=this.querySelector('form'), status=this.querySelector('[role=status]'), list=this.querySelector('[data-added]');
      let busy=false;
      const show=async()=>{
        await load();
        const extra=await extras();
        if(!this.isConnected)return;
        list.innerHTML=extra.map(m=>'<div class="route-row"><span>'+esc(m.make+' '+m.model)+' · '+esc(m.country)+'</span><button type="button" class="btn small" data-remove="'+esc(m.id)+'" aria-label="Убрать '+esc(m.make+' '+m.model)+'">Убрать</button></div>').join('');
        for(const [id,values] of [['catalog-countries',makes.map(m=>m.country)],['catalog-makes',makes.map(m=>m.name)]]){
          this.querySelector('#'+id).innerHTML=[...new Set(values)].sort(sort).map(v=>'<option value="'+esc(v)+'"></option>').join('');
        }
      };
      this.querySelector('details').ontoggle=e=>{if(e.target.open)show().catch(()=>status.textContent='Не удалось загрузить дополнения салона.');};
      const save=async(action,data)=>{
        if(busy)return;busy=true;const button=form.querySelector('button');button.disabled=true;
        try{await tenantApi('workflow.catalog.'+action,data);++generation;extraRequest=null;loading=null;await show();form.reset();status.textContent=action==='add'?'Модель добавлена в каталог салона':'Модель убрана из каталога салона';}
        catch{status.textContent='Не удалось сохранить каталог. Повторите ещё раз.';}
        finally{busy=false;button.disabled=false;}
      };
      form.onsubmit=async e=>{e.preventDefault();const data=Object.fromEntries(new FormData(form));for(const key of Object.keys(data))data[key]=String(data[key]).trim();if(Object.values(data).some(v=>!v)){status.textContent='Заполните страну, марку и модель';return;}try{await load();}catch{status.textContent='Не удалось загрузить каталог';return;}
        const existing=makes.find(m=>[m.name,m.alias].some(v=>v&&clean(v)===clean(data.make)));
        if(existing){if(existing.models.some(([n,a])=>[n,a].some(v=>v&&clean(v)===clean(data.model)))){status.textContent='Эта модель уже есть в каталоге';return;}data.make=existing.name;data.country=existing.country;}
        await save('add',data);};
      list.onclick=e=>{const btn=e.target.closest('[data-remove]');if(btn&&confirm('Убрать модель из справочника салона? Существующие заявки сохранятся.'))save('remove',{id:btn.dataset.remove});};
    }
  }
  customElements.define('dealer-vehicle-catalog',DealerCatalog);
  function canonicalMake(value){
    const normalized=clean(value);
    return makes?.find(m=>clean(m.name)===normalized)?.name||makes?.find(m=>m.alias&&clean(m.alias)===normalized)?.name||value.trim();
  }
  window.VehicleCatalog={open,connect,load,canonicalMake};
})();
