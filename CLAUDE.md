# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

AtenaEvents is a full-stack event management application with two sub-projects:
- `AtenaEventsAPI/` — Spring Boot 4 REST API (Java 17)
- `AtenaEvents-web/` — React 19 + Vite SPA

Infrastructure is orchestrated via `docker-compose.yml` at the root, which spins up PostgreSQL 16, the Spring Boot API, and the Nginx-served frontend.

## Development Commands

### Always test with Docker

```bash
# Build and start everything (use this for ALL testing)
docker compose up --build

# Frontend → http://localhost:3000
# API      → http://localhost:8080
```

Never use `./mvnw spring-boot:run` or `npm run dev` for testing. Always use `docker compose up --build` from project root.

### Other commands (build only, not for testing)

```bash
# Backend — build JAR only
cd AtenaEventsAPI && ./mvnw package -DskipTests

# Frontend — lint check
cd AtenaEvents-web && npm run lint
```

The API runs on `http://localhost:8080`. Swagger UI at `http://localhost:8080/swagger-ui/index.html`.

## Architecture

### Backend — `AtenaEventsAPI/`

Standard Spring Boot layered architecture: `controller → service → repository`.

`ddl-auto=update` — Hibernate manages schema. Only manual migration needed: `db-init.sql` drops NOT NULL on `email`/`password` columns (run via `db-migrate` Docker service).

Images and avatars are stored as base64 strings in `TEXT` columns. OAuth avatars are stored as URLs (`avatarUrl`).

#### Entities (`model/`)

| Entity | Table | Key fields |
|--------|-------|------------|
| `User` | `users` | `id`, `name`, `email` (nullable), `password` (nullable), `accountType` (enum), `username`, `providerId`, `avatarBase64`, `avatarUrl`, `createdAt`, `upgradedAt` |
| `Event` | `event` | `id`, `title`, `type`, `description`, `date`, `imageBase64`, `owner` (FK→User) |
| `Participation` | `participation` | `id`, `user` (FK), `event` (FK), `status`, `createdAt` |
| `Comment` | `comment` | `id`, `author` (FK), `event` (FK), `content`, `createdAt` |
| `RefreshToken` | `refresh_token` | `id`, `token`, `user` (FK), `expiresAt` |

`AccountType` enum: `PASSWORD | GUEST | GOOGLE | GITHUB`

`User.getAuthorities()` returns `ROLE_GUEST` for GUEST accounts, `ROLE_USER` for all others.
`User.getHandle()` returns the raw `username` field (use this instead of `getUsername()` which is overridden by UserDetails to return email or username).

#### DTOs (`model/dto/`)

| DTO | Purpose |
|-----|---------|
| `UserDTO` | User response: `id, name, email, avatarBase64, avatarUrl, guest, username, eventsCreatedCount, participationsCount` |
| `EventDTO` | Full event: `id, title, type, description, date, imageBase64, ownerId, ownerName, ownerAvatarUrl, participantsIds[]` |
| `EventListResponseDTO` | Compact event for lists |
| `EventCreateDTO` | Create/update event body |
| `ParticipantSummaryDTO` | Admin panel participant: `userId, name, email, avatarBase64, avatarUrl, accountType, joinedAt` |
| `ParticipateDTO` | Simple `{eventId, userId}` |
| `AuthResponseDTO` | `{accessToken, refreshToken, user: UserDTO}` |
| `GuestCreateDTO` | `{username}` — creates guest session |
| `UpgradePasswordDTO` | `{name, email, password}` — upgrades guest to full account |
| `MergeGuestDTO` | `{guestId}` — merges guest participations into a real account |
| `CommentCreateDTO` / `CommentResponseDTO` / `CommentUpdateDTO` | Comment CRUD |
| `LoginDTO` / `RegisterDTO` / `RefreshTokenRequestDTO` | Auth requests |

#### Controllers and Endpoints

