// Transport-independent bot logic. Incoming text, supplier content and AI output are untrusted.
export const ACTIONS=['create_request','update_request','add_note','send_supplier_request','reply_supplier','supplier_option','create_offer','mark_offer_sent','unknown'];
const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export function cleanContact(text,known=[]){let s=String(text||'');const removed=[];for(const [name,re] of [['ссылка',/https?:\/\/\S+|www\.\S+/gi],['email',/[\w.+-]+@[\w.-]+\.[a-z]{2,}/gi],['ник',/@[a-z0-9_]+/gi],['телефон',/(?:\+\d[\d ()-]{8,}\d|\b[78](?:[ ()-]*\d){10}\b)/g]])s=s.replace(re,()=>{removed.push(name);return '[удалено: '+name+']'});for(const value of known.filter(x=>x&&x.length>2))s=s.split(value).join('[удалено: данные клиента]');return {text:s,removed:[...new Set(removed)]};}
export function supplierTemplate(r,code){const fields=[['Марка',r.brand],['Модель',r.model],['Поколение',r.generation],['Годы',r.years],['Пробег до, км',r.mileage??'Не указан'],['Цвет',r.color],['Комплектация',r.trim]];return ['Запрос № '+code,...fields.map(([k,v])=>k+': '+(v||'Уточнить')),'Ответьте на это сообщение. Укажите автомобиль, год, пробег, цену закупки, валюту, наличие и срок поставки.'].join('\n');}
export function validateIntent(raw){if(!raw||typeof raw!=='object'||Array.isArray(raw)||!ACTIONS.includes(raw.action))throw Error('bad_intent');const allowed=['action','fields','text','question'];if(Object.keys(raw).some(k=>!allowed.includes(k)))throw Error('bad_intent');const fields=raw.fields||{};if(!fields||typeof fields!=='object'||Array.isArray(fields)||JSON.stringify(fields).length>12000)throw Error('bad_intent');for(const k of Object.keys(fields))if(!['client_name','phone','model','brand','budget','generation','years','mileage','spec','color','trim','status','reasons','main_reason','note','next_contact_at','scenario','currency','purchase','base_rate','logistics','duty','recycling','documents','commission','client_price','market_median','term','selected_numbers'].includes(k))throw Error('bad_intent');return {action:raw.action,fields,text:String(raw.text||'').slice(0,3000),question:String(raw.question||'').slice(0,1000)};}
export function privateUpdate(update){const m=update?.message;const cb=update?.callback_query;if(m)return m.chat?.type==='private'&&!m.from?.is_bot&&String(m.chat.id)===String(m.from?.id);if(cb)return cb.message?.chat?.type==='private'&&String(cb.message.chat.id)===String(cb.from?.id);return false;}
export class BotEngine{
 constructor(ports){this.p=ports;}
 async process(job){const u=job.payload;const actor=await this.p.actor(u.callback_query?.from?.id||u.message?.from?.id);if(!actor?.active)return;
  if(u.callback_query){const data=String(u.callback_query.data||'');if(/^(confirm|cancel):/.test(data)){const [action,id]=data.split(':');if(!UUID.test(id))return;await this.p.decide(actor,id,action==='confirm');return;}if(data.startsWith('review:')){const id=data.slice(7);if(UUID.test(id)&&actor.role!=='supplier')await this.p.reviewSupplier(actor,id);return;}if(data.startsWith('request:')){const id=data.slice(8);if(!UUID.test(id))return;await this.p.selectRequest(actor,id);return;}if(data.startsWith('thread:')){const id=data.slice(7);if(!UUID.test(id))return;await this.p.selectThread(actor,id);return;}return;}
  const m=u.message;if(!m)return;const original=m.text||m.caption||'';if(/^\/(start|help)(?:@\w+)?$/.test(original.trim())){await this.p.help(actor);return;}
  if(/^\/requests(?:@\w+)?$/.test(original.trim())){await this.p.requests(actor);return;}
  if(/^\/threads(?:@\w+)?$/.test(original.trim())){await this.p.threads(actor);return;}
  if(actor.role==='supplier'&&!await this.p.hasThread(actor,m.reply_to_message?.message_id)){await this.p.threads(actor);return;}
  if(actor.role!=='supplier'&&m.reply_to_message)await this.p.hasThread(actor,m.reply_to_message.message_id);
  let text=original;if(m.voice){if(m.voice.duration>120||m.voice.file_size>8*1024*1024){await this.p.notice(actor,'Голосовое должно быть до 2 минут и до 8 МБ.');return;}text=job.transcript||await this.p.transcribe(m.voice);}
  if(!text.trim()){await this.p.notice(actor,'Пришлите текст или голосовое. Фото и документы пока не распознаются автоматически.');return;}
  await this.p.saveTranscript(job.id,actor,text);
  if(actor.role==='supplier'){// Supplier input can never become an instruction to modify the dealer CRM.
   const sanitized=await this.p.redact(text,actor);await this.p.supplierReply(actor,m.reply_to_message?.message_id,sanitized,job.id);return;
  }
  const intent=validateIntent(await this.p.understand(text,actor));
  if(intent.action==='unknown'){await this.p.notice(actor,intent.question||'Уточните действие: создать заявку, обновить, написать поставщику или собрать КП.');return;}
  await this.p.propose(actor,intent,text,job.id);
 }
}
export async function boundedBytes(response,max){if(!response.ok)throw Error('download_failed');if(Number(response.headers.get('content-length'))>max)throw Error('file_too_large');const reader=response.body.getReader(),chunks=[];let total=0;try{while(true){const {value,done}=await reader.read();if(done)break;total+=value.length;if(total>max)throw Error('file_too_large');chunks.push(value);}}finally{await reader.cancel().catch(()=>{});}const result=new Uint8Array(total);let at=0;for(const chunk of chunks){result.set(chunk,at);at+=chunk.length;}return result;}
