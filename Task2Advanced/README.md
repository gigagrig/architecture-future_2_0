# Управление инфраструктурой через CI/CD

Terraform создаёт учебную ВМ и отдельный диск данных в Yandex Cloud. Состояние хранится в приватном Yandex Object Storage, а YDB Document API блокирует одновременные изменения. GitHub Actions проверяет код при push/PR; облачные операции запускаются вручную.

## Документы и реализация

- [Terraform с S3 backend](terraform/main.tf), [переменные](terraform/variables.tf), [выходы](terraform/outputs.tf).
- [Workflow облачного запуска](../.github/workflows/terraform.yml) и [проверки push/PR](../.github/workflows/terraform-checks.yml).
- [Запуск init/validate/plan/apply](scripts/deploy.sh), [шифрование аварийных файлов](scripts/recovery.sh).
- [Первоначальная подготовка dev](scripts/bootstrap.py), [тесты скриптов](tests/test-scripts.sh), [проверка облачного lifecycle](tests/verify-live.py).
- [Шаблон ручной конфигурации backend](backend/backend.local.hcl.example).
- Конфигурации [dev](envs/dev.tfvars), [stage](envs/stage.tfvars), [prod](envs/prod.tfvars).
- [Модуль ВМ](../Task1Advanced/modules/vm/).

## Устройство и ограничения

Версии: Terraform 1.11.4, Yandex provider 0.140.1. Блокировка через `dynamodb_table` устаревает в Terraform; версия CLI фиксирована до выбора и проверки замены. YDB используется как реализация DynamoDB-совместимого API, AWS-аккаунт не нужен.

Ключ состояния формируется скриптом из выбранного окружения: `future-2-0/<environment>/terraform.tfstate`. Имя среды одновременно определяет tfvars, имя ВМ и ключ backend. Каждому запуску выделяется собственный каталог `TF_DATA_DIR`; старые настройки другой среды не переиспользуются. Workflow сериализован по окружению, YDB обеспечивает блокировку между CI и локальными запусками.

Dev, stage и prod — учебные конфигурации. Для отдельной границы доступа каждой среде нужны собственные backend, сервисные аккаунты и GitHub Environment. Разные ключи в одном bucket предотвращают смешение состояния, но не разграничивают права. Скрипт bootstrap подготавливает только dev.

ВМ не имеет публичного IP. Группа безопасности bootstrap разрешает SSH из своей подсети и исходящий трафик. GitHub runner обращается к облачным API; SSH и доступ в частную сеть для pipeline не требуются. Для интерактивного входа нужен отдельный сетевой маршрут.

## Первоначальная подготовка dev

Нужны существующий учебный каталог, подсеть, активный биллинг и авторизованный ключ администратора этого каталога. Bootstrap используется локально; административный ключ в GitHub не передаётся.

Установить Python 3.10+, `cryptography`, `boto3` в виртуальном окружении (`pip install cryptography boto3`). Запустить сначала проверку, затем создание:

```bash
python scripts/bootstrap.py --key /secure/admin.json \
  --folder-id FOLDER_ID --subnet-id SUBNET_ID \
  --output-dir /secure/future-task2
python scripts/bootstrap.py --key /secure/admin.json \
  --folder-id FOLDER_ID --subnet-id SUBNET_ID \
  --output-dir /secure/future-task2 --apply
```

Команды выполняются из `Task2Advanced`. Скрипт создаёт:

- сервисный аккаунт deployment с `compute.editor` на учебный каталог;
- сервисный аккаунт backend с `ydb.editor` на каталог и ACL чтения/записи только своего bucket; общий `admin` аккаунтам CI не назначается;
- непубличный bucket с версионированием и лимитом 1 GiB;
- YDB Serverless без оплачиваемой резервированной мощности, с лимитом 10 RU/s, лимитом данных 1 GiB и защитой от удаления;
- таблицу Document API `terraform-locks`, первичный ключ `LockID` типа String;
- отдельную группу безопасности и SSH-ключ, выбирает актуальный Ubuntu 24.04 LTS и сохраняет его конкретный image ID.

Ресурсы с выбранным префиксом повторно используются при повторном запуске; ключи не перевыпускаются, если их файлы существуют. Выходной каталог должен быть вне репозитория. В нём сохраняются `resources.json`, `deploy-key.json`, `backend-key.json`, `github-variables.json` и SSH-ключи с закрытыми правами. Защитите каталог и сделайте его резервную копию. При неоднозначной ошибке создания ключа проверьте список ключей в IAM перед повтором.

