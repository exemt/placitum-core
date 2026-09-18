# API контроллера

[English](API.md) · Русский

Всё в Placitum настраивается через один HTTP API: и панель, и установщик, и ваши скрипты
разговаривают с контроллером. Отдельного чёрного хода у панели нет, так что всё, что делается
мышкой, делается и скриптом.

Здесь справочник: где API слушает, как выглядит запрос, что происходит после записи и что делает
каждая ручка. Про саму установку — [INSTALL.ru.md](INSTALL.ru.md).

## Где слушает

По умолчанию контроллер на `http://127.0.0.1:8080` — только с самой машины. Порт задаётся
в `.env` переменной `PLC_CONTROLLER_PORT`.

С другой машины — через туннель:

```sh
ssh -L 8080:127.0.0.1:8080 user@server
```

## Доступ

Своего входа у API нет. Кто добрался до порта, тот и оператор установки: ролей, токенов и режима
«только чтение» не существует. Держится это на двух вещах, и обе настраивает установщик:

- порт привязан к петле (в Docker — compose-файлом, без Docker — переменной `CONTROLLER_HOST`);
- панель раздаёт узел за проверкой входа (`auth`), и браузер попадает в API через ту же проверку входа.

Не выставляйте порт 8080 наружу. Сессия на этом порту равна root на узле.

От чужих веб-страниц API защищается сам. Запрос, который что-то меняет (всё, кроме `GET`, `HEAD`
и `OPTIONS`), должен прийти с того же источника или с источника из `CONTROLLER_CORS_ORIGIN`, иначе
ответ будет `403 cross_origin`. Запрос без `Origin` и без `Sec-Fetch-Site` — curl, установщик,
скрипт — это инструмент, а не страница, и он проходит.

## Как выглядит запрос

- JSON туда, JSON обратно. С телом отправляйте `Content-Type: application/json`.
- Версии в пути нет. API такой, какой установлен; какой именно — скажет `GET /api/meta`.
- Имена полей в `snake_case`, идентификаторы называются `uuid`, время — ISO 8601 в UTC.
- JSON-тело принимается примерно до 3 МБ (`CONTROLLER_STORE_MAX_BYTES` × 1,4, по умолчанию 2 МиБ).
  У загрузок, которые не JSON — геобаза, страница, сертификат, — свои пределы.
- `PUT` меняет только то, что прислали: пропущенное поле остаётся прежним. А присланное поле
  берётся целиком — `doc` профиля или блок `nginx` заменяет старый, а не подмешивается в него.
- По этому же адресу раздаётся панель. Путь, который не `/api/…` и не `/healthz`, вернёт страницу
  панели, а не 404.

## Пространство

Почти каждый путь начинается с uuid пространства HTTP:

```
/api/<scope>/servers
```

Пространство — это целая конфигурация nginx: серверы, маршруты, наборы, профили и инспекторы.
После установки оно одно и называется `default`. Сначала узнайте его uuid:

```sh
curl -s http://127.0.0.1:8080/api/spaces
```

```json
{
  "spaces": [
    {
      "uuid": "00000000-0000-4000-8000-000000000001",
      "name": "default",
      "raw": false,
      "created_at": "2026-09-12T15:27:32.862Z",
      "updated_at": "2026-09-17T12:34:39.625Z"
    }
  ]
}
```

Дальше в примерах он лежит в переменной:

```sh
SCOPE=$(curl -s http://127.0.0.1:8080/api/spaces | jq -r '.spaces[0].uuid')
API=http://127.0.0.1:8080/api/$SCOPE
```

Если в пути не uuid — `400 invalid_scope`; если uuid чужой — `404 unknown_scope`.

## Ошибки

Ошибка всегда приходит в одном виде:

```json
{ "error": "not_found" }
```

Некоторые добавляют поля с подробностями: `detail`, `names`, `uses`, `invalid`, `known`, `max`,
`errors`.

| Код | Когда |
| --- | --- |
| `400` | запрос неверный: не тот uuid, нет обязательного поля, недопустимое значение |
| `403` | `cross_origin`: запись пришла с чужой страницы |
| `404` | такого объекта нет, или нет такого пространства |
| `409` | на объект ссылаются, или имя занято |
| `413` | тело больше предела |
| `422` | запрос верный, а конфигурация из него — нет; смотрите `errors` |
| `500` | `internal_error`: необработанный сбой, смотрите журнал контроллера |
| `503` | сосед недоступен: шина, поиск, служба ключей |

Коды, которые встречаются везде:

| Код | Что значит |
| --- | --- |
| `invalid_scope`, `unknown_scope` | uuid пространства в пути |
| `invalid_uuid`, `not_found` | uuid объекта в пути |
| `name_taken`, `address_taken`, `path_taken`, `port_taken` | уникальное имя или адрес уже заняты |
| `in_use` | на объект ссылаются; сначала снимите ссылки |
| `default_required`, `default_name_locked` | профиль `default` нельзя удалить или переименовать |
| `builtin_locked`, `builtin_name_locked` | поставляемый объект нельзя менять или переименовывать |
| `validation_failed` | конфигурация не собралась; причины в `errors` |
| `kv_unavailable` | шина недоступна, применять некуда |

## Сохранить и применить

Запись меняет базу контроллера, и только её. Узел и инспекторы продолжают работать по тому, что у
них уже есть. Применение — отдельный явный шаг:

1. **Сохранить** — `POST`, `PUT` или `DELETE` по объектам канала.
2. **Применить** — `POST .../send` по этому каналу. Контроллер собирает то, что есть, публикует новое
   поколение на шину и отвечает его версией и хешем.
3. **Применить** — процессы забирают поколение, применяют и докладывают, на чём работают.
4. **Проверить** — `GET /api/<scope>/convergence` сводит вместе сохранённое, применённое и то, что
   докладывает каждый получатель.

