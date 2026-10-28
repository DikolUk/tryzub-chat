# VARTA — Захищена платформа комунікацій для закритих спільнот

[![Go Version](https://img.shields.io/badge/Go-1.22%2B-blue)](https://golang.org)
[![Security](https://img.shields.io/badge/E2EE-Double%20Ratchet%20%2F%20X3DH-gold)](https://signal.org)
[![Architecture](https://img.shields.io/badge/Deployment-Docker%20Compose-green)](https://docker.com)

## Архітектура та можливості

- **Zero-Knowledge Backend:** Сервер ніколи не отримує приватних ключів користувачів і не має доступу до відкритого вмісту.
- **Реєстрація за одноразовими інвайтами:** Без номера телефону та без обов'язкової електронної пошти.
- **Store-and-Forward Mailbox:** Надійна черга зашифрованих пакетів для пристроїв офлайн із підтвердженням доставки (`ack`).
- **Вбудована CMS-панель:** Вебінтерфейс для керування інвайтами, ролями, сесіями та перегляду журналу безпеки.
- **Multi-Device E2EE:** Облік публічних ключів (Identity Key, Signed PreKey, One-Time PreKeys) для кожного пристрою окремо.

## Швидкий старт через Docker Compose

```bash
# 1. Скопіювати змінні середовища
cp .env.example .env

# 2. Запустити стек (PostgreSQL + Varta Core)
docker compose up -d --build

# 3. Перевірити логи
docker compose logs -f varta-server
```

## API Ендпоінти

| Метод | Ендпоінт | Опис |
| :--- | :--- | :--- |
| `GET` | `/api/v1/health` | Стан сервера та версія протоколу |
| `POST` | `/api/v1/auth/invite/check` | Перевірка дійсності інвайту |
| `POST` | `/api/v1/auth/register` | Реєстрація з прив'язкою ключів пристрою |
| `POST` | `/api/v1/auth/login` | Авторизація та отримання сесії |
| `GET` | `/api/v1/keys/{userId}` | Отримання PreKeyBundle для старту X3DH E2EE |
| `GET` | `/ws?token={token}` | WebSocket хаб реального часу для E2EE повідомлень |
| `GET` | `/admin` | Вебпанель керування безпекою |
