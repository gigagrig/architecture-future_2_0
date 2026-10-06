# Управление инфраструктурой через CI/CD

Предварительная версия / MVP. Terraform использует Yandex Object Storage для состояния и YDB Document API для блокировок. GitHub Actions подготовлен как неактивный шаблон. Подключение к облаку, реальные plan/apply и запуск CI/CD не проверялись. TODO: пройти подготовку и проверки ниже перед активацией.

## Документы и реализация

- [Terraform с S3 backend](terraform/main.tf), [входные параметры](terraform/variables.tf), [выходы](terraform/outputs.tf).
- [Шаблон backend](backend/backend.local.hcl.example).
- [GitHub Actions workflow](workflow/terraform.yml).
- Параметры окружений: [dev](envs/dev.tfvars), [stage](envs/stage.tfvars), [prod](envs/prod.tfvars).
- [Переиспользуемый модуль ВМ](../Task1Advanced/modules/vm/).

## Устройство

Один корневой Terraform-модуль получает окружение и его параметры. Для каждого окружения выделяется собственный ключ `future-2-0/<environment>/terraform.tfstate`. Backend всегда `s3`; локальный backend не предусмотрен. Для изоляции прав рекомендуется отдельный bucket и сервисные аккаунты на среду. Разные ключи в общем bucket сами по себе не обеспечивают разграничение доступа.

Учётные данные провайдера и backend различаются: авторизованный ключ управляет ВМ, а статический S3-ключ используется для Object Storage и YDB Document API. Последнему аккаунту нужны права на оба сервиса. Блокировка защищает state при запуске из CI и локальной машины; `concurrency` дополнительно сериализует workflow по окружению, не отменяя уже работающий запуск.

