<#
  Локальный сервер тату-студии «Чёрная Игла» + пересылка заявок в Telegram.

  Что делает:
    GET  /              — отдаёт index.html
    POST /api/booking   — принимает заявку из формы и отправляет её вам в Telegram

  Настройка (один раз):
    1. В Telegram найдите @BotFather → /newbot → получите токен вида 123456:ABC-...
    2. Откройте своего нового бота и нажмите «Start» (или напишите ему любое сообщение).
    3. Скопируйте secrets.example.bat в secrets.bat, впишите токен и запустите start.bat —
       скрипт покажет ваш chat_id.
    4. Впишите chat_id в secrets.bat и запустите start.bat снова. Сайт: http://localhost:8080/

  Токен и chat_id можно передать параметрами или переменными окружения
  TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID. Не храните токен в index.html!
#>
param(
  [string]$Token  = $env:TELEGRAM_BOT_TOKEN,
  [string]$ChatId = $env:TELEGRAM_CHAT_ID,
  [int]$Port      = 8080
)

$ErrorActionPreference = 'Stop'
# Telegram API работает только по TLS 1.2+, а PowerShell 5.1 по умолчанию может использовать старый протокол
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Utf8 = New-Object System.Text.UTF8Encoding($false)
$Root = $PSScriptRoot

# Максимальная длина каждого поля заявки (всё длиннее обрезается)
$FieldLimits = [ordered]@{
  bookingId = 20; name = 40; phone = 30; email = 80; master = 60
  service = 80; date = 40; time = 10; price = 20; comment = 500
}
$RequiredFields = @('name', 'phone', 'master', 'service', 'date', 'time')


# ---------------------------------------------------------------- проверка настроек

if (-not $Token -or $Token -like 'PASTE*') {
  Write-Host 'Не указан токен бота. Впишите его в secrets.bat (TELEGRAM_BOT_TOKEN).' -ForegroundColor Red
  exit 1
}
$Api = "https://api.telegram.org/bot$Token"

# Без chat_id — показываем, кто писал боту, чтобы узнать свой id
if (-not $ChatId -or $ChatId -like 'PASTE*') {
  Write-Host 'chat_id не указан. Ищу последние сообщения боту...' -ForegroundColor Yellow
  try {
    $updates = Invoke-RestMethod "$Api/getUpdates"
  } catch {
    Write-Host "Telegram отклонил запрос — проверьте токен. ($($_.Exception.Message))" -ForegroundColor Red
    exit 1
  }
  $chats = @($updates.result | ForEach-Object { $_.message.chat } | Where-Object { $_ } | Sort-Object id -Unique)
  if ($chats.Count -eq 0) {
    Write-Host 'Сообщений нет. Откройте бота в Telegram, нажмите Start и запустите снова.'
  } else {
    foreach ($c in $chats) {
      Write-Host ("chat_id: {0}   ({1} {2} @{3})" -f $c.id, $c.first_name, $c.title, $c.username) -ForegroundColor Green
    }
    Write-Host 'Впишите нужный chat_id в secrets.bat (TELEGRAM_CHAT_ID) и запустите снова.'
  }
  exit 0
}


# ---------------------------------------------------------------- вспомогательные функции

function ConvertTo-TgHtml([string]$s) {
  # Экранирование для parse_mode=HTML в Telegram
  if ($null -eq $s) { return '' }
  return $s.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
}

function Send-Telegram([string]$text) {
  $body = @{ chat_id = $ChatId; text = $text; parse_mode = 'HTML'; disable_web_page_preview = $true } | ConvertTo-Json
  # Тело передаём байтами UTF-8, иначе PowerShell 5.1 испортит кириллицу
  Invoke-RestMethod -Method Post -Uri "$Api/sendMessage" `
    -ContentType 'application/json; charset=utf-8' -Body $Utf8.GetBytes($body) | Out-Null
}

function Send-Bytes($ctx, [int]$status, [string]$contentType, [byte[]]$bytes) {
  $res = $ctx.Response
  $res.StatusCode = $status
  $res.ContentType = $contentType
  $res.ContentLength64 = $bytes.Length
  $res.OutputStream.Write($bytes, 0, $bytes.Length)
  $res.Close()
}

function Send-Json($ctx, [int]$status, $obj) {
  Send-Bytes $ctx $status 'application/json; charset=utf-8' $Utf8.GetBytes(($obj | ConvertTo-Json -Compress))
}

# Собирает текст сообщения для Telegram из проверенных полей
function Format-BookingMessage($f) {
  $e = @{}
  foreach ($k in $f.Keys) { $e[$k] = ConvertTo-TgHtml $f[$k] }

  $lines = @(
    '🖋 <b>Новая запись — Чёрная Игла</b>'
    "Номер: <code>$($e.bookingId)</code>"
    ''
    "👤 <b>$($e.name)</b>"
    "📞 $($e.phone)"
  )
  if ($f.email)   { $lines += "✉️ $($e.email)" }
  $lines += @(
    ''
    "🎨 Мастер: $($e.master)"
    "💉 Услуга: $($e.service)"
    "📅 Когда: $($e.date), $($e.time)"
    "💰 Стоимость: $($e.price)"
  )
  if ($f.comment) { $lines += @('', "💬 <i>$($e.comment)</i>") }
  return $lines -join "`n"
}