Каналы независимы: правила для инспектора `modsec` уходят своим ходом, конфигурация узла — своим.

| Канал | Что передаёт | Применение | Опубликованное поколение |
| --- | --- | --- | --- |
| `nginx` | серверы, маршруты, порты, сертификаты, настройки пространства | `POST config/send` | `GET config/desired` |
| `agent` | настройки агента узла | `POST agent/send` | `GET agent/desired` |
| `haproxy` | настройки балансировщика | `POST haproxy/send` | `GET haproxy/desired` |
| `rules` | файлы и наборы правил ModSecurity | `POST rules/send` | `GET rules/desired` |
| `ip` | профили и наборы IP | `POST ip-profiles/send` | `GET ip-profiles/desired` |
| `auth`, `captcha`, `json`, `action`, `cookie`, `counter`, `vlai`, `rewrite` | профили этого инспектора | `POST <имя>/send` | `GET <имя>/desired` |

В ответ на применение приходит опубликованное поколение:

```json
{ "v": 1, "rev": 68, "config_hash": "sha256:75c22e…", "store": 0, "pages": ["blocked.html"] }
```

`rev` растёт на единицу с каждым поколением. Если менять было нечего, версия остаётся прежней и
применение ничего не делает.

У сводки применения одна лампа на всё пространство (`green`, `yellow`, `red`) и по записи на канал:
хеш черновика, хеш и версия опубликованного, и каждый получатель с тем, что он докладывает (`ok`, `stale`,
`pending`, `failed`, `foreign`, `silent`).

## Служебное

| Ручка | Что отдаёт |
| --- | --- |
| `GET /healthz` | `ok` текстом, без обращения к базе |
| `GET /api/health` | `{"ok":true,"db":true}` после пинга базы |
| `GET /api/meta` | имя сервиса, версия, хост, pid, время работы |

## Пространства, парк и применение конфигурации

| Ручка | Что делает |
| --- | --- |
| `GET /api/spaces` | все пространства HTTP: uuid, имя, время |
| `GET /api/fleet` | снимок всего живого: агенты узлов и их воркеры, инспекторы, буфери, службы, трафик по маршрутам |
| `POST /api/fleet/forget` | забыть процессы по именам, когда их контейнеров уже нет |
| `GET /api/<scope>/convergence` | что сохранено, что применено, что докладывает каждый получатель |
| `POST /api/<scope>/convergence/refresh` | пересчитать; `?channel=nginx` — один канал |

Получатель парка бывает `up` или `degraded` и исчезает, когда перестаёт докладывать. В каждой записи
есть время последнего доклада, хеш и версия, на которых он работает, результат последнего
применения и его счётчики.

`POST /api/fleet/forget` принимает имена, которые снял установщик, и отвечает тем, что забыл:

```sh
curl -s -X POST http://127.0.0.1:8080/api/fleet/forget \
  -H 'content-type: application/json' \
  -d '{"names":["edge-02"]}'
```

```json
{ "forgotten": 3, "agents": ["9a1c…"], "inspectors": 2, "stores": 0, "services": 0 }
```

Имена — это идентификаторы узлов и имена хостов контейнеров, до 512 за раз; плохой список —
`400 invalid_names`. Живой процесс вернётся в парк со следующим докладом.

### Живая лента

Тот же снимок отдаётся по WebSocket:

```
ws://127.0.0.1:8080/agent_health_socket
```

Первым сообщением приходит полный снимок, дальше по одному на изменение, не чаще раза в секунду.
Лента односторонняя: что бы клиент ни прислал, это игнорируется. Страница в браузере откроет её
только с разрешённого источника — правило то же, что для записи. Пинг раз в 30 секунд отцепляет
тех, кто перестал отвечать.

## Справочники

Списки только на чтение: из них панель строит формы. Полезны скрипту, которому надо называть вещи
так же, как их называет установка.

| Ручка | Что отдаёт |
| --- | --- |
| `GET /api/actions` | словарь действий: оси, глаголы, их параметры и кто из инспекторов слушает |
| `GET /api/<scope>/catalog` | всё одним куском: ответы блокировки, форматы журнала, наборы, инспекторы, subject'ы, профили, страницы, хранилища тел, апстримы |
| `GET /api/<scope>/content-types` | типы содержимого для наборов вида `content` |
| `GET /api/<scope>/crypto` | открытый ключ установки, его алгоритм и отпечаток |
| `GET /api/log-levels` | текущие уровни журналирования и службы, которые их принимают |
| `PUT /api/log-levels` | задать их: `{"levels":{"controller":"debug"}}` |

Уровни журналирования применяются сразу по всей установке, без применения: документ уходит на шину, и
каждый процесс забирает из него свою строку. Имя, которого нет в `services`, отклоняется с
`400 unknown_service`; `null` или пустая строка снимают переопределение, и процесс возвращается
к своей настройке.

## Серверы, маршруты, порты, апстримы

Из этих четырёх складывается конфигурация узла. Все они в канале `nginx`, поэтому на узле правка
окажется только после `POST config/send`.

