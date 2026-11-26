"""Refresh the bundled public carsBase make/model index from a downloaded cars.json."""
import json
import sys
from collections import defaultdict
from pathlib import Path

source = json.loads(Path(sys.argv[1]).read_text())
rows = []
for make in source:
    models = [[m['name'], m.get('cyrillic_name') or ''] for m in make['models']]
    rows.append([make['country'], make['name'], make.get('cyrillic_name') or '', models])
if not rows or any(not country or not name or not models for country, name, _, models in rows):
    raise ValueError('Incomplete vehicle catalog')
target = Path(__file__).resolve().parents[1] / 'assets' / 'vehicle-catalog.json'
target.write_text('[\n' + ',\n'.join(json.dumps(row, ensure_ascii=False, separators=(',', ':')) for row in rows) + '\n]\n')

# The bot also receives plain Russian text. Generate its lookup from the same snapshot.

aliases = defaultdict(set)
canonical = {}
def key(value):
    return ' '.join(value.lower().replace('ё', 'е').split())

def remember(scope, name, other):
    normalized = key(name)
    canonical[scope, normalized] = normalized
    for alias in (name, other):
        if alias:
            aliases[scope, key(alias)].add(normalized)

for _, make, alias, models in rows:
    remember('', make, alias)
    for model, model_alias in models:
        remember(key(make), model, model_alias)

def literal(value):
    return "'" + value.replace("'", "''") + "'"

values = []
for (scope, alias), names in sorted(aliases.items()):
    name = canonical.get((scope, alias))
    if not name and len(names) != 1:
        continue
    values.append('(' + ','.join(map(literal, (scope, alias, name or next(iter(names))))) + ')')
sql = ['-- Generated from assets/vehicle-catalog.json. Apply after workflow.sql.', 'begin;']
for start in range(0, len(values), 500):
    sql.append('insert into public.vehicle_catalog_aliases(scope, alias, name) values\n' +
               ',\n'.join(values[start:start + 500]) +
               '\non conflict(scope, alias) do update set name=excluded.name;')
sql.append('commit;')
(target.parents[1] / 'supabase' / 'vehicle-aliases.sql').write_text('\n'.join(sql) + '\n')
