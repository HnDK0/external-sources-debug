-- ── Метаданные ────────────────────────────────────────────────────────────────
id       = "ranobehub"
name     = "RanobeHub"
version  = "1.0.2"
baseUrl  = "https://ranobehub.org"
language = "ru"
icon     = "https://raw.githubusercontent.com/HnDK0/external-sources/main/icons/ranobehub.png"

-- ── Константы ─────────────────────────────────────────────────────────────────

local apiBase = "https://ranobehub.org/api/"

-- ── Хелперы ───────────────────────────────────────────────────────────────────

local function absUrl(href)
  if not href or href == "" then return "" end
  if string_starts_with(href, "http") then return href end
  if string_starts_with(href, "//") then return "https:" .. href end
  return url_resolve(baseUrl, href)
end

local function extractId(bookUrl)
  local segment = bookUrl:gsub(baseUrl .. "/ranobe/", ""):match("^([^/?#]+)")
  if not segment then return nil end
  return segment:match("^(%d+)")
end

local function applyStandardContentTransforms(text)
  if not text or text == "" then return "" end
  text = string_normalize(text)
  local domain = baseUrl:gsub("https?://", ""):gsub("^www%.", ""):gsub("/$", "")
  text = regex_replace(text, "(?i)" .. domain .. ".*?\\n", "")
  text = regex_replace(text, "(?i)\\A[\\s\\p{Z}\\uFEFF]*((Глава\\s+\\d+|Chapter\\s+\\d+)[^\\n\\r]*[\\n\\r\\s]*)+", "")
  text = string_trim(text)
  return text
end

local function pickTitle(names, fallback)
  if not names then return fallback or "" end
  return names.rus or names.eng or names.original or fallback or ""
end

-- Вспомогательная функция — парсит результаты поиска из data.resource
local function parseResource(data)
  local items = {}
  if not data or not data.resource then return items end
  for _, novel in ipairs(data.resource) do
    local title = pickTitle(novel.names, novel.name)
    local id    = tostring(novel.id or "")
    local cover = novel.poster and novel.poster.medium or ""
    if title ~= "" and id ~= "" then
      table.insert(items, {
        title = string_clean(title),
        url   = baseUrl .. "/ranobe/" .. id,
        cover = absUrl(cover)
      })
    end
  end
  return items
end

-- ── Каталог (JSON API) ────────────────────────────────────────────────────────

