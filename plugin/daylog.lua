require("daylog.filetype").register()

-- Register :Daylog at plugin load, so the command works the moment daylog is installed, with any
-- plugin manager and no setup() call. register() only defines the command; its dispatch and
-- completion lazy-require the implementation, so startup stays cheap. setup() (optional) is for
-- configuration -- the daybook, sources, and the opt-in keymaps -- and re-registering is a no-op.
require("daylog.commands").register()