| Ручка | Что делает |
| --- | --- |
| `GET /api/<scope>/servers` | серверы с их портами и числом маршрутов |
| `POST /api/<scope>/servers` | создать сервер |
| `GET`, `PUT`, `DELETE /api/<scope>/servers/<uuid>` | прочитать, изменить, удалить один |
| `GET /api/<scope>/servers/<uuid>/inheritance` | что сервер наследует от пространства, поле за полем |
| `GET /api/<scope>/servers/<uuid>/locations` | его маршруты по порядку |
| `POST /api/<scope>/servers/<uuid>/locations` | добавить маршрут |
| `PUT /api/<scope>/servers/<uuid>/locations/order` | переставить их: `{"order":["uuid","uuid",…]}` — все маршруты сервера, каждый по разу |
| `GET`, `POST /api/<scope>/servers/<uuid>/ports` | на каких портах слушает сервер; привязать ещё один — `{"port_id":"…","default_server":false}` |
| `PUT`, `DELETE /api/<scope>/servers/<uuid>/ports/<bind>` | изменить или снять привязку |
| `GET`, `POST /api/<scope>/servers/<uuid>/certificates` | сертификаты, привязанные к серверу |
| `DELETE /api/<scope>/servers/<uuid>/certificates/<bind>` | отвязать один |
| `GET`, `POST /api/<scope>/ports` | порты пространства |
| `GET`, `PUT`, `DELETE /api/<scope>/ports/<uuid>` | один порт: адрес, номер, `ssl`, `http2`, `proxy_protocol` |
| `GET /api/<scope>/locations` | все маршруты пространства; `?server=<uuid>` оставит маршруты одного сервера |
| `GET`, `PUT`, `DELETE /api/<scope>/locations/<uuid>` | один маршрут |
| `GET /api/<scope>/locations/<uuid>/inheritance` | что он наследует от пространства и сервера |
| `GET`, `POST /api/<scope>/upstreams` | апстримы с их узлами |
| `GET`, `PUT`, `DELETE /api/<scope>/upstreams/<uuid>` | один апстрим |

У сервера два документа: `nginx` — поведение nginx (реальный адрес клиента, заголовки к бэкенду,
тайм-ауты), `waf` — защита: какие инспекторы там работают и с какими профилями. У маршрута те же
два, плюс обработчик: `proxy` на апстрим или возврат ответа.

`raw: true` у пространства, сервера или маршрута значит, что его текст пишут вручную в `raw_nginx`,
и контроллер только проверяет, что конфигурация собирается.

Порт, на котором ещё слушает сервер, удалить нельзя: `409 port_bound`. Апстрим, на который ещё
смотрит маршрут, — `409 upstream_bound`.

## Настройки пространства

| Ручка | Что делает |
| --- | --- |
| `GET /api/<scope>/http` | пространство: `nginx_main`, `nginx`, `waf_http`, `waf` и адреса инфраструктуры |
| `PUT /api/<scope>/http` | изменить их |
| `GET /api/<scope>/http/inheritance` | слой пространства так, как его видят серверы и маршруты |

`infra` показывает, где соседи узла — шина и оба Redis. Это только на чтение: `PUT` его не
принимает, а в адресах Redis пароль заменён на `***`.

## Сертификаты и буфер

Сертификат никогда не передаётся полем. Сначала файл кладут в буфер, зашифрованным ключом
установки, и уже сертификат ссылается на положенные объекты.

| Ручка | Что делает |
| --- | --- |
| `POST /api/<scope>/store` | положить объект: `{"type":"…","metadata":{…},"blob":"<base64>"}`, в ответ `201` и uuid |
| `GET /api/<scope>/store` | каталог: uuid, тип, метаданные, размер — без содержимого |
| `GET /api/<scope>/store/<uuid>` | метаданные и содержимое в base64 |
| `GET /api/<scope>/store/<uuid>/meta` | только метаданные |
| `GET /api/<scope>/store/<uuid>/blob` | сырой шифротекст, для агента |
| `GET`, `POST /api/<scope>/certificates` | сертификаты пространства; создать из объектов буфера |
| `GET`, `DELETE /api/<scope>/certificates/<uuid>` | один сертификат |
| `PUT`, `DELETE /api/<scope>/certificates/<uuid>/crl` | приложить или снять список отзыва |

`type` объекта — это `certificate`, `private_key`, `chain`, `ca`, `crl`, `creds`, `dhparam`,
`deny_page` или `other`. Объект пишут один раз и читают много: ни `PUT`, ни `DELETE` у него нет.

Сертификат создаётся из `{"name":"…","type":"server","cert_store_id":"…","key_store_id":"…"}`;
`type` — `server` или `client_ca`, серверному нужен ключ. Subject, издателя, SAN и даты контроллер
спрашивает у службы ключей и хранит рядом — сам он ничего не расшифровывает. `client_ca`, который
не является CA, отклоняется с `422 not_a_ca`, а CRL от другого издателя — с
`422 crl_issuer_mismatch`.

Объект больше `CONTROLLER_STORE_MAX_BYTES` — это `413 blob_too_large`, предел придёт в `max`.

## Инспекторы

Инспектор — процесс, который оценивает запросы. В пространстве лежит их каталог: имя, которым инспектора
вызывают в конфигурации, subject шины, на котором процесс слушает, и фазы, в которых он работает.

| Ручка | Что делает |
| --- | --- |
| `GET /api/<scope>/inspectors` | каталог |
| `POST /api/<scope>/inspectors` | добавить: `name`, `subject`, `phases`, `description`, `docs_url`, `log_level`, `conf` |
| `GET`, `PUT`, `DELETE /api/<scope>/inspectors/<uuid>` | одна запись |
| `GET /api/<scope>/inspectors/declared` | каких инспекторов конфигурация вызывает на самом деле, с каким профилем и знает ли их каталог |
| `PUT /api/<scope>/inspectors/installed` | задать список установленных: `{"names":["ip","modsec"]}` |

`declared` отвечает на вопрос «кого эта конфигурация ожидает увидеть»: обходит пространство, серверы
и маршруты, сводит их объявления и помечает незнакомых `known: false`. Именно на них `config/send`
и споткнётся.

`installed` — про другое: кто из поставляемых инспекторов работает в этой установке. Инспектор, на
которого ещё ссылается конфигурация, уйти не может: `409 inspector_in_use`, места перечислены
в `uses`. Удаление записи каталога, на которую ссылаются, падает так же.

