'use strict';
window.PodborLots=(()=>{
  const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const number=v=>Number(v).toLocaleString('ru-RU');
  const stamp=v=>new Date(v).toLocaleString('ru-RU',{dateStyle:'short',timeStyle:'short'});
  const results={fit:'Подходит',reject:'Не подходит',retry:'Перезвонить'};
  const attrs={generation:'Поколение',year:'Год',mileage:'Пробег, км',color:'Цвет',trim:'Комплектация'};
  function compare(request,spec,tolerance,candidate){
    const norm=x=>String(x??'').trim().toLowerCase().replace(/ё/g,'е');
    const vehicle=candidate.vehicle||{},checks=[];
    const constrained=x=>x!=null&&String(x).trim()!==''&&!/^(любо[йея]|без ограничений|не (указан[оаы]?|важно))$/i.test(norm(x));
    function record(label,wanted,actual,match){
      if(!constrained(wanted))return;
      checks.push({label,actual:actual==null||actual===''?'Уточнить':String(actual),wanted:String(wanted),state:actual==null||actual===''?'unknown':match?'ok':'diff'});
    }
    for(const k of ['generation','color','trim']){
      const requested=k==='generation'?request.generation:spec[k];
      record(attrs[k],requested,vehicle[k],norm(requested)===norm(vehicle[k]));
    }
    const years=(request.years||'').match(/(?:19|20)\d{2}/g)?.map(Number);
    if(years){
      const low=Math.min(...years),high=Math.max(...years),year=Number(vehicle.year),slack=Number(tolerance.years)||0;
      const after=/^\s*(от|с)\s/i.test(request.years)&&years.length===1,before=/^\s*до\s/i.test(request.years)&&years.length===1;
      record('Год',request.years,vehicle.year,(before||year>=low-slack)&&(after||year<=high+slack));
    }
    if(request.mileage!=null)record('Пробег, км','до '+number(request.mileage),vehicle.mileage!=null&&vehicle.mileage!==''?number(vehicle.mileage):null,Number(vehicle.mileage)<=Number(request.mileage)+(Number(tolerance.km)||0));
    if(request.budget)record('Цена клиенту','до '+number(request.budget)+' ₽',candidate.client_price?number(candidate.client_price)+' ₽':null,Number(candidate.client_price)<=Number(request.budget)*(1+Number(tolerance.pct||0)/100));
    return checks;
  }
  function comparison(r,inbox,options){
    const candidates=options.filter(o=>!o.archived).map(o=>({title:o.title,source:o.source_name,cost:number(o.total_cost)+' ₽',client_price:o.client_price,vehicle:o.input?.vehicle}));
    for(const l of inbox.listings||[]){if(!options.some(o=>!o.archived&&(o.input?.vehicle?.listing_url||o.source_name)===l.link))candidates.push({title:l.title,source:'Объявление',cost:l.purchase?number(l.purchase)+' '+l.currency:null,vehicle:l.vehicle});}
    for(const s of inbox.sources||[])for(const l of s.results||[]){
      if(s.source==='market'&&(inbox.listings||[]).some(x=>x.link===l.link))continue;
      candidates.push({title:l.title,source:s.source==='stock'?'МойСклад':'Объявление',cost:l.purchase?number(l.purchase)+' '+l.currency:null,vehicle:l.vehicle});}
    for(const t of inbox.threads||[])for(const m of t.messages||[]){
      const f=m.parsed;if(!m.incoming||m.option_id||!f?.purchase)continue;
      candidates.push({title:f.model||r.model,source:t.name,cost:number(f.purchase)+' '+(f.currency||''),vehicle:{...f,year:f.years}});
    }
    if(!candidates.length)return '';
    const tol=inbox.tolerances||{};
    const cards=candidates.map(c=>{
      let source=c.source||'Ручной подбор';if(/^https:\/\//i.test(source)){try{source=new URL(source).hostname.replace(/^www\./,'');}catch{source='Объявление';}}
      const checks=compare(r,inbox.spec||{},tol,c);
      const group=checks.find(x=>x.label==='Поколение'&&x.state==='diff')?'Другое поколение':checks.some(x=>x.state==='diff')?'Есть отклонения':checks.some(x=>x.state==='unknown')?'Нужно уточнить':'По заданным параметрам подходит';
      return '<article class="lot-compare"><strong>'+esc(c.title)+'</strong><small>'+esc(source)+'</small><p>'+esc(group)+'</p><dl><div><dt>Расчёт источника / себестоимость</dt><dd>'+esc(c.cost||'Уточнить')+'</dd></div>'+checks.map(x=>'<div><dt>'+esc(x.label)+'</dt><dd>'+esc(x.actual)+(x.state==='diff'?' · в заявке '+esc(x.wanted):'')+'</dd></div>').join('')+'</dl></article>';
    });
    return '<details class="domain-box" id="lot-comparison"><summary>Сравнение лотов · '+cards.length+'</summary><p class="footnote">Допуски салона: год ±'+esc(tol.years||0)+', пробег +'+esc(tol.km||0)+' км, бюджет +'+esc(tol.pct||0)+'%.</p><div class="lot-grid">'+cards.join('')+'</div></details>';
  }
  function callQueue(list,writable=true){
    if(!list?.length)return '';
    const items=list.map((l,i)=>{
      const last=l.calls?.[0], price=last?.actual_price??l.purchase;
      const contact=/^\+?\d{10,15}$/.test(l.phone||'')?'<a class="btn small" href="tel:+'+esc(l.phone.replace(/^\+/,''))+'">Позвонить</a>':'';
      const link=/^https:\/\//i.test(l.link)?'<a class="btn small" target="_blank" rel="noreferrer" href="'+esc(l.link)+'">Открыть объявление</a>':'';
      return '<article class="domain-box card"><b>'+esc(l.title)+'</b><p>'+esc(price?number(price)+' '+l.currency:'Цена по запросу')+' · '+esc(last?results[last.result]:'Ожидает звонка')+'</p><div class="row wrap">'+contact+link+'</div>'+
        (l.calls?.length?'<details><summary>История звонков · '+l.calls.length+'</summary>'+l.calls.map(c=>'<p><b>'+esc(results[c.result])+'</b> · '+esc(stamp(c.created_at))+' · '+esc(c.actor)+(c.actual_price?' · '+esc(number(c.actual_price)+' '+l.currency):'')+(c.note?'<br>'+esc(c.note):'')+(c.next_call?'<br>Перезвонить '+esc(stamp(c.next_call)):'')+'</p>').join('')+'</details>':'')+
        (writable?'<details><summary>Записать звонок</summary><form data-lot-call="'+i+'"><fieldset class="fields"><label class="field">Результат<select required name="result"><option value="">Выберите итог</option>'+Object.entries(results).map(([v,n])=>'<option value="'+v+'">'+n+'</option>').join('')+'</select></label><label class="field">Цена со слов продавца, '+esc(l.currency)+'<input type="number" step="0.01" min="0.01" max="100000000000" name="actual_price"></label><label class="field">Комментарий<input maxlength="1600" name="note"></label><label class="field">Следующий звонок<input type="datetime-local" name="next_call"></label></fieldset><button type="submit" class="btn small">Сохранить звонок</button></form></details>':'')+'</article>';
    });
    return '<section class="lot-calls"><h3>Обзвон объявлений</h3>'+items.join('')+'</section>';
  }
  async function saveCall(form,list,id,api){
    const l=list[Number(form.dataset.lotCall)];if(!l)throw Error('crm_conflict');
    const d=new FormData(form),next=d.get('next_call');
    if(d.get('result')==='retry'&&!next){const el=form.elements.next_call;el.setCustomValidity('Укажите время следующего звонка');el.reportValidity();el.oninput=()=>el.setCustomValidity('');form.elements.result.onchange=()=>el.setCustomValidity('');return false;}
    const p={request_id:id,url:l.link,previous:l.calls?.[0]?.id||null,result:d.get('result'),note:d.get('note').trim(),actual_price:d.get('actual_price')||null,next_call:next?new Date(next).toISOString():null};
    const key=JSON.stringify(p);if(form.dataset.payload!==key){form.dataset.payload=key;form.dataset.token=crypto.randomUUID();}
    await api('workflow.listing.call',{...p,token:form.dataset.token});return true;
  }
  return {attrs,comparison,callQueue,saveCall};
})();