Bucket и YDB создаются до `terraform init`, вне основного state: они не должны удаляться вместе с учебной ВМ. Не запускайте конфигурации задания 1 и задания 2 для одной ВМ одновременно под разными state.

## Ключ восстановления

На локальной машине создать отдельный GPG-каталог с правами 700 и ключ шифрования. Пример интерактивной команды:

```bash
mkdir -m 700 /secure/future-task2/recovery-gnupg
gpg --homedir /secure/future-task2/recovery-gnupg \
  --quick-generate-key future-task2-recovery rsa3072 encr 1y
gpg --homedir /secure/future-task2/recovery-gnupg --armor \
  --output /secure/future-task2/recovery-public.asc --export
```

Приватная часть остаётся у владельца. В GitHub передаётся только содержимое `recovery-public.asc`. Перед истечением срока ключа обновите публичную переменную и проверьте расшифрование. Bootstrap добавляет публичный ключ в JSON переменных, если файл уже существует рядом с остальными настройками.

## Настройки GitHub

В Settings → Environments создать `dev`. В Deployment branches and tags разрешить только `develop`. Для ручного подтверждения после выбора операции достаточно предусмотренного в workflow ввода имени среды. Required reviewers можно добавить, если есть второй участник; при запрете self-review единственный владелец не сможет подтвердить собственный запуск.

| Тип | Имя | Источник значения |
| --- | --- | --- |
| Environment secret | `YC_SERVICE_ACCOUNT_KEY_JSON` | Полное содержимое `deploy-key.json` |
| Environment secret | `YC_S3_ACCESS_KEY_ID` | Поле `access_key_id` из `backend-key.json` |
| Environment secret | `YC_S3_SECRET_ACCESS_KEY` | Поле `secret_access_key` из `backend-key.json` |
| Environment variables | `YC_FOLDER_ID`, `YC_ZONE`, `YC_IMAGE_ID`, `YC_SUBNET_ID` | Одноимённые поля `github-variables.json` |
| Environment variable | `YC_SECURITY_GROUP_IDS` | JSON-массив как строка, например `["enp..."]` |
| Environment variable | `VM_SSH_PUBLIC_KEY` | Полная строка публичного SSH-ключа |
| Environment variables | `TF_STATE_BUCKET`, `YDB_DOCUMENT_API_ENDPOINT`, `TF_LOCK_TABLE` | Одноимённые поля `github-variables.json` |
| Environment variable | `TF_RECOVERY_PUBLIC_KEY` | Полное содержимое `recovery-public.asc` |
| Repository variable | `CLOUD_MVP_ENABLED` | `true` после настройки dev; отсутствие/false блокирует облачный job |

GitHub требует файл workflow в default branch для кнопки Run workflow. При default branch `main` файл `.github/workflows/terraform.yml` должен присутствовать и в `main`. Запускать нужно из `develop`, где лежит вся реализация. Публикация только в `develop` запускает проверки push, но не гарантирует доступность ручной кнопки.

Actions закреплены по commit SHA. Workflow проверок push/PR не получает облачные секреты. Облачный workflow не имеет триггеров push/PR и использует только содержимое выбранной ветки `develop`.

## Облачный запуск

В Actions → Terraform deployment → Run workflow:

1. Выбрать ветку `develop`, environment `dev`, operation `plan`; поле confirm оставить пустым.
2. Проверить успешный init/validate/plan. В summary видны commit и число изменений по типам.
3. Для создания повторить запуск с operation `apply` и confirm `dev`.
4. Для удаления учебной ВМ и обоих дисков выбрать operation `destroy` и confirm `dev`. Bucket, YDB и ключи останутся.

Apply применяет бинарный plan, построенный в том же job. Предыдущий запуск plan не является планом следующего apply. Это ручное разрешение учебного развёртывания, не отдельное утверждение точного plan после его расчёта. Для промышленного использования необходим отдельный процесс просмотра и утверждения конкретного плана.

## Локальный запуск того же pipeline

Нужны Terraform 1.11.4, Bash, jq. Передать через окружение:

```text
YC_SERVICE_ACCOUNT_KEY_FILE
AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY
TF_VAR_folder_id
TF_VAR_zone
TF_VAR_image_id
TF_VAR_subnet_id
TF_VAR_security_group_ids
TF_VAR_ssh_public_key
STATE_BUCKET
LOCK_ENDPOINT
LOCK_TABLE
```

