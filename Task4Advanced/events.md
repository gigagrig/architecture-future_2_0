# Каталог событий

Предварительная версия / MVP. Имена событий обозначают свершившийся факт. Команды, например «создать счёт», не публикуются под видом факта. TODO: согласовать каждый контракт и срок хранения с источником и подписчиками.

## Общий конверт

Обязательные поля для каждого события:

| Поле | Тип и смысл |
| --- | --- |
| `event_id` | UUID, неизменный при повторной доставке |
| `event_type` | Имя из каталога |
| `schema_version` | Положительное целое; major-версия контракта |
| `occurred_at` | RFC 3339 UTC, время фиксации факта |
| `source` | Идентификатор bounded context |
| `aggregate_id` | Строковый ключ агрегата в контексте, не глобальный ID человека |
| `aggregate_version` | Положительное целое для порядка изменений этого агрегата |
| `region_id` | Идентификатор разрешённого регионального контура |
| `correlation_id` | UUID процесса; аналитический проектор создаёт новый, не переносит клиническую корреляцию |
| `payload` | Объект с обязательными полями из таблицы ниже |

Время не используется как единственный критерий порядка. Ключ партиционирования — `source + aggregate_id`; consumer сверяет версию и фиксирует обработанный `event_id` вместе с локальным эффектом. Для финансового события business idempotency_key/settlement_id сохраняет защиту даже после очистки технического журнала дедупликации.

## Операционные события

Доступ закрыт по контекстам; эти payload целиком не передаются в Analytics Products. `ref` — непрозрачный локальный идентификатор, не URL общего доступа. Все перечисленные поля обязательны для версии 1; технический конверт добавляется отдельно.

| Событие | Источник → подписчики | Семантика | Минимальный payload v1 |
| --- | --- | --- | --- |
| PatientRegistered | Registry → Care, Billing | Регистрация зафиксирована | patient_ref:string, clinic_id:string, registration_status:enum(active) |
| VisitCompleted | Care → Billing, собственный проектор загрузки | Визит завершён | encounter_ref:string, billable_ref:string, clinic_id:string; без диагнозов и текстов |
| AIResearchCompleted | AI → Care | Результат сохранён в закрытом контуре | research_ref:string, study_ref:string, result_ref:string, model_version:string; result_ref доступен только Care |
| InvoiceIssued | Billing → банковский адаптер при выбранном финансировании | Счёт сформирован | invoice_ref:string, total_minor:int>0, currency:string ISO 4217 |
| LoanAgreementCreated | Banking → Billing | Договор заключён; не означает оплату | agreement_ref:string, invoice_ref:string, principal_minor:int>0, currency:string |
| PaymentSettled | Banking → Billing | Расчёт подтверждён банковским учётом | settlement_id:string, invoice_ref:string, amount_minor:int>0, currency:string |
| InvoicePaid | Billing → собственный финансовый проектор | Счёт полностью оплачен после сверки | invoice_ref:string, clinic_id:string, amount_minor:int>0, currency:string |
| StaffingCapacityChanged | Workforce → Care, собственный проектор | Пересмотрено число доступных слотов | clinic_id:string, service_date:date, available_slots:int>=0 |
| BatchReceived | Pharma → собственный проектор запасов | Партия принята | batch_ref:string, product_code:string, quantity:int>0, expires_on:date |
| DeviceAvailabilityChanged | Devices → Care, собственный проектор | Изменена доступность устройства | device_ref:string, clinic_id:string, status:enum(available,maintenance,offline) |

Подписка банковского адаптера на InvoiceIssued допускается только для явно запрошенного финансирования, после проверки разрешения и маршрута. Это не массовая отправка всех счетов клиники в банк. TODO: определить контракт команды запроса финансирования и сроки ожидания.

## Аналитические события

Источники — доменные проекторы, подписчики — соответствующие витрины Analytics Products. Они читают только разрешённые административные/финансовые данные своего домена. Каждое событие содержит полный пересчитанный срез по ключу, поэтому повторная доставка заменяет версию, а не прибавляет счётчик повторно.

| Событие | Источник | Семантика / ключ | Минимальный payload v1 |
| --- | --- | --- | --- |
| ClinicCapacityPublished | care-delivery | Загрузка клиники за день / clinic_id + period_start | clinic_id:string, period_start:date, period_end:date, available_slots:int>=0, booked_slots:int>=0 |
| FinancialSummaryPublished | clinic-billing или banking | Срез финансов по организации, дню и валюте | organization_id:string, period_start:date, currency:string, total_minor:int>=0, transaction_count:int>=0 |
| AIUsagePublished | ai-research | Техническая загрузка по модели и дню | model_version:string, period_start:date, completed_count:int>=0, processing_seconds:int>=0 |
| SupplySummaryPublished | pharma-supply | Запас по складу и категории | warehouse_id:string, category_id:string, period_start:date, available_units:int>=0 |
| DeviceAvailabilitySummaryPublished | medical-devices | Доступность по клинике, типу и дню | clinic_id:string, device_type:string, period_start:date, available_minutes:int>=0 |

Нет patient_ref, encounter_ref, study_ref, result_ref, customer_ref, текста медкарты, диагнозов или исследований, в том числе в конверте и технических logs. Маскирование таких полей не заменяет их исключения. TODO: оценить риск восстановления личности по малым группам, утвердить минимальный размер группы и подавление редких срезов; до согласования не публиковать соответствующие продукты.

Проектор Care строит загрузку по административному расписанию и доступной мощности из Workforce, не по содержимому медицинских записей. Завершение визита может инициировать пересчёт, но не определяет само по себе число забронированных слотов. Период задан полуинтервалом `[period_start, period_end)` в часовой зоне клиники; ключ среза и период должны совпадать.

## Доставка, версия и ошибки

- Новое необязательное поле совместимо только если consumers допускают его и поле разрешено политикой; обязательное поле/новый смысл требует новой major-версии и периода двойной поддержки. Пример строгой JSON Schema отклоняет любые неизвестные поля: расширение сначала согласуется и разворачивается у читателей.
- Consumers не вызывают домен-источник для каждого сообщения. Недостающие справочники поступают по отдельному контракту, необрабатываемые сообщения ограниченно повторяются и уходят в DLQ с сигналом владельцу.
- Для MVP предлагается до 5 попыток с увеличивающейся задержкой и разбросом; DLQ разбирает доменная команда. TODO: уточнить интервалы, ёмкость и сроки хранения. Ошибка авторизации или запрет поля не исправляются бесконечными retry.
- Повторная обработка берёт разрешённый архив, не создаёт новый event_id для прежнего факта. Исправление бизнес-факта публикуется отдельным событием с новой версией агрегата.
- Удаление/ограничение данных выполняется в источнике, проекциях, кэшах и архивах согласно утверждённой политике. Replay не должен возвращать исключённые записи; применяется журнал запретов перед записью результата.

## Исполнимый пример

[clinic-capacity.schema.json](contracts/clinic-capacity.schema.json) фиксирует только разрешённые поля одного аналитического события, [пример](contracts/clinic-capacity.example.json) использует вымышленные идентификаторы. JSON Schema проверяет форму, но не полномочия источника, допустимость региона, связь дат и `booked_slots <= available_slots`: эти межполевые инварианты проверяет доменный проектор. TODO: добавить их runtime-проверки и схемы остальных событий.
