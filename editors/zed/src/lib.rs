use zed_extension_api::{self as zed, LanguageServerId, Result};

struct ZalsExtension;

impl zed::Extension for ZalsExtension {
    fn new() -> Self {
        Self
    }

    fn language_server_command(
        &mut self,
        _language_server_id: &LanguageServerId,
        worktree: &zed::Worktree,
    ) -> Result<zed::Command> {
        let path = worktree.which("zals");
        if let Some(path) = path {
            Ok(zed::Command {
                command: path,
                args: vec!["--stdio".to_string()],
                env: Default::default(),
            })
        } else {
            Err("zals binary not found in PATH. Install it via `brew install zals` or `pip install zals`.".into())
        }
    }
}

zed::register_extension!(ZalsExtension);
