-- Idempotent schema migration — runs on every docker compose up.
-- Wraps everything in a conditional block so it is safe on fresh installs
-- (when the users table doesn't exist yet — Hibernate creates it on first boot).
DO $$
BEGIN
    -- Drop NOT NULL on email — Hibernate can't do this via ddl-auto=update
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'users'
          AND column_name = 'email' AND is_nullable = 'NO'
    ) THEN
        ALTER TABLE users ALTER COLUMN email DROP NOT NULL;
    END IF;

    -- Drop NOT NULL on password
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'users'
          AND column_name = 'password' AND is_nullable = 'NO'
    ) THEN
        ALTER TABLE users ALTER COLUMN password DROP NOT NULL;
    END IF;
END $$;