# ---------------------------------------------------------------- обработка заявки

function Invoke-Booking($ctx) {
  $req = $ctx.Request
  if ($req.ContentLength64 -gt 16KB) { Send-Json $ctx 413 @{ ok = $false; error = 'Слишком большой запрос' }; return }

  $reader = New-Object IO.StreamReader($req.InputStream, $Utf8)
  $raw = $reader.ReadToEnd()
  $reader.Close()

  try { $data = $raw | ConvertFrom-Json } catch { Send-Json $ctx 400 @{ ok = $false; error = 'Некорректные данные' }; return }

  # Скрытое поле-ловушка: люди его не видят, спам-боты заполняют. Делаем вид, что всё ок.
  if ($data.website) { Send-Json $ctx 200 @{ ok = $true }; return }

  # Обрезаем поля до допустимой длины
  $f = @{}
  foreach ($key in $FieldLimits.Keys) {
    $v = ([string]$data.$key).Trim()
    if ($v.Length -gt $FieldLimits[$key]) { $v = $v.Substring(0, $FieldLimits[$key]) }
    $f[$key] = $v
  }

  # Повторная проверка на сервере — браузерной валидации доверять нельзя
  $missing = @($RequiredFields | Where-Object { -not $f[$_] })
  if ($missing.Count) { Send-Json $ctx 422 @{ ok = $false; error = 'Заполните все обязательные поля' }; return }
  $digits = ($f.phone -replace '\D', '').Length
  if ($digits -lt 10 -or $digits -gt 12) { Send-Json $ctx 422 @{ ok = $false; error = 'Некорректный телефон' }; return }

  try {
    Send-Telegram (Format-BookingMessage $f)
  } catch {
    Write-Warning "Telegram: $($_.Exception.Message)"
    Send-Json $ctx 502 @{ ok = $false; error = 'Сервис временно недоступен' }
    return
  }

  Write-Host ("[{0:HH:mm:ss}] Заявка {1} от {2} отправлена в Telegram" -f (Get-Date), $f.bookingId, $f.name) -ForegroundColor Green
  Send-Json $ctx 200 @{ ok = $true }
}


# ---------------------------------------------------------------- HTTP-сервер

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Start()
Write-Host "Сайт запущен: http://localhost:$Port/   (Ctrl+C — остановить)" -ForegroundColor Cyan

try {
  while ($listener.IsListening) {
    # Ждём запрос короткими интервалами, чтобы Ctrl+C срабатывал сразу
    $task = $listener.GetContextAsync()
    while (-not $task.AsyncWaitHandle.WaitOne(500)) { }
    $ctx = $task.GetAwaiter().GetResult()

    try {
      $method = $ctx.Request.HttpMethod
      $path = $ctx.Request.Url.AbsolutePath

      if ($method -eq 'POST' -and $path -eq '/api/booking') {
        Invoke-Booking $ctx
      } elseif ($method -eq 'GET' -and ($path -eq '/' -or $path -eq '/index.html')) {
        Send-Bytes $ctx 200 'text/html; charset=utf-8' ([IO.File]::ReadAllBytes((Join-Path $Root 'index.html')))
      } else {
        Send-Json $ctx 404 @{ ok = $false; error = 'Not found' }
      }
    } catch {
      Write-Warning $_.Exception.Message
      try { Send-Json $ctx 500 @{ ok = $false; error = 'Ошибка сервера' } } catch { }
    }
  }
} finally {
  $listener.Stop()
}
