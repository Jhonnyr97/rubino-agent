# frozen_string_literal: true

# Records the OS process that owns a live (status="active") session so an
# orphaned session — one whose process died without ending it (e.g. a hard
# terminal kill / SIGKILL that no trap can catch, #11) — can be reaped to
# "ended" the next time sessions are listed or resumed. NULL for ended
# sessions and for rows created before this migration.
Sequel.migration do
  up do
    alter_table(:sessions) do
      add_column :owner_pid, Integer
    end
  end

  down do
    alter_table(:sessions) do
      drop_column :owner_pid
    end
  end
end
