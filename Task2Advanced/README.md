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
- [Создание ключей Yandex Cloud](#создание-ключей-yandex-cloud) и [добавление Secrets/Variables в GitHub](#настройки-github).

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

## Создание ключей Yandex Cloud

Для pipeline нужны **два ключа**, из которых получаются **три GitHub Secret**:

- Авторизованный ключ deployment-аккаунта — JSON-файл целиком. Провайдер Terraform использует его для доступа к Compute Cloud.
- Статический ключ backend-аккаунта — пара access key ID / secret access key. Она используется для Object Storage и YDB Document API; это не ключ AWS-аккаунта.

API-ключ, временный IAM-токен и SSH-ключ не заменяют эти ключи. Создавать собственные роли не требуется: используются встроенные роли и ACL, перечисленные в разделе первоначальной подготовки.

### Вариант 1: использовать файлы bootstrap

Если bootstrap уже выполнен, новые ключи создавать не нужно. Откройте его выходной каталог вне репозитория — например, `~/.config/yandex-cloud/future-task2` (в примерах выше `/secure/future-task2` обозначает этот же выбранный вами каталог):

| Локальный файл | Что использовать |
| --- | --- |
| `deploy-key.json` | Весь JSON, от первой `{` до последней `}` |
| `backend-key.json` | Значения полей `access_key_id` и `secret_access_key` отдельно |
| `github-variables.json` | Несекретные настройки окружения |
| `recovery-public.asc` | Публичный ключ аварийного восстановления |

Открывайте файлы локальным редактором, а не публикуйте их в чат, issue или лог. Поле `id` в `backend-key.json` — идентификатор записи IAM, **не** значение для `YC_S3_ACCESS_KEY_ID`.

Для нового каталога используйте команды bootstrap из предыдущего раздела. Ключ из аргумента `--key` — административный, только для первоначальной настройки; его нельзя подставлять вместо `deploy-key.json` в CI. При отсутствии административного ключа владелец учебного каталога может создать его через процедуру авторизованного ключа ниже для отдельного bootstrap-аккаунта с правами администратора только этого каталога. Не назначайте такие права deployment-аккаунту.

### Вариант 2: создать ключи вручную в консоли

Этот вариант подходит для существующих сервисных аккаунтов с настроенными правами. При стандартном префиксе bootstrap их имена — `future-tf-dev-deploy` и `future-tf-dev-backend`. Для нового проекта сначала выполните первоначальную подготовку: выпуск ключей сам по себе не создаёт bucket, YDB, таблицу блокировок и сеть.

Авторизованный ключ:

1. В [консоли Yandex Cloud](https://console.yandex.cloud/) выберите целевой каталог → Identity and Access Management → Сервисные аккаунты.
2. Откройте `future-tf-dev-deploy` → Создать новый ключ → Создать авторизованный ключ.
3. Выберите RSA-2048, укажите понятное описание, например `GitHub Actions dev`, и создайте ключ.
4. Нажмите «Скачать файл с ключами». Сохраните JSON вне репозитория как `deploy-key.json`; при замене не перезаписывайте единственную резервную копию старого ключа.

Закрытая часть выдаётся только при создании; если файл утрачен, потребуется новый ключ. [Инструкция Yandex Cloud](https://yandex.cloud/ru/docs/iam/operations/authentication/manage-authorized-keys).

Статический ключ:

1. В том же каталоге откройте `future-tf-dev-backend`.
2. Нажмите Создать новый ключ → Создать статический ключ доступа, добавьте описание и создайте ключ.
3. Сразу сохраните идентификатор ключа доступа и секретный ключ в защищённом хранилище. Секретное значение повторно получить нельзя.
4. Используйте идентификатор как `YC_S3_ACCESS_KEY_ID`, а секретный ключ как `YC_S3_SECRET_ACCESS_KEY`. Не путайте идентификатор ключа доступа с ID сервисного аккаунта.

Эту пару можно перенести непосредственно в GitHub через форму ниже. Для локальных скриптов формат `backend-key.json` должен совпадать с bootstrap: `access_key_id`, `secret_access_key` и `id` записи ключа IAM. [Инструкция Yandex Cloud](https://yandex.cloud/ru/docs/iam/operations/authentication/manage-access-keys).

Храните локальные ключи в каталоге с правами `700`, файлы — `600`; резервную копию — в зашифрованном хранилище. При плановой ротации создайте новый ключ, обновите GitHub и локальную конфигурацию, проверьте `plan`, затем отзовите старый ключ в IAM. При утечке отзывайте скомпрометированный ключ сразу: удаления файла из Git недостаточно.

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

### 1. Создать окружение dev

Нужны права владельца личного репозитория или администратора репозитория организации.

1. Откройте репозиторий → Settings → Environments → New environment. Для этого проекта: [настройки окружений](https://github.com/gigagrig/architecture-future_2_0/settings/environments).
2. Введите `dev` → Configure environment. Если оно уже существует, откройте его.
3. В Deployment branches and tags выберите Selected branches and tags → Add deployment branch or tag rule → тип Branch, шаблон `develop` → Add rule.

Required reviewers можно добавить, если есть второй участник; при запрете self-review единственный владелец не сможет подтвердить собственный запуск. [Настройка окружений GitHub](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments).

### 2. Добавить три секрета

Внутри `dev` найдите Environment secrets. Для каждого из первых трёх пунктов таблицы нажмите Add secret, укажите точное имя в Name, вставьте значение в Secret и сохраните. Это **секреты окружения dev**, не Codespaces/Dependabot и не обычные Variables. [Инструкция GitHub Secrets](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-secrets?tool=webui).

Для `YC_SERVICE_ACCOUNT_KEY_JSON` вставьте весь JSON без Markdown-ограждений и без преобразования в Base64. Путь к файлу вместо его содержимого не подходит. Не изменяйте экранирование `\n` внутри JSON. Для двух `YC_S3_*` вставляйте только соответствующее строковое значение, без имени поля, окружающих кавычек, запятых или пробелов по краям.

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

После сохранения проверьте наличие трёх имён в Environment secrets. GitHub не показывает сохранённое значение для повторного чтения; если ошиблись, замените его через редактирование секрета. Не добавляйте в workflow вывод секретов для диагностики.

### 3. Добавить несекретные переменные

На странице `dev` в Environment variables используйте Add variable для каждого имени из таблицы. Файл `github-variables.json` не загружается одним секретом: каждое поле становится отдельной переменной Name / Value. Копируйте значения строк без внешних JSON-кавычек и с декодированным экранированием. Например, `YC_SECURITY_GROUP_IDS` должно выглядеть как `["enp..."]`, а не `[\"enp...\"]`.

`TF_RECOVERY_PUBLIC_KEY` добавьте отдельно из `recovery-public.asc`, если его ещё нет в JSON: весь текст, включая строки `-----BEGIN PGP PUBLIC KEY BLOCK-----` и `-----END PGP PUBLIC KEY BLOCK-----`, с настоящими переносами строк. Без него workflow остановится до обращения к облаку. Приватный GPG-ключ, приватный SSH-ключ и административный ключ в GitHub не передаются. `VM_SSH_PUBLIC_KEY` содержит только публичную строку `ssh-ed25519 ...`.

### 4. Разрешить запуск и проверить доступ

Откройте Settings → Secrets and variables → Actions → Variables → New repository variable. Создайте `CLOUD_MVP_ENABLED` со значением `true` без кавычек. Для этого проекта: [переменные репозитория](https://github.com/gigagrig/architecture-future_2_0/settings/variables/actions). Эта переменная нужна именно на уровне **repository**, поскольку условие job проверяется до загрузки окружения `dev`.

GitHub требует файл workflow в default branch для кнопки Run workflow. При default branch `main` файл `.github/workflows/terraform.yml` должен присутствовать и в `main`. Запускать нужно из `develop`, где лежит вся реализация. Публикация только в `develop` запускает проверки push, но не гарантирует доступность ручной кнопки.

Actions закреплены по commit SHA. Workflow проверок push/PR не получает облачные секреты. Облачный workflow не имеет триггеров push/PR и использует только содержимое выбранной ветки `develop`.

Выполните сначала `plan` по инструкции ниже. Зелёный `Terraform checks` проверяет код, но не наличие секретов и не доступ к облаку. Если cloud job пропущен, проверьте ветку и `CLOUD_MVP_ENABLED`; если preflight завершился ошибкой — подтверждение операции и recovery-ключ. При ошибке аутентификации проверьте имена секретов, формат значений и принадлежность ключей нужным аккаунтам; при отказе доступа — их роли и ACL. Успешный `plan` не доказывает возможность создания ресурсов: квоты и ограничения Compute Cloud проверяются при `apply`.

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
