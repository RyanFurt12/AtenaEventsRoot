# AtenaEvents

Aplicação full-stack de gestão de eventos.

- **`AtenaEventsAPI/`** — API REST em Spring Boot 4 (Java 17) · [README](AtenaEventsAPI/README.md)
- **`AtenaEvents-web/`** — SPA em React 19 + Vite, servida por Nginx · [README](AtenaEvents-web/README.md)
- **PostgreSQL 16** — banco de dados
- **MailHog** — servidor SMTP de desenvolvimento (apenas em dev)

Toda a orquestração é feita via Docker Compose. **Não é necessário instalar Java, Node ou Postgres na máquina** — apenas Docker.

> Este repositório raiz contém a orquestração (Compose, `.env`, migração). Cada sub-projeto tem seu próprio README com instruções de execução isolada. Para rodar o sistema completo, use o Docker Compose daqui (seção 4).

---

## 1. Pré-requisitos

- [Docker](https://docs.docker.com/get-docker/) (com Docker Compose v2+)
- Portas livres (em dev): `3000` (web), `8080` (API), `8025` (MailHog)

---

## 2. Como os arquivos de configuração funcionam

| Arquivo | Papel |
|---|---|
| `docker-compose.yml` | Base — define todos os serviços. É a configuração de **produção**. |
| `docker-compose.override.yml` | **Dev** — aplicado **automaticamente** pelo `docker compose`. Expõe as portas no host, recria a rede `caddy_net` como rede local e sobe o MailHog. |
| `.env` | **Lido automaticamente** pelo Compose. É onde ficam todas as variáveis. **Você precisa criar este arquivo.** |
| `.env.example` | Template documentado. Copie para `.env` e preencha. |
| `db-init.sql` | Migração idempotente rodada pelo serviço `db-migrate` a cada subida. |

> O Compose aplica o `override` automaticamente quando ele existe. Por isso, **dev é o comportamento padrão** e **produção exige passar `-f docker-compose.yml` explicitamente** para ignorar o override (ver seção 5).

---

## 3. Variáveis de ambiente (`.env`)

Crie o `.env` a partir do template:

```bash
cp .env.example .env
```

| Variável | Descrição | Valor em DEV | Valor em PROD |
|---|---|---|---|
| `POSTGRES_DB` | Nome do banco | `atena_events` | `atena_events` |
| `POSTGRES_USER` | Usuário do banco | `atena` | `atena` |
| `POSTGRES_PASSWORD` | Senha do banco | qualquer | **senha forte** |
| `SPRING_PROFILES_ACTIVE` | Profile do Spring | `prod` | `prod` |
| `JWT_SECRET` | Chave de assinatura JWT (mín. 32 chars) | qualquer ≥32 | **gere uma forte** |
| `API_URL` | URL pública da API | `http://localhost:8080` | `https://api.seu-dominio.com` |
| `FRONTEND_URL` | URL pública do frontend | `http://localhost:3000` | `https://app.seu-dominio.com` |
| `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` | Credenciais OAuth Google | — | — |
| `GITHUB_CLIENT_ID` / `GITHUB_CLIENT_SECRET` | Credenciais OAuth GitHub | — | — |
| `MAIL_HOST` | Host SMTP | *(ignorado — override usa MailHog)* | host do seu SMTP |
| `MAIL_PORT` | Porta SMTP | *(override = 1025)* | `587` (padrão) |
| `MAIL_USERNAME` | Usuário SMTP | *(vazio)* | usuário do SMTP |
| `MAIL_PASSWORD` | Senha SMTP | *(vazio)* | senha do SMTP |
| `MAIL_SMTP_AUTH` | Exige autenticação SMTP | *(override = `false`)* | `true` |
| `MAIL_SMTP_STARTTLS` | Usa STARTTLS | *(override = `false`)* | `true` |
| `MAIL_FROM` | Remetente dos emails | opcional | `no-reply@seu-dominio.com` |

> **Gerar um `JWT_SECRET` forte:** `openssl rand -base64 48`

> ⚠️ **`API_URL` é embutida no bundle do frontend em tempo de build** (build arg `VITE_API_URL`). Se você mudar `API_URL`, **rebuilde a imagem web** (`--build`).

---

## 4. Rodar em desenvolvimento

O comando padrão já usa o `override` (portas expostas + MailHog):

```bash
docker compose up --build
```

Acesse:

| Serviço | URL |
|---|---|
| Frontend | http://localhost:3000 |
| API | http://localhost:8080 |
| Swagger (docs da API) | http://localhost:8080/swagger-ui/index.html |
| **MailHog** (caixa de emails de teste) | http://localhost:8025 |

Em dev **não é preciso configurar SMTP**: todos os emails (recuperação de senha, confirmação de troca de email) são capturados pelo MailHog e visíveis na UI em `:8025`. Nenhum email real é enviado.

Parar tudo: `docker compose down` (adicione `-v` para apagar o volume do banco).

---

## 5. Rodar em produção

Em produção você **não** quer o override (não expõe portas no host, usa SMTP real e a rede externa do Caddy). Passe o arquivo base explicitamente:

```bash
docker compose -f docker-compose.yml up -d --build
```

Diferenças de produção:

### 5.1. SMTP real (obrigatório para recuperação de senha)
Defina no `.env` as variáveis `MAIL_*` apontando para um SMTP de verdade (Gmail, SendGrid, Amazon SES, etc.). Exemplo para Gmail com *app password*:

```dotenv
MAIL_HOST=smtp.gmail.com
MAIL_PORT=587
MAIL_USERNAME=sua-conta@gmail.com
MAIL_PASSWORD=sua-app-password
MAIL_SMTP_AUTH=true
MAIL_SMTP_STARTTLS=true
MAIL_FROM=no-reply@seu-dominio.com
```

> O código não muda entre dev e prod — apenas as variáveis. O MailHog **não** sobe em produção (ele existe só no override).

### 5.2. URLs e HTTPS
Use domínios reais em `API_URL` e `FRONTEND_URL` (com `https://`). Eles são usados para CORS, redirects de OAuth e para montar os links dos emails.

### 5.3. Reverse proxy (Caddy)
No base, os serviços `api` e `web` **não expõem portas no host** — eles ficam atrás de um reverse proxy na rede externa `caddy_net`. Antes de subir:

```bash
docker network create caddy_net
```

Tenha um container Caddy conectado a essa rede, com um `Caddyfile` parecido com:

```caddyfile
app.seu-dominio.com {
    reverse_proxy web:80
}

api.seu-dominio.com {
    reverse_proxy api:8080
}
```

O Caddy cuida do HTTPS automaticamente (Let's Encrypt). A API já está configurada para confiar nos headers `X-Forwarded-*` do proxy (`server.forward-headers-strategy=framework`).

---

## 6. Configurar OAuth2 (Google e GitHub)

Necessário tanto em dev quanto em prod para o login social. Em cada console, cadastre as **Redirect URIs** abaixo (trocando `{API_URL}` pelo valor do seu `.env`):

| Provedor | Redirect URI a autorizar |
|---|---|
| Google | `{API_URL}/login/oauth2/code/google` |
| GitHub | `{API_URL}/login/oauth2/code/github` |

- **Google:** [Google Cloud Console](https://console.cloud.google.com/apis/credentials) → criar credencial OAuth 2.0 → copiar Client ID/Secret para o `.env`.
- **GitHub:** Settings → Developer settings → OAuth Apps → copiar Client ID/Secret.

> Se não preencher as credenciais OAuth, a aplicação **sobe normalmente** (login por email/senha continua funcionando); apenas os botões de login social não funcionarão.

---

## 7. Banco de dados e migração

- O schema é gerenciado pelo Hibernate (`ddl-auto=update`) — as tabelas são criadas/atualizadas automaticamente.
- O serviço `db-migrate` roda `db-init.sql` a cada subida (idempotente): ele remove o `NOT NULL` das colunas `email`/`password` em `users` (necessário para contas de convidado e OAuth).
- Os dados persistem no volume Docker `postgres_data`. Para zerar o banco: `docker compose down -v`.

---

## 8. Comandos úteis

```bash
# Dev — subir com rebuild
docker compose up --build

# Dev — logs da API
docker compose logs -f api

# Produção — subir em background sem o override
docker compose -f docker-compose.yml up -d --build

# Parar (mantém o banco)
docker compose down

# Parar e apagar o banco
docker compose down -v
```

### Builds locais (sem Docker — apenas para checagem, não para rodar)
```bash
# Backend — gerar o JAR
cd AtenaEventsAPI && ./mvnw package -DskipTests

# Frontend — lint
cd AtenaEvents-web && npm run lint
```

---

## 9. Funcionalidades de conta (senha e email)

- **Login/cadastro** por email+senha, ou via Google/GitHub (OAuth), ou como **convidado**.
- **Trocar senha** (logado): `/home/settings` → *Privacidade e Segurança*. Exige a senha atual.
- **Recuperar senha:** link *"Esqueceu a senha?"* na tela de login → email com link de redefinição.
- **Trocar email:** em *Privacidade e Segurança*. Exige a senha atual **e** confirmação por um link enviado ao novo endereço (o email só muda após confirmar).

> Em dev, abra os emails no MailHog (http://localhost:8025) e clique nos links de lá.