Ключи backend соответствуют `YC_S3_*`, остальные значения — переменным GitHub выше. `TF_VAR_environment` и пути state скрипт определяет сам. Не записывайте значения секретов в отслеживаемые env/tfvars.

Из корня репозитория:

```bash
bash Task2Advanced/scripts/deploy.sh --environment dev --operation plan
bash Task2Advanced/scripts/deploy.sh --environment dev --operation apply --confirm dev
bash Task2Advanced/scripts/deploy.sh --environment dev --operation destroy --confirm dev
```

В `./log` создаются приватные каталоги запусков (можно заменить через `--logs-dir`). Каждое обращение к Terraform имеет отдельный log, plan хранится там же. Локальные logs, plan и backend metadata не добавляются в Git. Рабочий state находится в Object Storage; локальный файл metadata в `TF_DATA_DIR` не является состоянием ресурсов.

## Сбой backend и восстановление

Перед обращением к облаку CI проверяет шифрование публичным GPG-ключом. При неуспешном запуске шифруются диагностические logs, plan и файлы `*.tfstate*`, включая `errored.tfstate`, если Terraform создал его после отказа записи backend. Приватный ключ провайдера не включается. Публичный GitHub artifact содержит только `terraform-recovery.tar.gz.gpg` и хранится семь дней.

1. Остановить новые apply/destroy; скачать artifact неуспешного run.
2. На доверенной машине расшифровать:
   `gpg --homedir /secure/future-task2/recovery-gnupg --output recovery.tar.gz --decrypt terraform-recovery.tar.gz.gpg`.
3. Распаковать в закрытый каталог, проверить log и выбрать именно `errored.tfstate`. Metadata backend под именем `terraform.tfstate` не подходит.
4. Восстановить доступ к S3/YDB и инициализировать тот же bucket/key. Сверить lineage/serial, историю версий в bucket и реально существующие ресурсы. Сделать защищённую копию удалённого состояния.
5. При подтверждённой необходимости выполнить `terraform state push /secure/errored.tfstate` с теми же переменными и `TF_DATA_DIR`, затем `terraform plan`. Не использовать `-force` или `-lock=false` для обхода ошибок.
6. Принудительно снимать блокировку можно только после проверки отсутствия активного процесса.

Если runner потерян целиком или GitHub недоступен до загрузки artifact, доставка аварийного state не гарантируется: используются последняя версия S3 и сверка/import ресурсов. Версионирование bucket не сохраняет состояние, которое Terraform не смог отправить.

## Проверки

```bash
terraform fmt -check -recursive Task1Advanced
terraform fmt -check -recursive Task2Advanced
terraform -chdir=Task2Advanced/terraform init -backend=false -lockfile=readonly
terraform -chdir=Task2Advanced/terraform validate
terraform -chdir=Task1Advanced/modules/vm test
bash Task2Advanced/tests/test-scripts.sh
```

Mock-тесты проверяют модуль без облака. Тесты скриптов проверяют отказ неподтверждённого apply, отсутствие apply в plan, разделение backend по средам, destroy, ошибку записи state и расшифрование аварийного архива. Для проверки реального backend нужны init/plan/apply, чтение объекта состояния и проверка занятой блокировки через YDB. Эти проверки не заменяются разбором YAML.

Для отдельной проверки dev без GitHub из корня репозитория:

```bash
python Task2Advanced/tests/verify-live.py --config-dir /secure/future-task2
python Task2Advanced/tests/verify-live.py --config-dir /secure/future-task2 --lifecycle
```

Первая команда выполняет только init/plan. Вторая требует пустого dev-state, создаёт платную ВМ, проверяет параметры и state, отсутствие изменений при повторном plan, занятую блокировку и изоляцию stage-plan. После успешного apply она удаляет учебные ресурсы, даже если последующая проверка не прошла. При ошибке самого apply автоматическое удаление не выполняется: сначала нужно проверить частично созданные ресурсы и сохранность state. Значения stage при этой проверке используют тестовый backend dev только для демонстрации разных ключей; отдельная среда требует своих доступов.

## Источники

- [Состояние в Object Storage](https://yandex.cloud/ru/docs/terraform/tutorials/terraform-state-storage).
- [Блокировки через YDB](https://yandex.cloud/ru/docs/terraform/tutorials/terraform-state-lock).
- [GitHub Environments](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments).
