CREATE TABLE cats (
    id uuid PRIMARY KEY,
    name varchar(100) NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT cats_name_unique UNIQUE (name)
);