Версия Terraform фиксирована на 1.11.4. Блокировка через `dynamodb_table` поддерживается этой версией, но помечена устаревающей. TODO: до обновления CLI проверить замену на совместимый механизм; не отключать блокировку ради успешного запуска. Настройка сверена с [инструкцией Yandex Cloud](https://yandex.cloud/en/docs/terraform/tutorials/terraform-state-lock), но её работа в конкретном аккаунте не подтверждена.

## Первоначальная подготовка ресурсов

TODO: администратору облака подготовить ресурсы до `terraform init`:

1. Создать непубличные buckets для state, включить версионирование и согласовать шифрование, хранение версий и восстановление. Не применять Object Lock ко всем объектам без проверки удаления блокировок.
2. Создать YDB Serverless и таблицу Document API `terraform-locks` с первичным ключом `LockID` типа String по инструкции провайдера. Обычная YDB SQL-таблица без совместимого Document API не заменяет её.
3. Выдать аккаунту backend права чтения/записи state, просмотра своего префикса bucket и операций Document API с таблицей блокировок: чтение, создание, удаление записи и описание таблицы. Конкретные IAM-роли и bucket policy нужно проверить администратору. Аккаунту ВМ выдать отдельные права на целевой каталог.
4. Подготовить существующие subnet, security groups и образ. Создать отдельные credentials для сред, подтвердить доступ runner к API.
5. Зафиксировать bucket, endpoint YDB и имя таблицы. Они не создаются основным Terraform-корнем: иначе backend зависел бы от ещё не созданной инфраструктуры.

## Настройки GitHub

Создать GitHub Environments `dev`, `stage`, `prod`. Разрешить deployment только из защищённой ветки `develop`; назначить reviewers, отключить обход защиты и самоподтверждение там, где это требуется. Protection rules настраиваются в GitHub, YAML сам их не создаёт. См. [документацию environments](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments).

| Тип | Имя | Значение |
| --- | --- | --- |
| Environment secret | `YC_SERVICE_ACCOUNT_KEY_JSON` | JSON авторизованного ключа управления ВМ |
| Environment secret | `YC_S3_ACCESS_KEY_ID` | ID статического ключа backend |
| Environment secret | `YC_S3_SECRET_ACCESS_KEY` | Секрет статического ключа backend |
| Environment variable | `YC_FOLDER_ID`, `YC_ZONE` | Целевой каталог и зона |
| Environment variable | `YC_IMAGE_ID`, `YC_SUBNET_ID` | Образ и подсеть |
| Environment variable | `YC_SECURITY_GROUP_IDS` | JSON-массив, например `["enp-example"]` |
| Environment variable | `VM_SSH_PUBLIC_KEY` | Полная строка публичного SSH-ключа |
| Environment variable | `TF_STATE_BUCKET` | Bucket этой среды |
| Environment variable | `YDB_DOCUMENT_API_ENDPOINT` | Полный HTTPS endpoint Document API |
| Environment variable | `TF_LOCK_TABLE` | `terraform-locks` или согласованное имя |
| Repository variable | `CLOUD_MVP_ENABLED` | Оставить отсутствующей/`false`; `true` только после подготовки |

TODO: заменить action tags на проверенные commit SHA перед активацией. Далее скопировать `workflow/terraform.yml` в `.github/workflows/terraform.yml` и включить файл в default branch, чтобы стал доступен `workflow_dispatch`. При запуске выбирать `develop`. Сейчас файла в `.github/workflows` нет: push не активирует workflow.

## Последовательность pipeline

1. Оператор вручную выбирает среду и `plan` (по умолчанию) либо `apply`. Job не запускается при выключенном `CLOUD_MVP_ENABLED` или другой ветке.
2. После прохождения настроенных environment protection rules runner получает секреты. Он проверяет наличие параметров, создаёт временный файл ключа с закрытыми правами, выполняет `fmt`, `init` с удалённым backend и `validate`.
3. `plan` сохраняется только на временном runner. В summary публикуются commit SHA и количество операций по типам без атрибутов ресурсов. Полные plan, state и logs не загружаются как GitHub artifacts, поскольку репозиторий публичный.
4. Только при явном выборе `apply` применяется именно бинарный plan, созданный в этом job. В конце удаляются временные файлы ключа, plan и локальный каталог backend. При сбое публикуется краткая ошибка; диагностику выполняют локально с авторизованным доступом.

Это MVP с подтверждением запуска, а не отдельным утверждением полного plan после его формирования. Предыдущий запуск `plan` не является планом следующего `apply`: он вычисляется заново. TODO перед prod: внедрить закрытое хранение plan, просмотр конкретных изменений и отдельный approval именно этого неизменного plan. До этого использовать workflow только для учебных сред. Нет триггеров push/pull_request и нет передачи облачных секретов коду из внешних PR.

## Локальная проверка без доступов

```bash
terraform fmt -check -recursive Task2Advanced
terraform -chdir=Task2Advanced/terraform init -backend=false
terraform -chdir=Task2Advanced/terraform validate
```

Эти команды не проверяют S3 и YDB. `init -backend=false` используется только для анализа конфигурации; это не разрешение переходить к локальному state при реальном запуске.

## TODO: проверка с доступами

1. Скопировать `backend/backend.local.hcl.example` в `backend/backend.local.hcl`; заполнить bucket, endpoint YDB и ключ выбранной среды. Передать `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `YC_SERVICE_ACCOUNT_KEY_FILE`, `TF_VAR_environment`, `TF_VAR_folder_id`, `TF_VAR_zone`, `TF_VAR_image_id`, `TF_VAR_subnet_id`, `TF_VAR_security_group_ids` и `TF_VAR_ssh_public_key` через окружение. Не выводить значения в logs.
2. Для новой dev-среды выполнить:

```bash
terraform -chdir=Task2Advanced/terraform init -reconfigure -backend-config=../backend/backend.local.hcl
terraform -chdir=Task2Advanced/terraform plan -var-file=../envs/dev.tfvars -out=dev.tfplan
terraform -chdir=Task2Advanced/terraform apply dev.tfplan
```

Для stage/prod изменить backend key, переменные и `.tfvars` согласованно. TODO: сверить эту тройку перед запуском. Если ВМ уже создана демонстрационной конфигурацией, нельзя создавать её повторно под новым state. Сначала остановить изменения, сделать защищённую резервную копию и согласовать перенос state с сохранением resource addresses через отдельную процедуру миграции; простой `-reconfigure` состояние не переносит. В текущем MVP таких развёртываний нет.

3. Проверить появление state в правильном bucket/key и отсутствие рабочего `terraform.tfstate` в корне. При ошибке записи backend Terraform может сохранить аварийный state локально: его нужно защищённо восстановить в backend до новых изменений, а не удалять автоматически.

   TODO до включения облачного apply в CI: реализовать и проверить защищённое сохранение аварийного state с временного runner при отказе S3. Текущий шаблон его не экспортирует, поэтому при завершении runner восстановление может потребовать импорта ресурсов. Это известное ограничение MVP; оставлять `CLOUD_MVP_ENABLED=false` до проверки восстановления.
4. В тестовой среде проверить два одновременных запуска: второй должен ждать/получить ошибку блокировки. Не использовать `-lock=false`. Освобождать блокировку принудительно можно только после подтверждения отсутствия активного процесса.
5. Проверить GitHub: `plan` не меняет ресурсы, `apply` требует явного выбора и настроенного reviewer, другая ветка и выключенный флаг блокируют запуск. Проверить, что в публичных logs и artifacts нет содержимого state, plan и секретов.
6. TODO: приложить обезличенные ссылки на успешные workflow и свидетельства проверки блокировки. Непроверенные пункты пока остаются открытыми.

## Источники

- [Состояние Terraform в Yandex Object Storage](https://yandex.cloud/en/docs/terraform/tutorials/terraform-state-storage).
- [S3 backend и параметры блокировки](https://developer.hashicorp.com/terraform/language/backend/s3).
- [GitHub Actions concurrency](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency).
