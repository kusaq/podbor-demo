'use strict';
window.PodborLotTools=(()=>{
 const spec={
 "price_from": [
  "Цена от, ₽",
  0,
  100000000000
 ],
 "price_to": [
  "Цена до, ₽",
  0,
  100000000000
 ],
 "year_from": [
  "Год от",
  1900,
  2100
 ],
 "year_to": [
  "Год до",
  1900,
  2100
 ],
 "mileage_from": [
  "Пробег от, км",
  0,
  20000000
 ],
 "mileage_to": [
  "Пробег до, км",
  0,
  20000000
 ],
 "color": ["Цвет",["Белый","Чёрный","Серый","Серебристый","Синий","Красный","Зелёный","Коричневый","Бежевый","Другой"]],
 "body": [
  "Кузов",
  [
   "Седан",
   "Хэтчбек",
   "Универсал",
   "Лифтбек",
   "Внедорожник",
   "Кроссовер",
   "Купе",
   "Кабриолет",
   "Минивэн",
   "Пикап",
   "Фургон"
  ]
 ],
 "gearbox": [
  "Коробка",
  [
   "Автомат",
   "Механика",
   "Робот",
   "Вариатор"
  ]
 ],
 "fuel": [
  "Топливо",
  [
   "Бензин",
   "Дизель",
   "Гибрид",
   "Электро",
   "Газ"
  ]
 ],
 "drive": [
  "Привод",
  [
   "Передний",
   "Задний",
   "Полный"
  ]
 ]
};
 const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 function inputs(values={}){
  return Object.entries(spec).map(([k,[label,setting,max]])=>'<label class="field">'+label+(Array.isArray(setting)?
   '<select data-lot-filter="'+k+'"><option value="">Любой</option>'+setting.map(v=>'<option '+(v===values[k]?'selected':'')+'>'+v+'</option>').join('')+'</select>':
   '<input type="number" step="1" min="'+setting+'" max="'+max+'" data-lot-filter="'+k+'" value="'+esc(values[k]??'')+'">')+'</label>').join('');
 }
 function values(root){
  const out={};
  for(const el of root.querySelectorAll('[data-lot-filter]')){
   if(!el.value)continue;const k=el.dataset.lotFilter;
   out[k]=el.type==='number'?Number(el.value):el.value;
  }
  return out;
 }
 function ranges(f){return ['price','year','mileage'].every(k=>f[k+'_from']==null||f[k+'_to']==null||f[k+'_from']<=f[k+'_to']);}
 async function route(api,q,creating){
  const answer=await api('workflow.recipients',{brand:q.brand,model:q.model,...(q.request_id?{request_id:q.request_id}:{})});
  const list=answer.recipients||[],dlg=document.createElement('dialog');dlg.className='route-dialog';
  dlg.innerHTML='<form><h2>Получатели запроса</h2><p>Марка · '+esc(answer.brand||'не указана')+'</p>'+
   (list.length?'<fieldset class="route-people"><legend>Кому отправить</legend>'+list.map(r=>'<label><input name="recipient" type="checkbox" checked value="'+esc(r.key)+'"> '+esc(r.name)+'</label>').join('')+'</fieldset>':'<p>Для этой марки новых получателей нет. Проверьте марки и доступ в разделе «Поставщики».</p>')+
   '<details><summary>Фильтры подбора</summary><div class="lot-filter-fields">'+inputs(q.filters)+'</div></details><div role="alert"></div><footer><button class="btn" type="button" data-cancel>Отмена</button><button class="btn primary" type="submit"></button></footer></form>';
  document.body.append(dlg);const form=dlg.querySelector('form');
  const label=()=>{const n=form.querySelectorAll('[name=recipient]:checked').length;form.querySelector('[type=submit]').textContent=(creating?'Создать заявку':'Сохранить параметры')+(n?' и отправить · '+n:' без рассылки');};label();form.onchange=label;
  return new Promise(resolve=>{
   let data=null;dlg.addEventListener('close',()=>{dlg.remove();resolve(data);},{once:true});
   dlg.querySelector('[data-cancel]').onclick=()=>dlg.close();
   form.onsubmit=e=>{e.preventDefault();const filters=values(form);
    if(!ranges(filters)){dlg.querySelector('[role=alert]').textContent='Нижняя граница должна быть меньше или равна верхней.';return;}
    data={filters,recipients:[...form.querySelectorAll('[name=recipient]:checked')].map(e=>e.value)};dlg.close();};
   dlg.showModal();
  });
 }
 function matches(c,filters){
  for(const [k,v] of Object.entries(filters)){
   if(v==null||v==='')continue;
   const [key,limit]=k.split('_'),actual=key==='price'?c.price:c.vehicle?.[key];
   if(actual==null||actual==='')return false;
   if(limit==='from'?Number(actual)<v:limit==='to'?Number(actual)>v:String(actual).trim().toLowerCase()!==String(v).toLowerCase())return false;
  }
  return true;
 }
 async function imageFile(file){
  if(file.size>35*1024*1024)throw Error('Файл больше 35 МБ');
  const url=URL.createObjectURL(file),img=new Image();
  try{
   img.src=url;await img.decode();
   for(const max of [1440,1080,800,600]){
    const scale=Math.min(1,max/Math.max(img.naturalWidth,img.naturalHeight));const canvas=document.createElement('canvas');
    canvas.width=Math.max(1,Math.round(img.naturalWidth*scale));canvas.height=Math.max(1,Math.round(img.naturalHeight*scale));
    const g=canvas.getContext('2d');g.fillStyle='white';g.fillRect(0,0,canvas.width,canvas.height);g.drawImage(img,0,0,canvas.width,canvas.height);
    for(const quality of [.84,.68,.5]){
     const src=canvas.toDataURL('image/jpeg',quality);if(src.length<=350020)return {id:crypto.randomUUID(),src,name:file.name};
    }
   }
   throw Error('Выберите фото меньшего размера');
  }finally{URL.revokeObjectURL(url);}
 }
 return {spec,inputs,values,ranges,route,matches,imageFile};
})();
