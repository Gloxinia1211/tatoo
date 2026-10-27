/**
 * Cloudflare Worker — пересылка заявок в Telegram, когда сайт выложен в интернет
 * (GitHub Pages, Netlify и т.п.), а компьютер с server.ps1 не включён круглосуточно.
 *
 * Развёртывание (бесплатно):
 *   1. dash.cloudflare.com → Workers & Pages → Create → Worker → вставьте этот код → Deploy.
 *   2. Settings → Variables and Secrets → добавьте секреты TELEGRAM_BOT_TOKEN и TELEGRAM_CHAT_ID.
 *      По желанию — переменную ALLOWED_ORIGIN (адрес вашего сайта, например https://my-studio.pages.dev).
 *   3. В index.html замените BOOKING_ENDPOINT на https://<имя-воркера>.<аккаунт>.workers.dev
 */

/* Максимальная длина полей заявки */
const FIELD_LIMITS = {
  bookingId: 20, name: 40, phone: 30, email: 80, master: 60,
  service: 80, date: 40, time: 10, price: 20, comment: 500,
};
const REQUIRED = ['name', 'phone', 'master', 'service', 'date', 'time'];

/** Экранирование для parse_mode=HTML в Telegram */
const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

function formatMessage(f) {
  const e = Object.fromEntries(Object.entries(f).map(([k, v]) => [k, esc(v)]));
  return [
    '🖋 <b>Новая запись — Чёрная Игла</b>',
    `Номер: <code>${e.bookingId}</code>`,
    '',
    `👤 <b>${e.name}</b>`,
    `📞 ${e.phone}`,
    f.email ? `✉️ ${e.email}` : null,
    '',
    `🎨 Мастер: ${e.master}`,
    `💉 Услуга: ${e.service}`,
    `📅 Когда: ${e.date}, ${e.time}`,
    `💰 Стоимость: ${e.price}`,
    f.comment ? `\n💬 <i>${e.comment}</i>` : null,
  ].filter((line) => line !== null).join('\n'); // null — необязательные пустые поля
}

export default {
  async fetch(request, env) {
    const cors = {
      'Access-Control-Allow-Origin': env.ALLOWED_ORIGIN || '*',
      'Access-Control-Allow-Methods': 'POST, OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type',
    };
    const json = (status, obj) =>
      new Response(JSON.stringify(obj), { status, headers: { ...cors, 'Content-Type': 'application/json; charset=utf-8' } });

    // Предварительный CORS-запрос браузера
    if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors });
    if (request.method !== 'POST') return json(405, { ok: false, error: 'Method not allowed' });

    let data;
    try {
      data = await request.json();
    } catch {
      return json(400, { ok: false, error: 'Некорректные данные' });
    }

    // Поле-ловушка для спам-ботов
    if (data.website) return json(200, { ok: true });

    // Обрезаем поля до допустимой длины
    const f = {};
    for (const [key, max] of Object.entries(FIELD_LIMITS)) {
      f[key] = String(data[key] ?? '').trim().slice(0, max);
    }

    // Повторная проверка на сервере
    if (REQUIRED.some((k) => !f[k])) return json(422, { ok: false, error: 'Заполните все обязательные поля' });
    const digits = f.phone.replace(/\D/g, '').length;
    if (digits < 10 || digits > 12) return json(422, { ok: false, error: 'Некорректный телефон' });

    const tg = await fetch(`https://api.telegram.org/bot${env.TELEGRAM_BOT_TOKEN}/sendMessage`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        chat_id: env.TELEGRAM_CHAT_ID,
        text: formatMessage(f),
        parse_mode: 'HTML',
        disable_web_page_preview: true,
      }),
    });
    if (!tg.ok) return json(502, { ok: false, error: 'Сервис временно недоступен' });

    return json(200, { ok: true });
  },
};
