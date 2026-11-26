'use strict';
window.requestProgress = function(delivery,options,offers,status){
  const threads=delivery.threads||[], labels={pending:'В очереди',sending:'Отправляем',sent:'Отправлено в Telegram',failed:'Ошибка отправки',uncertain:'Отправка не подтверждена'};
  const rows=threads.map(t=>({...t,label:t.replied?'Поставщик ответил':labels[t.state]||'Отправка не подтверждена'}));
  const replies=rows.filter(t=>t.replied).length;
  let title,action,section;
  if(!rows.length){title='Запрос не отправлен';action=delivery.eligible?'Выбрать получателей':'Добавить вариант вручную';section=delivery.eligible?'dispatch':'manual';}
  else if(rows.some(t=>(!t.state||['failed','uncertain'].includes(t.state))&&!t.replied)){title='Проверьте отправку';action='Открыть переписку';section='thread';}
  else if(replies){title='Ответили '+replies+' из '+rows.length;action='Посмотреть ответы';section='thread';}
  else if(rows.every(t=>t.state==='sent')){title=rows.length===1?'Отправлено поставщику':'Отправлено поставщикам · '+rows.length;action='Открыть переписку';section='thread';}
  else{title='Рассылка поставщикам';action='Проверить отправку';section='thread';}
  if(status==='won'){action='Открыть заказ';section='order';}
  else if(status==='lost'){action='Посмотреть подбор';section='options';}
  else if(offers.length){action='Открыть КП';section='offers';}
  else if(options.length){action='Сравнить варианты и собрать КП';section='options';}
  return {title,action,section,rows};
};