## Профили инспекторов

Восемь инспекторов держат настройки в профилях, и ручки у всех восьми одинаковые. Вместо `<имя>`
подставьте `auth`, `captcha`, `json`, `action`, `cookie`, `counter`, `vlai` или `rewrite`:

| Ручка | Что делает |
| --- | --- |
| `GET /api/<scope>/<имя>/profiles` | все профили этого инспектора |
| `POST /api/<scope>/<имя>/profiles` | создать: `{"name":"…","description":"…","doc":{…}}` |
| `GET`, `PUT`, `DELETE /api/<scope>/<имя>/profiles/<uuid>` | один профиль |
| `POST /api/<scope>/<имя>/profiles/<uuid>/restore` | вернуть поставляемый `default` в исходный вид |
| `POST /api/<scope>/<имя>/send` | применить профили этого инспектора |
| `GET /api/<scope>/<имя>/desired` | изданное поколение |

`doc` — это и есть профиль, и поля в нём свои у каждого инспектора: у профиля капчи и у профиля
правки ответов общего нет ничего. Панель строит формы из тех же документов, а в её справке в разделе
**Защита** каждое поле описано словами. Неподходящий `doc` — это `400 invalid_profile`, а ссылка
внутри него, которая никуда не ведёт, называет себя: `deny_response_unknown`, `schema_not_found`,
`counter_unknown`, имя придёт в `detail`.

У каждого инспектора есть профиль `default`. Его нельзя переименовать (`400 default_name_locked`)
и нельзя удалить, пока он последний (`409 default_required`); профиль, которым ещё пользуется
маршрут, тоже не удалить (`409 in_use`). `modified: true` у `default` значит, что он разошёлся с
поставляемым; `restore` возвращает его обратно.

У двух инспекторов есть кое-что помимо профилей.

**auth** держит ещё источники, по которым профиль пускает людей:

| Ручка | Что делает |
| --- | --- |
| `GET`, `POST /api/<scope>/auth/sources` | источники: файл пользователей, LDAP или другой поставщик |
| `GET`, `PUT`, `DELETE /api/<scope>/auth/sources/<uuid>` | один источник |
| `POST /api/<scope>/auth/user-line` | собрать строку для файлового источника |

`user-line` принимает `{"login":"…","password":"…","groups":["admin"],"totp_store":"<uuid>"}`
и возвращает `{"line":"login:$2b$…:admin"}` — пароль, посчитанный bcrypt, готовый к вставке в файл
пользователей. Контроллер ничего не сохраняет: это помощник, а не реестр. Слабый пароль отклоняется
с `400 weak_password`.

Источник, которым пользуется профиль, не удалить (`409 in_use`), а профиль с несуществующим
источником не сохранить (`400 unknown_source`). Профиль, который пускает по группам, не сохранится
(`409 fast_path_gated`), пока маршрут вызывает инспектора по условию: условие может проскочить мимо
проверки групп, и проверка входа не удержит.

**counter** держит ещё общие счётчики пространства:

| Ручка | Что делает |
| --- | --- |
| `GET /api/<scope>/counter/shared` | общие счётчики |
| `PUT /api/<scope>/counter/shared` | заменить их: `{"shared":[…]}` |

Счётчик, на который ещё смотрит профиль, пропасть не может: `400 profile_reference_broken`.

## Правила ModSecurity

| Ручка | Что делает |
| --- | --- |
| `GET`, `POST /api/<scope>/rule-files` | файлы правил; файл — это `name`, `description` и `text_raw` |
| `GET`, `PUT`, `DELETE /api/<scope>/rule-files/<uuid>` | один файл |
| `GET`, `POST /api/<scope>/rule-sets` | наборы правил: какие файлы и списки идут вместе, плюс политика |
| `GET`, `PUT`, `DELETE /api/<scope>/rule-sets/<uuid>` | один набор |
| `POST /api/<scope>/rule-sets/<uuid>/restore` | вернуть поставляемый набор `default` |
| `POST /api/<scope>/rules/compile` | собрать, не применяя; в ответ счётчики и хеш |
| `POST /api/<scope>/rules/send` | собрать и применить |
| `GET /api/<scope>/rules/desired` | изданное поколение: версия, хеш, имена профилей |
| `GET /api/<scope>/rules/pack` | весь изданный указатель, каким его читает инспектор |

Файл, входящий в набор, не удалить (`409 in_use`). `compile` — безопасный способ проверить файл
правил до того, как он дойдёт до узла.

## Списки IP, профили и геоданные

| Ручка | Что делает |
| --- | --- |
| `GET`, `POST /api/<scope>/ip-sets` | наборы IP: списки, страны и ASN, со стороной `exclude` и флагом `inverse` |
| `GET`, `PUT`, `DELETE /api/<scope>/ip-sets/<uuid>` | один набор |
| `GET`, `POST /api/<scope>/ip-profiles` | профили IP: упорядоченные правила по этим наборам |
| `GET`, `PUT`, `DELETE /api/<scope>/ip-profiles/<uuid>` | один профиль |
| `POST /api/<scope>/ip-profiles/<uuid>/restore` | вернуть поставляемый `default` |
| `POST /api/<scope>/ip-profiles/send` | применить профили |
| `GET /api/<scope>/ip-profiles/desired`, `…/pack` | изданное поколение и полный указатель |
| `GET /api/<scope>/ip-countries` | страны с размером списка префиксов |
| `GET /api/<scope>/ip-countries/<uuid>/addresses` | её префиксы; `?q=` фильтрует по адресу или подсети |
| `GET /api/<scope>/ip-countries/<uuid>/addresses/export` | то же текстовым файлом |
| `GET /api/<scope>/ip-asns`, `…/<uuid>/addresses`, `…/export` | то же для автономных систем |
| `POST /api/<scope>/geo/lookup/batch` | посмотреть адреса: `{"addrs":["203.0.113.7"]}` |
| `POST /api/<scope>/geo/import/<kind>` | загрузить базу MaxMind, `kind` — `country` или `asn` |
| `GET /api/<scope>/geo/import` | как идут задания импорта |
| `GET /api/geo/files/<kind>` | загруженный файл: хеш, размер, дата сборки, опубликован ли он |

