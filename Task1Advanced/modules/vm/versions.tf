terraform {
  required_version = ">= 1.11.4, < 2.0.0"
  required_providers {
    yandex = {
      source  = "yandex-cloud/yandex"
      version = "0.140.1"
    }
  }
}