| Controller | Base | Key endpoints |
|-----------|------|---------------|
| `AuthController` | `/auth` | POST `/login`, `/register`, `/refresh`, `/logout`, `/guest`, `/upgrade/password`, `/merge-guest` |
| `EventController` | `/events` | GET `/{id}`, GET `/recommended`, GET `/created_by/{userId}`, GET `/participated_by/{userId}`, GET `/{eventId}/participants` (owner-only), POST, PUT `/{id}`, DELETE `/{id}` |
| `ParticipationController` | `/participate` | POST `/toggle/event/{eventId}/user/{userId}`, GET `/event/{eventId}/user/{userId}` (bool), GET `/event/{eventId}`, GET `/user/{userId}` |
| `CommentController` | `/comments` | GET `/event/{eventId}`, POST, PUT `/{id}`, DELETE `/{id}` |
| `UserController` | `/users` | GET `/{id}`, PUT `/{id}`, POST `/{id}/avatar`, DELETE `/{id}` |

#### Security rules (`SecurityConfig`)

- Public (no auth): `/auth/register|login|refresh|logout|guest`, `/oauth2/**`, `/login/oauth2/**`, Swagger, GET `/events/recommended`, GET `/events/{id}`, GET `/comments/event/{eventId}`
- `ROLE_GUEST` or `ROLE_USER`: POST `/participate/toggle/...`, GET `/participate/event/{eventId}/user/{userId}`
- `ROLE_GUEST` only: POST `/auth/upgrade/password`
- `ROLE_USER` only: everything else (`anyRequest`)
- Method security: `@PreAuthorize("#userId == #principal.id")` on toggle (prevents toggling for other users)
- Session policy: `IF_REQUIRED` (OAuth2 needs HTTP session; JWT requests remain stateless)

#### Services

- `EventService` — CRUD + ownership verification (`verifyOwnership` throws 403 if not owner) + `listParticipants`
- `ParticipationService` — toggle logic, list by event/user
- `GuestAuthService` — `createGuest`, `upgradeWithPassword`, `mergeGuestIntoUser`, `generateUniqueUsername`
- `CommentService` / `UserService` — standard CRUD with ownership checks

#### Security (`security/`)

- `JwtService` — signs/validates tokens; guest tokens use `jwt.guest-token-expiration-ms` (2h), full tokens use `jwt.access-token-expiration-ms` (15min); JWT claims: `sub` (userId), `email`, `name`, `guest` (bool), `avatarUrl`
- `JwtAuthFilter` — extracts Bearer token, sets `SecurityContext`
- `OAuthSuccessHandler` — 4 cases: returning OAuth user → refresh avatar; guest upgrading (session `UPGRADE_GUEST_ID`) → in-place upgrade; email match → link provider; new user → create. Redirects to `{frontendUrl}/oauth-callback?accessToken=...&refreshToken=...`
- `CustomAuthorizationRequestResolver` — stores `upgradeGuestId` query param in HTTP session before OAuth redirect

---

### Frontend — `AtenaEvents-web/`

React Router v7 SPA. No global state manager (no Redux/Zustand). Pages call API modules directly.

#### Routing (`App.jsx`)

```
/                         → redirect to /welcome
/welcome                  → WelcomePage (public)
/signin                   → SignInPage (redirects full users to /home)
/signup                   → SignUpPage (redirects full users to /home)
/oauth-callback           → OAuthCallbackPage (public)
/events/:id               → EventDetailsPage (public — handles auth state internally)
/events/:id/edit          → EditEventPage (PrivateRoute)
/home/*                   → HomeLayout (PrivateRoute — full users only)
  /home                   → HomePage
  /home/events            → MyEventsPage
  /home/events/:eventId/participants → EventParticipantsPage (owner-only admin panel)
  /home/settings          → ConfigPage
  /home/profile           → ProfilePage
  /home/profile/edit      → EditProfilePage
  /home/new               → CreateEventPage
```

`PrivateRoute` blocks guests AND unauthenticated users → `/signin`.
`GuestGuard` restricts guests to their locked event + auth pages.

#### Auth context (`context/AuthContext.jsx`)

Single source of truth. Persisted in `localStorage` as `atena_user`.

```js
// User shape
{ id, name, email, avatarBase64, avatarUrl, guest (bool), username, guestEventId? }

// Key values
isGuest = user?.guest === true
guestEventId = user?.guestEventId ?? null

// Key methods
login(email, password)          // calls maybeMergeGuest() before persistUser
register(name, email, password) // calls maybeMergeGuest() before persistUser
loginAsGuest(username)          // creates guest session, no refresh token
setGuestEvent(eventId)          // reads localStorage directly (stale-closure safe)
upgradeWithPassword(name, email, password)
loginWithOAuth(provider, upgradeGuestId?)  // redirects browser to backend
handleOAuthCallback(accessToken, refreshToken)  // called by OAuthCallbackPage
maybeMergeGuest()               // reads guest from localStorage BEFORE persistUser overwrites
```