Префиксы стран и ASN — единственные списки в API с постраничной выдачей: они принимают `page`
(с нуля) и `page_size` (по умолчанию 10, не больше 200), а в ответе рядом с записями лежат `total`,
`count`, `page`, `page_size` и `page_count`. `export` страницы не знает и отдаёт весь список
текстовым вложением. Всё остальное отвечает целиком.

Загрузка — это сам файл в теле, без формы:

```sh
curl -s -X POST --data-binary @GeoLite2-Country.mmdb \
  -H 'content-type: application/octet-stream' \
  "$API/geo/import/country"
```

В ответ приходит `202` и задание; импорт идёт в фоне, а `GET geo/import` показывает, до чего он
дошёл — разбор, сравнение, запись — и что изменилось. Слишком большой файл — `413 file_too_large`,
предел в `detail`; незнакомый `kind` — `404 unknown_kind`.

## Наборы и адреса

Набор данных — это именованный набор значений, который читают узел и инспекторы: адреса, строки,
тело страницы.

| Ручка | Что делает |
| --- | --- |
| `GET`, `POST /api/<scope>/datasets` | наборы пространства; создать набор |
| `GET`, `PUT`, `DELETE /api/<scope>/datasets/<uuid>` | один набор |
| `GET /api/<scope>/datasets/<uuid>/addresses` | его записи; `?q=` оставит те, где встречается эта строка |
| `POST /api/<scope>/datasets/<uuid>/addresses` | добавить записи: `address`, или `addresses`, или целый `text`, и необязательный `ttl_s` |
| `GET`, `PUT /api/<scope>/datasets/<uuid>/content` | тело набора вида `content`, в base64 |
| `GET /api/<scope>/addresses?address=<значение>` | найти ровно это значение по всем наборам пространства |
| `GET`, `DELETE /api/<scope>/addresses/<uuid>` | одна запись |

`kind` — это `list` или `content`; `type` говорит, как выглядит значение. Набор `active` живой: он
лежит в Redis, узел и инспекторы пишут в него на ходу, а запись с `ttl_s` пропадает сама. Набор
`internal` лежит в базе и меняется только тогда, когда его меняете вы. Через API и тот и другой
читаются и пишутся одинаково; `in_nginx: true` вдобавок вкомпилирует набор в конфигурацию узла, а
для этого нужен `config/send`.

В ответ на добавление придёт то, что добавилось, а на плохое значение — `400 invalid_address`
с перечнем в `invalid`. Набор, на который ссылаются, не удалить (`409 in_use`); поставляемый набор
не переименовать и не удалить (`400 builtin_locked`).

## Ответы блокировки, хранилища тел, форматы журнала

| Ручка | Что делает |
| --- | --- |
| `GET`, `POST /api/<scope>/deny-responses` | чем узел отвечает при блокировке |
| `PUT`, `DELETE /api/<scope>/deny-responses/<uuid>` | один ответ |
| `GET`, `POST /api/<scope>/body-stores` | куда складываются тела запросов |
| `PUT /api/<scope>/body-stores/<uuid>` | изменить одно; удаления у хранилища тел нет |
| `GET`, `POST /api/<scope>/log-formats` | форматы журнала nginx |
| `PUT`, `DELETE /api/<scope>/log-formats/<uuid>` | один формат |

Ответ блокировки приходит с полем `uses`: все места конфигурации, где он назван. Хранилище тел
отвечает адресом архива, с которым настроен контроллер, в `url`, а остальными настройками — в
`spec`. Удаление отвечает `{"ok":true}`, занятое имя — `409 name_taken`.

## Конфигурация узла

| Ручка | Что делает |
| --- | --- |
| `GET /api/<scope>/config/preview` | вся конфигурация nginx текстом, как она есть сейчас |
| `POST /api/<scope>/config/preview` | то же для черновика: `{"draft":{…},"node":{"kind":"server","uuid":"…"}}` |
| `POST /api/<scope>/config/send` | собрать, проверить и применить |
| `GET /api/<scope>/config/desired` | изданное поколение |

`POST config/preview` — это то, что панель показывает, пока вы ещё правите: она накладывает
несохранённое на сохранённое и возвращает только этот блок, с `errors` и `warnings` вместо ошибки.
Ничего не сохраняется и никуда не уходит.

`config/send` не примет конфигурацию, которая не заработает, и скажет почему:

```json
{
  "error": "validation_failed",
  "errors": [
    { "code": "auth_fast_path_gated", "message": "waf_inspect auth on shop.example.com / …" }
  ]
}
```

Если всё хорошо, в ответе будет новое поколение и предупреждения, которые не сочли смертельными, —
например, действие, которого никто не слушает.

## Агент узла и балансировщик

| Ручка | Что делает |
| --- | --- |
| `GET`, `PUT /api/<scope>/agent` | настройки агента узла и хеш того, во что они собираются |
| `POST /api/<scope>/agent/send` | применить их |
| `GET /api/<scope>/agent/desired` | изданное поколение |
| `GET`, `PUT /api/<scope>/haproxy` | настройки балансировщика |
| `GET /api/<scope>/haproxy/preview` | `haproxy.cfg`, в который они собираются, текстом |
| `POST /api/<scope>/haproxy/send` | применить их |
| `GET /api/<scope>/haproxy/desired` | изданное поколение |

