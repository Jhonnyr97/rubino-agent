# frozen_string_literal: true

# Per-session memory-extraction watermark (#249). Holds the id of the newest
# message the memory extractor has already processed for this session. The
# post-turn extractor reads only messages NEWER than this cursor (tie-broken on
# rowid, same total order as the rest of Session::Store), so each turn's
# extraction is bounded to that turn's new messages instead of re-reading an
# overlapping window of already-extracted history. NULL means "never extracted"
# — the extractor then sees the whole (short) session, exactly as before.
Sequel.migration do
  up do
    alter_table(:sessions) do
      add_column :memory_extracted_msg_id, String
    end
  end

  down do
    alter_table(:sessions) do
      drop_column :memory_extracted_msg_id
    end
  end
end
