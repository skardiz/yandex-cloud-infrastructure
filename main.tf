# Блок для настройки Terraform
terraform {
  required_providers {
    yandex = {
      source  = "yandex-cloud/yandex"
      version = "0.123.0"
    }
  }
}

# Блок для настройки провайдера
provider "yandex" {
  zone      = "ru-central1-a"
  folder_id = "b1gnlpjp9528dbc7kpug"
  service_account_key_file = "key.json"
}

# 1. Создаем виртуальную сеть (VPC)
resource "yandex_vpc_network" "app_network" {
  name = "app-network"
}

# 2. Создаем подсеть
resource "yandex_vpc_subnet" "app_subnet" {
  name           = "app-subnet-a"
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.app_network.id
  v4_cidr_blocks = ["192.168.10.0/24"]
}

# 3. Создаем группу безопасности (облачный файрвол)
resource "yandex_vpc_security_group" "k8s_sg" {
  name       = "k8s-security-group"
  network_id = yandex_vpc_network.app_network.id

  # Правило, разрешающее весь трафик внутри этой группы безопасности.
  ingress {
    protocol          = "ANY"
    description       = "Правило для внутрикластерного взаимодействия"
    predefined_target = "self_security_group"
    from_port         = 0
    to_port           = 65535
  }

  # Правило, разрешающее балансировщику проверять здоровье узлов.
  ingress {
    protocol          = "TCP"
    description       = "Правило для проверок здоровья от балансировщика"
    predefined_target = "loadbalancer_healthchecks"
  }

  # Правило для доступа к API Kubernetes извне
  ingress {
    protocol       = "TCP"
    description    = "Правило для kubectl"
    v4_cidr_blocks = ["0.0.0.0/0"]
    port           = 443
  }

  # Дополнительное правило для доступа к API Kubernetes извне
  ingress {
    protocol       = "TCP"
    description    = "Правило для kubectl"
    v4_cidr_blocks = ["0.0.0.0/0"]
    port           = 9443
  }

  # Правило для доступа по SSH
  ingress {
    protocol       = "TCP"
    description    = "Правило для доступа по SSH"
    v4_cidr_blocks = ["0.0.0.0/0"]
    port           = 22
  }

  # Правило для сервисов Kubernetes (NodePort)
  ingress {
    protocol       = "TCP"
    description    = "Правило для сервисов Kubernetes (NodePort)"
    v4_cidr_blocks = ["0.0.0.0/0"]
    from_port      = 30000
    to_port        = 32767
  }

  egress {
    protocol       = "ANY"
    description    = "Разрешаем любой исходящий трафик"
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}

# 4. Создаем кластер Kubernetes
resource "yandex_kubernetes_cluster" "app_cluster" {
  name       = "my-app-cluster"
  network_id = yandex_vpc_network.app_network.id
  master {
    zonal {
      zone      = yandex_vpc_subnet.app_subnet.zone
      subnet_id = yandex_vpc_subnet.app_subnet.id
    }
    public_ip = true
    version   = "1.29"
    # ИСПРАВЛЕНО: Привязываем нашу группу безопасности к мастер-ноде
    security_group_ids = [yandex_vpc_security_group.k8s_sg.id]
  }
  service_account_id      = "ajecem1j4lrvfmjkrg72"
  node_service_account_id = "ajecem1j4lrvfmjkrg72"
}

# 5. Создаем группу узлов (Node Group) для нашего кластера
resource "yandex_kubernetes_node_group" "app_node_group" {
  name       = "my-app-node-group"
  cluster_id = yandex_kubernetes_cluster.app_cluster.id
  version    = "1.29"
  instance_template {
    platform_id = "standard-v3"
    boot_disk {
      type = "network-hdd"
      size = 32
    }
    resources {
      memory = 2
      cores  = 2
    }
    container_runtime {
      type = "containerd"
    }
    network_interface {
      subnet_ids         = [yandex_vpc_subnet.app_subnet.id]
      security_group_ids = [yandex_vpc_security_group.k8s_sg.id]
      nat                = true
    }
    metadata = {
      ssh-keys = "ubuntu:${file("~/.ssh/ansible_vps.pub")}"
    }
  }
  scale_policy {
    fixed_scale {
      size = 1
    }
  }
}

# Выводим адреса
output "kubernetes_cluster_endpoint" {
  value       = yandex_kubernetes_cluster.app_cluster.master[0].external_v4_endpoint
  description = "Внешний адрес API нашего Kubernetes кластера"
}

output "kubernetes_cluster_id" {
  value       = yandex_kubernetes_cluster.app_cluster.id
  description = "Уникальный ID нашего Kubernetes кластера"
}