Применение, которой нечего менять, оставляет прежнюю версию и просто подтверждает поколение.

## Аудит и журналы

Поисковые ручки — тонкая прокладка к службе поиска, которая читает то, что записал логгер.

| Ручка | Что отдаёт |
| --- | --- |
| `GET /api/search/audit` | события: по одному на проверенный запрос |
| `GET /api/search/audit/groups` | то же, сгруппированное |
| `GET /api/search/audit/<node>/<ray>` | одна запись по узлу и идентификатору запроса |
| `GET /api/search/audit/<node>/<ray>/<часть>` | её часть: `inspectors`, `findings`, `headers`, `args`, `body` |
| `GET /api/search/findings` | что нашли инспекторы |
| `GET /api/search/logs` | журналы служб |
| `GET /api/search/logs/facets` | значения, которые предлагают фильтры журнала |

Строка запроса передаётся как есть, и ответ тоже. Если поиск не настроен, придёт
`503 search_disabled`; если он не ответил за 15 секунд — `503 search_unreachable`.

## Рецепты

Найти пространство и посмотреть, что установлено:

```sh
API=http://127.0.0.1:8080/api
SCOPE=$(curl -s $API/spaces | jq -r '.spaces[0].uuid')

curl -s $API/$SCOPE/catalog | jq '{inspectors:[.inspectors[].name], profiles:[.profiles[].name]}'
```

Включить защиту на одном маршруте и отправить это на узел:

```sh
LOC=$(curl -s "$API/$SCOPE/locations?server=$SERVER" | jq -r '.locations[0].uuid')

curl -s -X PUT $API/$SCOPE/locations/$LOC \
  -H 'content-type: application/json' \
  -d '{"waf":{"enabled":true}}'

curl -s $API/$SCOPE/config/preview          # вся конфигурация nginx текстом
curl -s -X POST $API/$SCOPE/config/send     # собрать, проверить, применить
```

Забанить адрес на час:

```sh
DS=$(curl -s $API/$SCOPE/datasets | jq -r '.datasets[] | select(.name=="shop-banned") | .uuid')

curl -s -X POST $API/$SCOPE/datasets/$DS/addresses \
  -H 'content-type: application/json' \
  -d '{"address":"203.0.113.7","ttl_s":3600}'
```

Посмотреть, дошло ли:

```sh
curl -s $API/$SCOPE/convergence | jq '{lamp, channels: [.channels[] | {id, state}]}'
```

```json
{ "lamp": "green", "channels": [ { "id": "nginx", "state": "ok" }, { "id": "rules", "state": "ok" } ] }
```

Канал остаётся `stale`, пока получатель работает по прежнему поколению, и становится `failed`, если
он попробовал и не смог. Кто именно — скажет `GET /api/fleet`.

Применить всё после серии правок:

```sh
for ch in config rules ip-profiles auth captcha json action cookie counter vlai rewrite agent haproxy; do
  curl -s -X POST $API/$SCOPE/$ch/send >/dev/null
done
```

Применение, которой нечего применять, безвредна: поколение и его версия останутся прежними.

## Все ручки

Один список, чтобы искать глазами и грепом. Подробности — в разделах выше.

