# frozen_string_literal: true

# Records the working directory a session was launched in so resume can be
# scoped per-cwd (r5 MF-4 / C-1). Bare `chat` / `--continue` previously resumed
# the GLOBALLY-latest session, so launching in folder B silently latched onto
# folder A's conversation (cross-directory session bleed). With a cwd stamped on
# every session, auto-resume can filter to "the latest session FOR THIS dir" and
# never grab another folder's. NULL for rows created before this migration (they
# are treated as cwd-less and only resumed when no scoped match exists is not
# done — they simply never match a cwd filter, matching Claude Code's per-cwd
# picker behaviour).
Sequel.migration do
  up do
    alter_table(:sessions) do
      add_column :cwd, String
    end
  end

  down do
    alter_table(:sessions) do
      drop_column :cwd
    end
  end
end