function getCatalogList(index)
  local page = index + 1
  local url = apiBase .. "search?page=" .. tostring(page) .. "&sort=computed_rating&status=0&take=40"

  local r = http_get(url)
  if not r.success then return { items = {}, hasNext = false } end

  local data = json_parse(r.body)
  local items = parseResource(data)
  return { items = items, hasNext = #items > 0 }
end

-- ── Поиск (JSON API fulltext, только первая страница) ─────────────────────────

function getCatalogSearch(index, query)
  if index > 0 then return { items = {}, hasNext = false } end

  local url = apiBase .. "fulltext/global?query=" .. url_encode(query) .. "&take=10"
  local r = http_get(url)
  if not r.success then return { items = {}, hasNext = false } end

  local results = json_parse(r.body)
  if not results then return { items = {}, hasNext = false } end

  local items = {}
  for _, block in ipairs(results) do
    if type(block) == "table" then
      local meta = block.meta
      if meta and meta.key == "ranobe" and block.data then
        for _, novel in ipairs(block.data) do
          local title = pickTitle(novel.names, novel.name)
          local id    = tostring(novel.id or "")
          local cover = novel.image and novel.image:gsub("/small", "/medium") or ""
          if title ~= "" and id ~= "" then
            table.insert(items, {
              title = string_clean(title),
              url   = baseUrl .. "/ranobe/" .. id,
              cover = absUrl(cover)
            })
          end
        end
      end
    end
  end

  return { items = items, hasNext = false }
end

-- ── Детали книги (JSON API /api/ranobe/{id}) ──────────────────────────────────

local function fetchBookData(bookUrl)
  local id = extractId(bookUrl)
  if not id then return nil end
  local r = http_get(apiBase .. "ranobe/" .. id)
  if not r.success then return nil end
  local parsed = json_parse(r.body)
  return parsed and parsed.data or nil
end

function getBookTitle(bookUrl)
  local data = fetchBookData(bookUrl)
  if not data then return nil end
  local title = pickTitle(data.names, data.name)
  return title ~= "" and string_clean(title) or nil
end

function getBookCoverImageUrl(bookUrl)
  local data = fetchBookData(bookUrl)
  if not data then return nil end
  local cover = data.posters and data.posters.medium or ""
  return cover ~= "" and absUrl(cover) or nil
end

function getBookDescription(bookUrl)
  local data = fetchBookData(bookUrl)
  if not data then return nil end
  local desc = data.description or ""
  desc = regex_replace(desc, "<[^>]*>", "")
  return string_trim(desc) ~= "" and string_trim(desc) or nil
end

-- ── Жанры и теги книги ────────────────────────────────────────────────────────
--
-- API возвращает два массива в data.tags:
--   data.tags.genres — основные жанры (Фэнтези, Романтика, Экшн …)
--   data.tags.events — события/теги  (Реинкарнация, Академия, ЛитРПГ …)
--
-- Для каждого элемента берём names.rus → names.eng → title (в таком приоритете).
-- Оба массива объединяются в один список — Kotlin не различает "жанр" и "тег",
-- показывает всё одинаковыми чипами.

function getBookGenres(bookUrl)
  local data = fetchBookData(bookUrl)
  if not data or not data.tags then return {} end

  local genres = {}

  local function addTags(tagArray)
    if not tagArray then return end
    for _, tag in ipairs(tagArray) do
      local label = (tag.names and (tag.names.rus or tag.names.eng)) or tag.title or ""
      label = string_trim(label)
      if label ~= "" then
        table.insert(genres, label)
      end
    end
  end

  addTags(data.tags.genres)
  addTags(data.tags.events)

  return genres
end

-- ── Список глав ───────────────────────────────────────────────────────────────

function getChapterList(bookUrl)
  local id = extractId(bookUrl)
  if not id then
    log_error("ranobehub: cannot extract id from " .. bookUrl)
    return {}
  end

  local r = http_get(apiBase .. "ranobe/" .. id .. "/contents")
  if not r.success then
    log_error("ranobehub: contents failed code=" .. tostring(r.code))
    return {}
  end

  local data = json_parse(r.body)
  if not data or not data.volumes then return {} end

  local chapters = {}
  for _, volume in ipairs(data.volumes) do
    local volNum = tostring(volume.num or "")
    if volume.chapters then
      for _, chapter in ipairs(volume.chapters) do
        local chNum = tostring(chapter.num or "")
        local title = chapter.name or ("Chapter " .. chNum)
        local chUrl = baseUrl .. "/ranobe/" .. id .. "/" .. volNum .. "/" .. chNum
        table.insert(chapters, {
          title  = string_clean(title),
          url    = chUrl,
          volume = "Том " .. volNum
        })
      end
    end
  end

  return chapters
end

-- ── Хэш для обновлений ────────────────────────────────────────────────────────

function getChapterListHash(bookUrl)
  local id = extractId(bookUrl)
  if not id then return nil end
  local r = http_get(apiBase .. "ranobe/" .. id .. "/contents")
  if not r.success then return nil end
  local data = json_parse(r.body)
  if not data or not data.volumes then return nil end
  local volumes = data.volumes
  local lastVol = volumes[#volumes]
  if not lastVol or not lastVol.chapters then return nil end
  local lastCh = lastVol.chapters[#lastVol.chapters]
  return lastCh and tostring(lastCh.num) or nil
end

-- ── Текст главы ───────────────────────────────────────────────────────────────

function getChapterText(html, url)
  local cleaned = html_remove(html, "script", "style", ".ads-desktop", ".ads-mobile")
  local el = html_select_first(cleaned, "div.ui.text.container[data-container]")
  if el then
    local inner = html_remove(el.html, ".title-wrapper", ".chapter-hoticons")
    return applyStandardContentTransforms(html_text(inner))
  end
  return ""
end

-- ── Список фильтров ───────────────────────────────────────────────────────────

function getFilterList()
  return {
    -- Сортировка
    {
      type             = "sort",
      key              = "sort",
      label            = "Сортировка",
      defaultValue     = "computed_rating",
      defaultAscending = false,
      options = {
        { value = "computed_rating", label = "По рейтингу"           },
        { value = "last_chapter_at", label = "По дате обновления"    },
        { value = "created_at",      label = "По дате добавления"    },
        { value = "name_rus",        label = "По названию"           },
        { value = "views",           label = "По просмотрам"         },
        { value = "count_chapters",  label = "По количеству глав"    },
      }
    },

    -- Статус перевода
    {
      type         = "select",
      key          = "status",
      label        = "Статус перевода",
      defaultValue = "0",
      options = {
        { value = "0", label = "Любой"      },
        { value = "1", label = "В процессе" },
        { value = "2", label = "Завершено"  },
        { value = "3", label = "Заморожено" },
        { value = "4", label = "Неизвестно" },
      }
    },

    -- Страна происхождения (checkbox — только включить)
    {
      type  = "checkbox",
      key   = "country",
      label = "Страна",
      options = {
        { value = "1", label = "Япония" },
        { value = "2", label = "Китай"  },
        { value = "3", label = "Корея"  },
        { value = "4", label = "США"    },
      }
    },

    -- Жанры (tristate — включить / исключить)
    {
      type  = "tristate",
      key   = "tags",
      label = "Жанры",
      options = {
        { value = "22",  label = "Боевые искусства"  },
        { value = "114", label = "Гарем"             },
        { value = "7",   label = "Драма"             },
        { value = "8",   label = "Фэнтези"           },
        { value = "9",   label = "Романтика"         },
        { value = "11",  label = "Приключение"       },
        { value = "13",  label = "Научная фантастика"},
        { value = "14",  label = "Экшн"              },
        { value = "17",  label = "Комедия"           },
        { value = "18",  label = "Психология"        },
        { value = "19",  label = "Трагедия"          },
        { value = "20",  label = "Сверхъестественное"},
        { value = "21",  label = "Школьная жизнь"    },
        { value = "93",  label = "Повседневность"    },
        { value = "101", label = "Исторический"      },
        { value = "115", label = "Для взрослых"      },
        { value = "189", label = "Сёнэн"             },
        { value = "216", label = "Дзёсэй"            },
        { value = "242", label = "Сюаньхуа"          },
        { value = "364", label = "Сянься"            },
      }
    },

    -- События (tristate — объединяются с tags при отправке запроса)
    {
      type  = "tristate",
      key   = "events",
      label = "События",
      options = {
        { value = "25",  label = "Академия"              },
        { value = "116", label = "Алхимия"               },
        { value = "28",  label = "Альтернативный мир"    },
        { value = "314", label = "Апокалипсис"           },
        { value = "290", label = "Выживание"             },
        { value = "302", label = "Геймеры"               },
        { value = "266", label = "Вампиры"               },
        { value = "281", label = "Реинкарнация"          },
        { value = "88",  label = "Месть"                 },
        { value = "79",  label = "Петля времени"         },
        { value = "80",  label = "Путешествие во времени"},
        { value = "306", label = "ММОРПГ (ЛитРПГ)"       },
        { value = "313", label = "Виртуальная реальность"},
        { value = "139", label = "Переселение души"      },
        { value = "41",  label = "Дворяне"               },
        { value = "85",  label = "Навязчивая любовь"     },
        { value = "151", label = "Дарк"                  },
        { value = "42",  label = "Всемогущий ГГ"         },
        { value = "45",  label = "ГГ силён с начала"     },
        { value = "81",  label = "Из слабого в сильного" },
      }
    },
  }
end

-- ── Каталог с фильтрами ───────────────────────────────────────────────────────

function getCatalogFiltered(index, filters)
  local page = index + 1

  -- Сортировка
  local sort = filters["sort"] or "computed_rating"

  -- Статус
  local status = filters["status"] or "0"

  -- Страна (checkbox: через запятую)
  local country_inc = filters["country_included"] or {}

  -- Объединяем tags + events в tags:positive / tags:negative
  -- (паттерн ranobehub: оба типа тегов идут в один параметр API)
  local tags_inc = {}
  local tags_exc = {}
  for _, key in ipairs({"tags", "events"}) do
    local inc = filters[key .. "_included"] or {}
    local exc = filters[key .. "_excluded"] or {}
    for i = 1, #inc do tags_inc[#tags_inc + 1] = inc[i] end
    for i = 1, #exc do tags_exc[#tags_exc + 1] = exc[i] end
  end

  -- Строим URL
  local url = apiBase .. "search?page=" .. tostring(page)
              .. "&sort=" .. url_encode(sort)
              .. "&status=" .. status
              .. "&take=40"

  -- Страна
  if #country_inc > 0 then
    local parts = {}
    for i = 1, #country_inc do parts[#parts + 1] = country_inc[i] end
    url = url .. "&country=" .. table.concat(parts, ",")
  end

  -- Теги: включить
  if #tags_inc > 0 then
    url = url .. "&tags:positive=" .. table.concat(tags_inc, ",")
  end

  -- Теги: исключить
  if #tags_exc > 0 then
    url = url .. "&tags:negative=" .. table.concat(tags_exc, ",")
  end

  local r = http_get(url)
  if not r.success then return { items = {}, hasNext = false } end

  local data = json_parse(r.body)
  local items = parseResource(data)
  return { items = items, hasNext = #items > 0 }
end