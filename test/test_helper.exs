ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(C3.Repo, :manual)

# Attachment files outlive the sandbox's rollbacks: start every run from an empty directory.
File.rm_rf!(C3.Config.attachments_dir())