| Метод | Путь |
| --- | --- |
| `GET` | `/healthz` |
| `GET` | `/api/health` |
| `GET` | `/api/meta` |
| `GET` | `/api/actions` |
| `GET` | `/api/fleet` |
| `POST` | `/api/fleet/forget` |
| `GET` | `/api/geo/files/<kind>` |
| `GET` | `/api/log-levels` |
| `PUT` | `/api/log-levels` |
| `GET` | `/api/search/audit` |
| `GET` | `/api/search/audit/<node>/<ray>` |
| `GET` | `/api/search/audit/<node>/<ray>/args` |
| `GET` | `/api/search/audit/<node>/<ray>/body` |
| `GET` | `/api/search/audit/<node>/<ray>/findings` |
| `GET` | `/api/search/audit/<node>/<ray>/headers` |
| `GET` | `/api/search/audit/<node>/<ray>/inspectors` |
| `GET` | `/api/search/audit/groups` |
| `GET` | `/api/search/findings` |
| `GET` | `/api/search/logs` |
| `GET` | `/api/search/logs/facets` |
| `GET` | `/api/spaces` |
| `GET` | `/api/<scope>/action/desired` |
| `GET` | `/api/<scope>/action/profiles` |
| `POST` | `/api/<scope>/action/profiles` |
| `GET` | `/api/<scope>/action/profiles/<uuid>` |
| `PUT` | `/api/<scope>/action/profiles/<uuid>` |
| `DELETE` | `/api/<scope>/action/profiles/<uuid>` |
| `POST` | `/api/<scope>/action/profiles/<uuid>/restore` |
| `POST` | `/api/<scope>/action/send` |
| `GET` | `/api/<scope>/addresses` |
| `GET` | `/api/<scope>/addresses/<uuid>` |
| `DELETE` | `/api/<scope>/addresses/<uuid>` |
| `GET` | `/api/<scope>/agent` |
| `PUT` | `/api/<scope>/agent` |
| `GET` | `/api/<scope>/agent/desired` |
| `POST` | `/api/<scope>/agent/send` |
| `GET` | `/api/<scope>/auth/desired` |
| `GET` | `/api/<scope>/auth/profiles` |
| `POST` | `/api/<scope>/auth/profiles` |
| `GET` | `/api/<scope>/auth/profiles/<uuid>` |
| `PUT` | `/api/<scope>/auth/profiles/<uuid>` |
| `DELETE` | `/api/<scope>/auth/profiles/<uuid>` |
| `POST` | `/api/<scope>/auth/profiles/<uuid>/restore` |
| `POST` | `/api/<scope>/auth/send` |
| `GET` | `/api/<scope>/auth/sources` |
| `POST` | `/api/<scope>/auth/sources` |
| `GET` | `/api/<scope>/auth/sources/<uuid>` |
| `PUT` | `/api/<scope>/auth/sources/<uuid>` |
| `DELETE` | `/api/<scope>/auth/sources/<uuid>` |
| `POST` | `/api/<scope>/auth/user-line` |
| `GET` | `/api/<scope>/captcha/desired` |
| `GET` | `/api/<scope>/captcha/profiles` |
| `POST` | `/api/<scope>/captcha/profiles` |
| `GET` | `/api/<scope>/captcha/profiles/<uuid>` |
| `PUT` | `/api/<scope>/captcha/profiles/<uuid>` |
| `DELETE` | `/api/<scope>/captcha/profiles/<uuid>` |
| `POST` | `/api/<scope>/captcha/profiles/<uuid>/restore` |
| `POST` | `/api/<scope>/captcha/send` |
| `GET` | `/api/<scope>/catalog` |
| `GET` | `/api/<scope>/certificates` |
| `POST` | `/api/<scope>/certificates` |
| `GET` | `/api/<scope>/certificates/<uuid>` |
| `DELETE` | `/api/<scope>/certificates/<uuid>` |
| `PUT` | `/api/<scope>/certificates/<uuid>/crl` |
| `DELETE` | `/api/<scope>/certificates/<uuid>/crl` |
| `GET` | `/api/<scope>/config/desired` |
| `GET` | `/api/<scope>/config/preview` |
| `POST` | `/api/<scope>/config/preview` |
| `POST` | `/api/<scope>/config/send` |
| `GET` | `/api/<scope>/content-types` |
| `GET` | `/api/<scope>/convergence` |
| `POST` | `/api/<scope>/convergence/refresh` |
| `GET` | `/api/<scope>/cookie/desired` |
| `GET` | `/api/<scope>/cookie/profiles` |
| `POST` | `/api/<scope>/cookie/profiles` |
| `GET` | `/api/<scope>/cookie/profiles/<uuid>` |
| `PUT` | `/api/<scope>/cookie/profiles/<uuid>` |
| `DELETE` | `/api/<scope>/cookie/profiles/<uuid>` |
| `POST` | `/api/<scope>/cookie/profiles/<uuid>/restore` |
| `POST` | `/api/<scope>/cookie/send` |
| `GET` | `/api/<scope>/counter/desired` |
| `GET` | `/api/<scope>/counter/profiles` |
| `POST` | `/api/<scope>/counter/profiles` |
| `GET` | `/api/<scope>/counter/profiles/<uuid>` |
| `PUT` | `/api/<scope>/counter/profiles/<uuid>` |
| `DELETE` | `/api/<scope>/counter/profiles/<uuid>` |
| `POST` | `/api/<scope>/counter/profiles/<uuid>/restore` |
| `POST` | `/api/<scope>/counter/send` |
| `GET` | `/api/<scope>/counter/shared` |
| `PUT` | `/api/<scope>/counter/shared` |
| `GET` | `/api/<scope>/crypto` |
| `GET` | `/api/<scope>/datasets` |
| `POST` | `/api/<scope>/datasets` |
| `GET` | `/api/<scope>/datasets/<uuid>` |
| `PUT` | `/api/<scope>/datasets/<uuid>` |
| `DELETE` | `/api/<scope>/datasets/<uuid>` |
| `GET` | `/api/<scope>/datasets/<uuid>/addresses` |
| `POST` | `/api/<scope>/datasets/<uuid>/addresses` |
| `GET` | `/api/<scope>/datasets/<uuid>/content` |
| `PUT` | `/api/<scope>/datasets/<uuid>/content` |
| `POST` | `/api/<scope>/geo/lookup/batch` |
| `GET` | `/api/<scope>/geo/import` |
| `POST` | `/api/<scope>/geo/import/<kind>` |
| `GET` | `/api/<scope>/haproxy` |
| `PUT` | `/api/<scope>/haproxy` |
| `GET` | `/api/<scope>/haproxy/desired` |
| `GET` | `/api/<scope>/haproxy/preview` |
| `POST` | `/api/<scope>/haproxy/send` |
| `GET` | `/api/<scope>/http` |
| `PUT` | `/api/<scope>/http` |
| `GET` | `/api/<scope>/http/inheritance` |
| `GET` | `/api/<scope>/inspectors` |
| `POST` | `/api/<scope>/inspectors` |
| `GET` | `/api/<scope>/inspectors/<uuid>` |
| `PUT` | `/api/<scope>/inspectors/<uuid>` |
| `DELETE` | `/api/<scope>/inspectors/<uuid>` |
| `GET` | `/api/<scope>/inspectors/declared` |
| `PUT` | `/api/<scope>/inspectors/installed` |
| `GET` | `/api/<scope>/ip-asns` |
| `GET` | `/api/<scope>/ip-asns/<uuid>` |
| `GET` | `/api/<scope>/ip-asns/<uuid>/addresses` |
| `GET` | `/api/<scope>/ip-asns/<uuid>/addresses/export` |
| `GET` | `/api/<scope>/ip-countries` |
| `GET` | `/api/<scope>/ip-countries/<uuid>` |
| `GET` | `/api/<scope>/ip-countries/<uuid>/addresses` |
| `GET` | `/api/<scope>/ip-countries/<uuid>/addresses/export` |
| `GET` | `/api/<scope>/ip-profiles` |
| `POST` | `/api/<scope>/ip-profiles` |
| `GET` | `/api/<scope>/ip-profiles/<uuid>` |
| `PUT` | `/api/<scope>/ip-profiles/<uuid>` |
| `DELETE` | `/api/<scope>/ip-profiles/<uuid>` |
| `POST` | `/api/<scope>/ip-profiles/<uuid>/restore` |
| `GET` | `/api/<scope>/ip-profiles/desired` |
| `GET` | `/api/<scope>/ip-profiles/pack` |
| `POST` | `/api/<scope>/ip-profiles/send` |
| `GET` | `/api/<scope>/ip-sets` |
| `POST` | `/api/<scope>/ip-sets` |
| `GET` | `/api/<scope>/ip-sets/<uuid>` |
| `PUT` | `/api/<scope>/ip-sets/<uuid>` |
| `DELETE` | `/api/<scope>/ip-sets/<uuid>` |
| `GET` | `/api/<scope>/json/desired` |
| `GET` | `/api/<scope>/json/profiles` |
| `POST` | `/api/<scope>/json/profiles` |
| `GET` | `/api/<scope>/json/profiles/<uuid>` |
| `PUT` | `/api/<scope>/json/profiles/<uuid>` |
| `DELETE` | `/api/<scope>/json/profiles/<uuid>` |
| `POST` | `/api/<scope>/json/profiles/<uuid>/restore` |
| `POST` | `/api/<scope>/json/send` |
| `GET` | `/api/<scope>/locations` |
| `GET` | `/api/<scope>/locations/<uuid>` |
| `PUT` | `/api/<scope>/locations/<uuid>` |
| `DELETE` | `/api/<scope>/locations/<uuid>` |
| `GET` | `/api/<scope>/locations/<uuid>/inheritance` |
| `GET` | `/api/<scope>/ports` |
| `POST` | `/api/<scope>/ports` |
| `GET` | `/api/<scope>/ports/<uuid>` |
| `PUT` | `/api/<scope>/ports/<uuid>` |
| `DELETE` | `/api/<scope>/ports/<uuid>` |
| `GET` | `/api/<scope>/rewrite/desired` |
| `GET` | `/api/<scope>/rewrite/profiles` |
| `POST` | `/api/<scope>/rewrite/profiles` |
| `GET` | `/api/<scope>/rewrite/profiles/<uuid>` |
| `PUT` | `/api/<scope>/rewrite/profiles/<uuid>` |
| `DELETE` | `/api/<scope>/rewrite/profiles/<uuid>` |
| `POST` | `/api/<scope>/rewrite/profiles/<uuid>/restore` |
| `POST` | `/api/<scope>/rewrite/send` |
| `GET` | `/api/<scope>/rule-files` |
| `POST` | `/api/<scope>/rule-files` |
| `GET` | `/api/<scope>/rule-files/<uuid>` |
| `PUT` | `/api/<scope>/rule-files/<uuid>` |
| `DELETE` | `/api/<scope>/rule-files/<uuid>` |
| `GET` | `/api/<scope>/rule-sets` |
| `POST` | `/api/<scope>/rule-sets` |
| `GET` | `/api/<scope>/rule-sets/<uuid>` |
| `PUT` | `/api/<scope>/rule-sets/<uuid>` |
| `DELETE` | `/api/<scope>/rule-sets/<uuid>` |
| `POST` | `/api/<scope>/rule-sets/<uuid>/restore` |
| `POST` | `/api/<scope>/rules/compile` |
| `GET` | `/api/<scope>/rules/desired` |
| `GET` | `/api/<scope>/rules/pack` |
| `POST` | `/api/<scope>/rules/send` |
| `GET` | `/api/<scope>/servers` |
| `POST` | `/api/<scope>/servers` |
| `GET` | `/api/<scope>/servers/<uuid>` |
| `PUT` | `/api/<scope>/servers/<uuid>` |
| `DELETE` | `/api/<scope>/servers/<uuid>` |
| `GET` | `/api/<scope>/servers/<uuid>/certificates` |
| `POST` | `/api/<scope>/servers/<uuid>/certificates` |
| `DELETE` | `/api/<scope>/servers/<uuid>/certificates/<bind-uuid>` |
| `GET` | `/api/<scope>/servers/<uuid>/inheritance` |
| `GET` | `/api/<scope>/servers/<uuid>/locations` |
| `POST` | `/api/<scope>/servers/<uuid>/locations` |
| `PUT` | `/api/<scope>/servers/<uuid>/locations/order` |
| `GET` | `/api/<scope>/servers/<uuid>/ports` |
| `POST` | `/api/<scope>/servers/<uuid>/ports` |
| `PUT` | `/api/<scope>/servers/<uuid>/ports/<bind-uuid>` |
| `DELETE` | `/api/<scope>/servers/<uuid>/ports/<bind-uuid>` |
| `GET` | `/api/<scope>/store` |
| `POST` | `/api/<scope>/store` |
| `GET` | `/api/<scope>/store/<uuid>` |
| `GET` | `/api/<scope>/store/<uuid>/blob` |
| `GET` | `/api/<scope>/store/<uuid>/meta` |
| `GET` | `/api/<scope>/upstreams` |
| `POST` | `/api/<scope>/upstreams` |
| `GET` | `/api/<scope>/upstreams/<uuid>` |
| `PUT` | `/api/<scope>/upstreams/<uuid>` |
| `DELETE` | `/api/<scope>/upstreams/<uuid>` |
| `GET` | `/api/<scope>/vlai/desired` |
| `GET` | `/api/<scope>/vlai/profiles` |
| `POST` | `/api/<scope>/vlai/profiles` |
| `GET` | `/api/<scope>/vlai/profiles/<uuid>` |
| `PUT` | `/api/<scope>/vlai/profiles/<uuid>` |
| `DELETE` | `/api/<scope>/vlai/profiles/<uuid>` |
| `POST` | `/api/<scope>/vlai/profiles/<uuid>/restore` |
| `POST` | `/api/<scope>/vlai/send` |
| `WS` | `/agent_health_socket` |
