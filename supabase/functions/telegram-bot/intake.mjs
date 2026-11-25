const filterSpec={
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
 "color": ["Фильтр цвета",["Белый","Чёрный","Серый","Серебристый","Синий","Красный","Зелёный","Коричневый","Бежевый","Другой"]],
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
const labels = {
  client_name:'Имя', phone:'Телефон', model:'Модель', brand:'Марка', budget:'Бюджет',
  generation:'Поколение', years:'Годы', mileage:'Пробег', color:'Цвет', trim:'Комплектация', city:'Город'
};
const names = Object.fromEntries(Object.entries(labels).map(([k,v])=>[v.toLowerCase(),k]));
Object.assign(names,{клиент:'client_name',год:'years','марка и модель':'model'});
const cars = [
  ['Toyota','Camry','тойота','камри'],['Toyota','RAV4','тойота','рав4'],['Toyota','Corolla','тойота','королла'],
  ['Kia','Sportage','киа','спортейдж'],['Hyundai','Tucson','хендай','туссан'],['Honda','Fit','хонда','фит'],
  ['Mazda','CX-5','мазда','сх-5'],['BMW','X5','бмв','х5'],['Volkswagen','Tiguan','фольксваген','тигуан']
];
function amount(s){
  const m=s.trim().match(/^(?:до\s*)?(\d[\d \u00a0]*(?:[.,]\d+)?)\s*(млн|миллион[а-я]*|тыс[а-я.]*)?(?:\s*(?:₽|руб[а-я.]*|RUB))?$/iu);
  if(!m)return null;
  const n=Number(m[1].replace(/\s/g,'').replace(',','.'))*(m[2]?m[2].startsWith('м')?1e6:1000:1);
  return n>0&&n<=1e11?n:null;
}
export function intakeFields(text,origin){
  const f={},value=String(text||'').trim();
  const phone=value.match(/(?:\+7|8)(?:[ ()-]*\d){10}(?!\d)/);
  if(phone)f.phone='7'+phone[0].replace(/\D/g,'').slice(-10);
  if(origin?.type==='user'){const u=origin.sender_user||{};if(u.first_name)f.client_name=[u.first_name,u.last_name].filter(Boolean).join(' ').slice(0,160);}
  const lower=value.toLowerCase(),matches=cars.filter(([,model,,alias])=>[model.toLowerCase(),alias].some(x=>new RegExp('(?:^|[^\\p{L}\\p{N}])'+x+'(?=$|[^\\p{L}\\p{N}])','u').test(lower)));
  if(matches.length===1){const [b,m]=matches[0];f.brand=b;f.model=b+' '+m;}
  if(!f.model&&matches.length===0){
    const knownBrands=['Toyota','Lexus','Honda','Nissan','Mazda','Subaru','Mitsubishi','Suzuki','BMW','Audi','Volkswagen','Skoda','Mercedes-Benz','Porsche','Volvo','Ford','Kia','Hyundai','Chery','Geely','Haval','BYD','Li Auto','Tesla','Zeekr'];
    const brandNames=knownBrands.join('|');
    const carsFound=[...value.matchAll(new RegExp('(?:^|[^\\p{L}\\p{N}])('+brandNames+')\\s+([A-Za-z0-9][A-Za-z0-9.-]{0,20})(?=$|[^\\p{L}\\p{N}])','giu'))];
    if(carsFound.length===1){const [,b,m]=carsFound[0];if(!/^(?:19|20)\d{2}$/.test(m)){f.brand=knownBrands.find(v=>v.toLowerCase()===b.toLowerCase());f.model=f.brand+' '+m.replace(/[.]$/,'');}}
  }
  const self=value.match(/(?:[Мм]еня зовут|[Мм]о[её] имя)\s+([А-ЯЁ][а-яё-]{1,39})(?:\s+([А-ЯЁ][а-яё-]{1,39}))?/u);
  if(self&&!f.client_name)f.client_name=self.slice(1).filter(Boolean).join(' ');
  const city=value.match(/(?:доставк[ауи]|доставкой)\s+(?:до|в)\s+([А-ЯЁ][а-яё-]{1,50})(?=[\s.,;!?]|$)/u);if(city)f.city=city[1];
  const money=value.match(/(?:бюджет(?:ом)?\s*(?:до)?\s*|до\s+)(\d[\d \u00a0]*(?:[.,]\d+)?\s*(?:млн|миллион[а-я]*|тыс[а-я.]*|₽|руб[а-я.]*))/iu);if(money&&amount(money[1]))f.budget=amount(money[1]);
  const year=value.match(/(?:^|[^\d])((?:19|20)\d{2})(?:\s*[-–]\s*((?:19|20)\d{2}))?(?=\s*(?:г(?:од|\.|\s)|[,.;]|$))/iu);
  if(year){const prefix=value.slice(0,year.index+1).trimEnd().match(/(?:^|\s)(от|с|до)$/iu);f.years=(prefix&&!year[2]?prefix[1]+' ':'')+[year[1],year[2]].filter(Boolean).join('-');}
  const km=value.match(/пробег[а-я]*\s*(?:до\s*)?(\d[\d ]*)\s*(тыс[а-я.]*)?\s*км/iu);
  if(km){const n=Number(km[1].replace(/\s/g,''))*(km[2]?1000:1);if(n<=20000000)f.mileage=n;}
  const colors=[['бел','Белый'],['черн','Чёрный'],['чёрн','Чёрный'],['серебрист','Серебристый'],['красн','Красный'],['син','Синий']];
  const found=colors.filter(([s])=>new RegExp('(?:^|\\s)'+s+'(?:ую|юю|ый|ий|яя|ая)(?:\\s|[,.;]|$)','iu').test(value));if(found.length===1)f.color=found[0][1];
  for(const line of value.split(/[\n;]/)){
    const m=line.trim().match(/^([^:]{1,24}):\s*(.{1,200})$/u);if(!m)continue;
    const label=m[1].trim().toLowerCase().replace(/,?\s*(₽|км)$/i,'');
    const filter=Object.keys(filterSpec).find(k=>filterSpec[k][0].toLowerCase().replace(/,?\s*(₽|км)$/i,'')===label);
    const v=m[2].trim();
    if(filter){
      f.filters??={};const opts=filterSpec[filter][1];
      f.filters[filter]=/^(любой|любая|любое|убрать|без ограничений)$/iu.test(v)?'':Array.isArray(opts)?(opts.find(x=>x.toLowerCase()===v.toLowerCase())||v):v.replace(/\s/g,'');
      continue;
    }
    const k=names[m[1].trim().toLowerCase()];if(!k)continue;
    if(k==='budget'){const n=amount(v);if(n)f.budget=n;else delete f.budget;}
    else if(k==='phone'){let n=v.replace(/[ ()+-]/g,'');if(n.length===10)n='7'+n;if(/^8\d{10}$/.test(n))n='7'+n.slice(1);if(/^\d{10,15}$/.test(n))f.phone=n;else delete f.phone;}
    else if(k==='mileage'){const n=v.replace(/(?:\s|км)/gi,'');if(/^\d{1,8}$/.test(n)&&Number(n)<=20000000)f.mileage=Number(n);}
    else if(v.length<=({client_name:160,brand:80,color:100,years:80,trim:160}[k]||200))f[k]=v;
  }
  return f;
}
export function intakePreview(f){
  const missing=['client_name','phone','brand','model','budget'].filter(k=>!f[k]);
  const rows=Object.entries(labels).filter(([k])=>f[k]!=null).map(([k,v])=>v+': '+(k==='budget'?Number(f[k]).toLocaleString('ru-RU')+' ₽':f[k]));
  const prompt=missing.length?'Допишите отдельными строками:\n'+missing.map(k=>labels[k]+': …').join('\n'):
    'Проверьте параметры. Поставщикам уйдут марка, модель, поколение, годы, пробег, цвет и комплектация. Нажмите «Создать заявку», если клиент согласен на обработку данных.';
  const invalid=[];
  for(const [k,v] of Object.entries(f.filters||{})){
    if(!v||!filterSpec[k])continue;const [label,opts,max]=filterSpec[k];rows.push(label+': '+v);
    if(Array.isArray(opts)?!opts.includes(v):!/^\d+$/.test(v)||Number(v)<opts||Number(v)>max)invalid.push(label+(Array.isArray(opts)?' ('+opts.join(', ')+')':''));
  }
  for(const key of ['year','mileage','price']){const a=f.filters?.[key+'_from'],b=f.filters?.[key+'_to'];if(a&&b&&Number(a)>Number(b))invalid.push(filterSpec[key+'_from'][0]+' больше верхней границы');}
  if(invalid.length)return {ready:false,text:rows.join('\n')+'\nИсправьте фильтры: '+invalid.join(', ')};
  return {ready:!missing.length,text:['Черновик заявки',...rows,'',prompt,'Изменить любое поле можно сообщением «Поле: значение».'].join('\n')};
}
