/* PDF generation with locally bundled dependencies and an OFL Cyrillic font. */
(function () {
'use strict';
function clean(text) { return String(text || '').replace(/[\u0000-\u001f\u007f]/g, ' ').replace(/\s+/g, ' ').trim(); }
function dataBytes(data) { return Uint8Array.from(atob(data.split(',')[1]), function (c) { return c.charCodeAt(0); }); }
async function createOffer(model) {
  if (!window.PDFLib || !window.fontkit) throw new Error('Библиотеки PDF ещё не загрузились');
  var lib = window.PDFLib, doc = await lib.PDFDocument.create(); doc.registerFontkit(window.fontkit);
  var response = await fetch('assets/NotoSans-Regular.ttf');
  if (!response.ok) throw new Error('Не удалось загрузить шрифт PDF');
  var font = await doc.embedFont(await response.arrayBuffer(), { subset: true });
  var template = model.letterhead, source = null, image = null;
  if (template && template.type === 'application/pdf') source = await lib.PDFDocument.load(dataBytes(template.data));
  else if (template && template.type === 'image/png') image = await doc.embedPng(dataBytes(template.data));
  else if (template && template.type === 'image/jpeg') image = await doc.embedJpg(dataBytes(template.data));
  var page, y, width, height;
  async function newPage() {
    if (source) { var pages = await doc.copyPages(source, [0]); page = doc.addPage(pages[0]); }
    else page = doc.addPage([595.28, 841.89]);
    width = page.getWidth(); height = page.getHeight();
    if (image) page.drawImage(image, { x: 0, y: 0, width: width, height: height });
    y = height - 150;
  }
  await newPage();
  async function line(text, size, gap) {
    var words = clean(text).split(' '), rows = [], row = '';
    words.forEach(function (word) {
      // Break very long words so arbitrary model names cannot run outside the page.
      var pieces = [], rest = word;
      while (rest && font.widthOfTextAtSize(rest, size) > width - 90) { var n = Math.max(1, Math.floor(rest.length / 2)); while (n > 1 && font.widthOfTextAtSize(rest.slice(0, n), size) > width - 90) n--; pieces.push(rest.slice(0, n)); rest = rest.slice(n); }
      pieces.push(rest); pieces.forEach(function (piece) { var next = row ? row + ' ' + piece : piece; if (font.widthOfTextAtSize(next, size) > width - 90 && row) { rows.push(row); row = piece; } else row = next; });
    });
    if (row) rows.push(row);
    for (var textRow of rows) { if (y < 100) await newPage(); page.drawText(textRow, { x: 45, y: y, size: size, font: font, color: lib.rgb(0.1, 0.13, 0.17) }); y -= size * 1.5; }
    y -= gap || 0;
  }
  await line(model.dealer.name || 'Автоподбор', 14, 8);
  await line('Коммерческое предложение', 22, 8);
  await line('Для ' + model.client + ' · ' + new Date(model.createdAt).toLocaleDateString('ru-RU'), 11, 14);
  for (var i = 0; i < model.cars.length; i++) {
    var car = model.cars[i];
    await line((i + 1) + '. ' + car.title, 15, 3);
    await line(car.description, 11, 2);
    await line(car.price.toLocaleString('ru-RU') + ' ₽ · ' + car.term, 13, 14);
  }
  await line('Цена действует до ' + new Date(model.validUntil).toLocaleDateString('ru-RU'), 11, 8);
  if (model.dealer.inn) await line('ИНН ' + model.dealer.inn, 10, 0);
  if (model.dealer.address) await line(model.dealer.address, 10, 0);
  if (model.dealer.phone) await line('Телефон дилера ' + model.dealer.phone, 10, 0);
  await line('Менеджер ' + model.manager, 10, 0);
  doc.setTitle('Коммерческое предложение'); doc.setProducer('Подбор');
  return doc.save();
}
function download(bytes, name) {
  var url = URL.createObjectURL(new Blob([bytes], { type: 'application/pdf' }));
  var link = document.createElement('a'); link.href = url; link.download = name; document.body.appendChild(link); link.click(); link.remove();
  setTimeout(function () { URL.revokeObjectURL(url); }, 60000);
}
window.PodborPdf = { createOffer: createOffer, download: download };
})();
