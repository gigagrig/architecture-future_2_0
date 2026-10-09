# Домены и событийные интеграции

Модель Domain-Driven Design (DDD) определяет границы доменов, владельцев бизнес-правил, агрегаты и контракты событий.

## Документы и реализация

- [Границы bounded contexts и отношения](bounded-contexts.md), [схема](diagrams/bounded-contexts.svg), [Mermaid](bounded-contexts.mmd).
- [Событийные сценарии](event-storming.md), [схема](diagrams/event-storming.svg), [Mermaid](event-storming.mmd).
- [Агрегаты: ключи, границы, инварианты](aggregates.md).
- [Каталог и минимальные контракты событий](events.md).
- [Обоснование событийного подхода](justification.md).
- Пример исполнимого контракта: [JSON Schema агрегированной загрузки клиники](contracts/clinic-capacity.schema.json), [синтетическое событие](contracts/clinic-capacity.example.json).

![Границы доменов](diagrams/bounded-contexts.svg)

![Команды, агрегаты, события и реакции](diagrams/event-storming.svg)

## Генерация схем

Схемы экспортируются Mermaid CLI 11.4.2 с [конфигурацией](mermaid-config.json). Из корня проекта:

```bash
mmdc -i Task4Advanced/bounded-contexts.mmd -o Task4Advanced/diagrams/bounded-contexts.svg -c Task4Advanced/mermaid-config.json -b white
mmdc -i Task4Advanced/event-storming.mmd -o Task4Advanced/diagrams/event-storming.svg -c Task4Advanced/mermaid-config.json -b white
```

