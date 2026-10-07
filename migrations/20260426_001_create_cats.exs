defmodule Frame.Migrations.CreateCats do
  use Ecto.Migration

  def up do
    create table(:cats, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :name, :varchar, size: 100, null: false
      add :created_at, :timestamptz, null: false, default: fragment("now()")
    end

    execute "ALTER TABLE cats ADD CONSTRAINT cats_name_unique UNIQUE (name)"
  end

  def down do
    drop table(:cats)
  end
end
