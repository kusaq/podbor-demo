-- Схема демо «Подбор». Выполнить один раз в Supabase: SQL Editor → New query → Run.
-- Повторный запуск безопасен: таблицы создаются только если их нет, моки не задваиваются.

-- Кто может войти в мини-апп и с какой ролью. Ключ это Telegram ID пользователя.
create table if not exists app_users (
  tg_id      bigint primary key,
  name       text not null,
  role       text not null check (role in ('manager', 'owner', 'supplier', 'admin')),
  active     boolean not null default true,
  created_at timestamptz not null default now()
);

-- Моки для экранов. kind говорит, на каком экране запись показывается, data это сама запись.
-- Сейчас фронт читает kind = 'request' (список запросов). Добавлять строки можно прямо в Table Editor.
create table if not exists mocks (
  id         uuid primary key default gen_random_uuid(),
  kind       text not null,
  data       jsonb not null,
  created_at timestamptz not null default now()
);

-- RLS включён, политик нет: из браузера по публичному ключу таблицы не читаются и не пишутся.
-- Всё ходит через функцию api, которая сначала проверяет, что запрос пришёл из Telegram.
alter table app_users enable row level security;
alter table mocks enable row level security;

-- Стартовые запросы, те же, что зашиты в демо. Toyota Camry остаётся в коде, она единственная кликабельная.
insert into mocks (kind, data)
select 'request', d
from (values
  ('{"key":"sorento","title":"Kia Sorento","client":"Ирина К.","mgr":"Олег С.","when":"вчера","status":"search","search":["готово","good"]}'::jsonb),
  ('{"key":"bmw","title":"BMW X5","client":"ООО «Вектор»","mgr":"Марина К.","when":"13 окт","status":"think","search":["отправлено","muted"]}'::jsonb),
  ('{"key":"palisade","title":"Hyundai Palisade","client":"Тимур Б.","mgr":"Артём Л.","when":"12 окт","status":"search","search":["обзвон","info"]}'::jsonb),
  ('{"key":"gle","title":"Mercedes GLE","client":"Павел Р.","mgr":"Олег С.","when":"9 окт","status":"lost","search":["закрыт","muted"]}'::jsonb)
) as seed(d)
where not exists (select 1 from mocks where kind = 'request');

-- Шпаргалка по полям запроса:
--   key     латиницей, уникальный (необязательно)
--   title   машина, client клиент, mgr менеджер, when подпись времени
--   status  search | think | lost | won  (Ищем тачку, Думает, Слился, Заказал)
--   search  ["подпись", "тон"], тон: good | warn | bad | info | muted
