# Виртуальные машины для dev, stage и prod

Предварительная версия / MVP. Облако: Yandex Cloud. Модуль создаёт ВМ с загрузочным и отдельным диском данных, подключая её к существующей подсети. Реальное развёртывание и SSH-подключение пока не проверены.

## Документы и реализация

- [Модуль vm_module: ресурсы](modules/vm/main.tf), [параметры](modules/vm/variables.tf), [выходы](modules/vm/outputs.tf), [версии](modules/vm/versions.tf).
- Конфигурации окружений: [dev](envs/dev/), [stage](envs/stage/), [prod](envs/prod/).
- [Локальные mock-тесты](modules/vm/tests/vm.tftest.hcl).

## Границы модуля

Внутри `modules/vm/` нет имён окружений, конкретных идентификаторов облака и учётных данных. Корневые конфигурации задают имя ВМ, метки и параметры. Сетью и подсетями управляет владелец инфраструктуры; модуль получает Subnet ID и создаёт сетевой интерфейс ВМ. Подсеть и диски должны находиться в одной зоне. Явный список security groups обязателен.

Публичный IP отключён. SSH доступен по частному адресу через согласованный VPN или bastion; правила существующей security group должны разрешать SSH только из этой сети. Cloud-init создаёт пользователя с публичным SSH-ключом и отключённым паролем. Сервисный аккаунт управления Terraform не прикрепляется к самой ВМ.

Диск данных подключается как `data`, но не форматируется и не монтируется: это исключает автоматическую потерю существующих данных при повторном применении. `auto_delete = false` сохраняет его при удалении только ВМ; полный `terraform destroy` удалит и отдельный ресурс диска. В MVP нет резервных копий и защиты от полного удаления. Изменение ресурсов может остановить ВМ.

## Интерфейс

Все параметры, кроме отмеченных defaults, обязательны.

| Параметр | Тип | Назначение |
| --- | --- | --- |
| `name` | string | Имя ВМ и префикс диска |
| `folder_id`, `zone` | string | Каталог и зона |
| `image_id`, `platform_id` | string | Фиксированный образ ОС и платформа |
| `cores`, `memory_gb` | number | vCPU и RAM в GB |
| `boot_disk_gb`, `data_disk_gb` | number | Размеры дисков в GB |
| `disk_type` | string | `network-hdd` или `network-ssd` |
| `subnet_id` | string | Существующая подсеть |
| `security_group_ids` | list(string) | Непустой список групп безопасности |
| `ssh_user`, `ssh_public_key` | string | Linux-пользователь и публичный ключ |
| `assign_public_ip` | bool | Публичный адрес, default `false` |
| `labels` | map(string) | Метки, default `{}` |

Выходы: `id`, `name`, `private_ip`, `public_ip` (`null` без публичного адреса), `data_disk_id`. Корневые конфигурации объединяют их в output `vm`.

| Окружение | vCPU | RAM, GB | Boot, GB | Data, GB |
| --- | ---: | ---: | ---: | ---: |
| dev | 2 | 4 | 20 | 20 |
| stage | 4 | 8 | 20 | 50 |
| prod | 8 | 16 | 20 | 100 |

Размеры учебные, предварительные. Название prod не означает готовность к промышленной эксплуатации. TODO: проверить допустимые сочетания CPU/RAM, размеры образа и квоты в выбранной зоне.

## Локальная проверка без облака

Базовая версия CLI: Terraform 1.11.4; провайдер: `yandex-cloud/yandex` 0.140.1. Это воспроизводимая стартовая комбинация, а не утверждение о последних версиях. TODO: перед реальным запуском оценить обновление и повторить проверку совместимости.

Из корня репозитория:

```bash
terraform fmt -check -recursive Task1Advanced
terraform -chdir=Task1Advanced/modules/vm init -backend=false
terraform -chdir=Task1Advanced/modules/vm validate
terraform -chdir=Task1Advanced/modules/vm test
terraform -chdir=Task1Advanced/envs/dev init -backend=false
terraform -chdir=Task1Advanced/envs/dev validate
```

Повторить две последние команды для stage и prod. `init -backend=false` загружает публичный провайдер, но не обращается к облачному backend. В тестах используется `mock_provider`: команда `apply` внутри теста создаёт только имитацию ресурсов. Проверяются параметры ВМ, подключение диска, отсутствие публичного IP и отклонение некорректных входов. Это не проверяет облачные квоты, реальные ключи, cloud-init или сетевую доступность.

## Будущий запуск с доступами

TODO: выполнить этот раздел после подготовки доступов; сейчас команды `plan/apply/destroy` с реальным провайдером не запускались.

1. Подготовить сервисный аккаунт, каталог, подсеть, группы безопасности и образ с cloud-init; выдать аккаунту права на управление ВМ и дисками, использование подсети и групп.
2. Для каждой среды скопировать `site.auto.tfvars.example` в `site.auto.tfvars` и заменить все `REPLACE_ME`. Файл исключён из Git. Настроить `YC_SERVICE_ACCOUNT_KEY_FILE` как путь к авторизованному ключу вне репозитория.
3. Передать публичный ключ через `TF_VAR_ssh_public_key`. Приватный ключ нужен только для последующего SSH, Terraform его не получает.
4. Запустить команды для выбранной среды. Пример для dev:

```bash
export YC_SERVICE_ACCOUNT_KEY_FILE=/secure/path/service-account.json
export TF_VAR_ssh_public_key="$(cat ~/.ssh/id_ed25519.pub)"
terraform -chdir=Task1Advanced/envs/dev init
terraform -chdir=Task1Advanced/envs/dev plan -var-file=dev.tfvars
terraform -chdir=Task1Advanced/envs/dev apply -var-file=dev.tfvars
terraform -chdir=Task1Advanced/envs/dev output vm
```

Для stage использовать каталог `envs/stage` и `-var-file=stage.tfvars`, для prod — `envs/prod` и `-var-file=prod.tfvars`. Эти корни независимы и используют локальное состояние; до совместной работы требуется настроить удалённый backend. Состояние и секреты не должны попадать в Git.

5. TODO: подтвердить в консоли параметры ВМ и оба диска, проверить SSH, после согласования отформатировать и смонтировать пустой диск. Сохранить обезличенные результаты в README. Не заявлять об успешной проверке только на основании mock-тестов.
6. После проверки учебной среды удалить её ресурсы командой `terraform -chdir=Task1Advanced/envs/dev destroy -var-file=dev.tfvars` (для других сред заменить путь и файл). Перед удалением проверить, что на диске нет нужных данных.

## TODO перед промышленным использованием

- Разделить каталоги и права сред, согласовать сетевые правила и резервное копирование.
- Проверить воспроизводимость запуска в каждой среде и поведение при изменении CPU/RAM.
- Определить политику обновления ОС, шифрования и восстановления дисков.

## Источники

- [Yandex Compute Instance: схема провайдера 0.140.1](https://github.com/yandex-cloud/terraform-provider-yandex/blob/v0.140.1/docs/resources/compute_instance.md).
- [Yandex Compute Disk](https://yandex.cloud/en/docs/terraform/resources/compute_disk).
- [Аутентификация Terraform в Yandex Cloud](https://yandex.cloud/en/docs/terraform/authentication).
