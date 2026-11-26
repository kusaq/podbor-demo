'use strict';
// A single request workspace within the Mini App. Identity always comes from its Telegram launch.
window.createMiniWork=function(ctx){
 let record=null,ticket=0,loading=false,error='';
 const refresh=async(preferredThread)=>{
  if(!record)return;
  const id=record.id,version=ticket;
  const detail=await ctx.api('crm.detail',{id});
  if(version!==ticket)return;
  record=detail.request;ctx.merge(record);
  await Promise.all([flow.load(id,preferredThread),domain.load(id)]);
 };
 const flow=window.PodborWorkflow({...ctx,request:()=>record,domain:()=>domain,isBusy:()=>false,formatError:ctx.errorText,refreshCard:refresh});
 const domain=window.PodborDomain.create({...ctx,flowHtml:flow.inboxHtml,extended:flow.extended,savePhotos:flow.savePhotos,photoPicker:flow.photoPicker,
  existingPhotos:flow.existingPhotos,isBusy:flow.busy,beforeMutation:()=>true,refreshRequest:refresh,afterSent:async()=>{
   await refresh();ctx.sent();
  }});
 return {
  async open(id,preferredThread){
   const version=++ticket;
   flow.reset();domain.reset();record={id};loading=true;error='';ctx.render();
   try{await refresh(preferredThread);}catch(e){if(version===ticket)error=ctx.errorText(e);}
   finally{if(version===ticket){loading=false;ctx.render();}}
  },
  focusSection(section){
   if(section==='manual'){
    const add=ctx.root.querySelector('[data-domain="new"]');if(add){add.click();ctx.root.querySelector('#domainOptionForm')?.scrollIntoView({block:'start'});return;}
   }
   const find={dispatch:'#wf-dispatch',thread:'.wf-inbox',manual:'[data-domain="new"]',options:'.domain-options',order:'.order-card',offers:'[data-domain="download"],[data-domain="offer"]',feedback:'#wf-feedback',calls:'.lot-calls',price:'[data-domain="review"]'};
   const el=find[section]&&ctx.root.querySelector(find[section]);
   if(el){const details=el.closest('details');if(details)details.open=true;el.scrollIntoView({block:'start'});}
  },
  leave(){
   if(flow.busy()||domain.isBusy()){ctx.flash('Дождитесь сохранения');return false;}
   if((flow.dirty()||domain.hasDirty())&&!window.confirm('Выйти из подбора без сохранения изменений?'))return false;
   ++ticket;record=null;flow.reset();domain.reset();return true;
  },
  html(){
   if(loading||!record)return '<div class="scroll"><p class="card" role="status">Загружаем подбор…</p></div>';
   if(error)return '<div class="scroll"><p class="card" role="alert">'+ctx.esc(error)+'</p><button class="btn" data-a="retryWork">Повторить загрузку</button></div>';
   return '<div class="scroll mini-work">'+domain.requestHtml()+'</div>';
  }
 };
};