#### API modules (`src/api/`)

| Module | Base | Key functions |
|--------|------|---------------|
| `client.js` | — | Central axios instance; handles auth headers, 401 refresh, force-logout |
| `eventApi.js` | `/events` | `getEvent`, `getRecommended`, `getCreatedBy`, `getParticipatedBy`, `getEventParticipants`, `createEvent`, `updateEvent`, `deleteEvent` |
| `participationApi.js` | `/participate` | `toggleParticipation`, `isParticipating`, `listByEvent`, `listByUser` |
| `commentApi.js` | `/comments` | `getComments`, `createComment`, `updateComment`, `deleteComment` |
| `userApi.js` | `/users` | `getUser`, `updateUser`, `uploadAvatar`, `deleteUser`, `login`, `register`, `logout` |

`client.js` specifics: `saveTokens(access, refresh)` accepts `null` refresh (for guests). `forceLogout()` redirects guests on `/events/` to `/welcome`, others to `/signin`.

#### Pages (`src/pages/`)

| Page | Route | Notes |
|------|-------|-------|
| `WelcomePage` | `/welcome` | Landing page |
| `SignInPage` | `/signin` | Shows guest banner if `isGuest`; only redirects to `/home` if `!isGuest` |
| `SignUpPage` | `/signup` | Same; prefills name from guest user |
| `OAuthCallbackPage` | `/oauth-callback` | Reads `?accessToken&refreshToken`, calls `handleOAuthCallback` |
| `EventDetailsPage` | `/events/:id` | Public; three-state comment section (anon/guest/full user); guest banner; GuestJoinModal; UpgradeAccountModal |
| `HomeLayout` | `/home/*` | Shell with Sidebar + Topbar |
| `HomePage` | `/home` | Recommended events feed |
| `MyEventsPage` | `/home/events` | Created + participated events; "Participantes" hover button on created tiles |
| `EventParticipantsPage` | `/home/events/:eventId/participants` | Owner-only admin panel; participant list with search, type badges, join date |
| `CreateEventPage` | `/home/new` | Event creation form |
| `EditEventPage` | `/events/:id/edit` | Event editing |
| `ProfilePage` | `/home/profile` | View profile |
| `EditProfilePage` | `/home/profile/edit` | Edit profile + avatar |
| `ConfigPage` | `/home/settings` | App settings |

#### Components (`src/components/`)

| Component | Purpose |
|-----------|---------|
| `EventCard` | Card used in HomePage feed |
| `Sidebar` | Nav sidebar (Início, Eventos, Config, Perfil, + Novo Evento) |
| `Topbar` | Top bar with title and user avatar |
| `Spinner` | Loading spinner |
| `ImagePicker` | Avatar/image upload with base64 conversion |
| `GuestJoinModal` | Username input modal for anonymous users clicking join |
| `UpgradeAccountModal` | Multi-step upgrade: choose provider / email form / success |
| `Icons` | All SVG icon components: `IconHome, IconCalendar, IconSettings, IconPerson, IconAdd, IconStar, IconBack, IconSearch, IconGoogle, IconGithub` |

#### Avatar rendering pattern

Always use: `avatarBase64 || avatarUrl` as the image src. `avatarBase64` is an uploaded image (base64 string); `avatarUrl` is from OAuth provider (Google picture / GitHub avatar_url).

---

## Environment Variables

| Variable | Where | Purpose |
|---|---|---|
| `DATABASE_URL` | API | JDBC URL for PostgreSQL |
| `POSTGRES_USER` / `POSTGRES_PASSWORD` | API + Docker | DB credentials |
| `JWT_SECRET` | API | JWT signing key (min 32 chars) |
| `SPRING_PROFILES_ACTIVE` | API | `prod` in Docker |
| `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` | API | Google OAuth2 app credentials |
| `GITHUB_CLIENT_ID` / `GITHUB_CLIENT_SECRET` | API | GitHub OAuth2 app credentials |
| `FRONTEND_URL` | API | Used for OAuth redirect (default: `http://localhost:3000`) |
| `VITE_API_URL` | Frontend | Base URL for API calls (default: `http://localhost:8080`) |
