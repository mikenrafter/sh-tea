//! tea — transparent pipeline stage logger (library).
//! Used by `tea-wrap` and the `tea` CLI.

use std::collections::{HashMap, HashSet};
use std::env;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::os::unix::io::AsRawFd;
use std::path::{Path, PathBuf};
use std::process;

use serde::Deserialize;

pub const CSV_FIELDS: &[&str] = &[
    "id",
    "timestamp",
    "cwd",
    "tool",
    "command",
    "highlighted",
    "logfile",
    "bytes",
    "exit_code",
];

const FALLBACK_TOOLS: &[&str] = &[
    "grep", "egrep", "fgrep", "head", "tail", "cut", "sed", "awk", "gawk", "tr",
    "expand", "unexpand", "fmt", "fold", "nl", "numfmt", "sort", "uniq", "shuf",
    "tac", "rev", "tsort", "paste", "join", "column", "col", "colrm", "od",
    "hexdump", "hd", "wc", "pr", "ptx", "comm",
];

const AGENT_ENV_MARKERS: &[&str] = &[
    "CURSOR_AGENT",
    "CURSOR_AGENT_ID",
    "CURSOR_INVOKED_AS",
    "CLAUDECODE",
    "CLAUDE_CODE",
    "CLAUDE_AGENT",
    "COPILOT_CLI",
    "COPILOT_AGENT",
    "AEGIS",
    "AEGIS_QUEUE",
    "HERMES_AGENT",
    "HERMES_PROFILE",
    "AGENT_TASK_ID",
    "OPENCODE_AGENT",
    // NOTE: bare "AGENT" is intentionally excluded — system.nix sets
    // environment.variables.AGENT = "claude" (consumed by
    // tools/niri-workspace-init to pick the default agent CLI), and NixOS
    // forwards environment.variables into systemd's global environment.
    // That makes AGENT nonempty on every process on the machine, including
    // background systemd services, which defeated this list's purpose as
    // an agentic-context detector.
];

const AGENT_COMM_SUBSTRINGS: &[&str] = &[
    "cursor-agent",
    "claude",
    "copilot",
    "aegis",
    "hermes-agent",
];

const DEFAULT_CONFIG_TOML: &str = r#"# tea — transparent pipeline logger
# Per-tool [tools.*] sections are added from TEA_DEFAULT_CONFIG when present.

[defaults]
default-interactive = true
manual-only = false
update-gitignore = true
max-log-records = 20
quiet = false
only-in-git-repos = false
only-outside-git-repos = false
"#;

#[derive(Debug, Clone)]
pub struct ToolCfg {
    pub enabled: bool,
    pub only_in_git_repos: bool,
    pub only_outside_git_repos: bool,
    pub update_gitignore: bool,
    pub default_interactive: bool,
    pub manual_only: bool,
    pub max_log_records: usize,
    pub quiet: bool,
}

impl Default for ToolCfg {
    fn default() -> Self {
        Self {
            enabled: true,
            only_in_git_repos: false,
            only_outside_git_repos: false,
            update_gitignore: true,
            default_interactive: true,
            manual_only: false,
            max_log_records: 20,
            quiet: false,
        }
    }
}

#[derive(Debug)]
pub struct Config {
    pub defaults: ToolCfg,
    pub tools: HashMap<String, ToolCfg>,
    pub path: String,
}

#[derive(Debug, Deserialize)]
struct RawConfig {
    #[serde(default)]
    defaults: HashMap<String, toml::Value>,
    #[serde(default)]
    tools: HashMap<String, HashMap<String, toml::Value>>,
}

pub type CsvRow = HashMap<String, String>;

pub fn load_tools() -> Vec<String> {
    if let Ok(path) = env::var("TEA_TOOLS_JSON") {
        if let Ok(text) = fs::read_to_string(&path) {
            if let Ok(data) = serde_json::from_str::<serde_json::Value>(&text) {
                if let Some(obj) = data.as_object() {
                    if !obj.is_empty() {
                        let mut keys: Vec<String> = obj.keys().cloned().collect();
                        keys.sort();
                        return keys;
                    }
                }
            }
        }
    }
    FALLBACK_TOOLS.iter().map(|s| (*s).to_string()).collect()
}

pub fn config_path() -> PathBuf {
    if let Ok(xdg) = env::var("XDG_CONFIG_HOME") {
        if !xdg.is_empty() {
            return PathBuf::from(xdg).join("tea").join("config.toml");
        }
    }
    let home = env::var("HOME").unwrap_or_else(|_| String::from("/"));
    PathBuf::from(home).join(".config").join("tea").join("config.toml")
}

fn default_config_text() -> String {
    if let Ok(path) = env::var("TEA_DEFAULT_CONFIG") {
        if let Ok(text) = fs::read_to_string(&path) {
            return text;
        }
    }
    DEFAULT_CONFIG_TOML.to_string()
}

pub fn ensure_user_config() -> io::Result<PathBuf> {
    let path = config_path();
    if !path.is_file() {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::write(&path, default_config_text())?;
    }
    Ok(path)
}

fn as_bool(val: &toml::Value, default: bool) -> bool {
    match val {
        toml::Value::Boolean(b) => *b,
        toml::Value::Integer(i) => *i != 0,
        toml::Value::Float(f) => *f != 0.0,
        toml::Value::String(s) => {
            let s = s.trim().to_lowercase();
            match s.as_str() {
                "1" | "true" | "yes" | "on" => true,
                "0" | "false" | "no" | "off" => false,
                _ => default,
            }
        }
        _ => default,
    }
}

fn as_int(val: &toml::Value, default: i64) -> i64 {
    match val {
        toml::Value::Integer(i) => *i,
        toml::Value::String(s) => s.trim().parse().unwrap_or(default),
        toml::Value::Float(f) => *f as i64,
        _ => default,
    }
}

fn apply_raw(base: &ToolCfg, raw: &HashMap<String, toml::Value>) -> ToolCfg {
    let mut cfg = base.clone();
    let mut raw = raw.clone();
    if raw.contains_key("default-intactive") && !raw.contains_key("default-interactive") {
        if let Some(v) = raw.remove("default-intactive") {
            raw.insert("default-interactive".into(), v);
        }
    }

    if let Some(v) = raw.get("enabled") {
        cfg.enabled = as_bool(v, cfg.enabled);
    }
    if let Some(v) = raw.get("only-in-git-repos") {
        cfg.only_in_git_repos = as_bool(v, cfg.only_in_git_repos);
    }
    if let Some(v) = raw.get("only-outside-git-repos") {
        cfg.only_outside_git_repos = as_bool(v, cfg.only_outside_git_repos);
    }
    if let Some(v) = raw.get("update-gitignore") {
        cfg.update_gitignore = as_bool(v, cfg.update_gitignore);
    }
    if let Some(v) = raw.get("default-interactive") {
        cfg.default_interactive = as_bool(v, cfg.default_interactive);
    }
    if let Some(v) = raw.get("manual-only") {
        cfg.manual_only = as_bool(v, cfg.manual_only);
    }
    if let Some(v) = raw.get("quiet") {
        cfg.quiet = as_bool(v, cfg.quiet);
    }
    if let Some(v) = raw.get("max-log-records") {
        cfg.max_log_records = as_int(v, cfg.max_log_records as i64).max(1) as usize;
    }
    cfg
}

pub fn load_config() -> Config {
    let path = match ensure_user_config() {
        Ok(p) => p,
        Err(_) => config_path(),
    };
    let mut defaults = ToolCfg::default();

    let text = fs::read_to_string(&path).unwrap_or_default();
    let raw: RawConfig = match toml::from_str(&text) {
        Ok(r) => r,
        Err(exc) => {
            eprintln!("tea: warning: bad config {}: {exc}", path.display());
            RawConfig {
                defaults: HashMap::new(),
                tools: HashMap::new(),
            }
        }
    };

    defaults = apply_raw(&defaults, &raw.defaults);

    let mut tools_map: HashMap<String, ToolCfg> = HashMap::new();
    for name in load_tools() {
        let section = raw.tools.get(&name).cloned().unwrap_or_default();
        tools_map.insert(name, apply_raw(&defaults, &section));
    }

    Config {
        defaults,
        tools: tools_map,
        path: path.to_string_lossy().into_owned(),
    }
}

pub fn tool_config(cfg: &Config, tool: &str) -> ToolCfg {
    cfg.tools
        .get(tool)
        .cloned()
        .unwrap_or_else(|| cfg.defaults.clone())
}

fn env_truthy(key: &str) -> bool {
    match env::var(key) {
        Ok(v) => matches!(v.trim().to_lowercase().as_str(), "1" | "true" | "yes"),
        Err(_) => false,
    }
}

fn env_falsey_or_empty(val: &str) -> bool {
    let s = val.trim();
    if s.is_empty() {
        return true;
    }
    matches!(s.to_lowercase().as_str(), "0" | "false" | "no" | "off")
}

const SHELL_NAMES: &[&str] = &["bash", "sh", "dash", "zsh", "ksh", "mksh", "fish"];

const TERMINAL_EMULATOR_COMM_SUBSTRINGS: &[&str] = &[
    "warp",
    "kitty",
    "alacritty",
    "wezterm",
    "ghostty",
    "hyper",
    "foot",
    "terminology",
    "konsole",
    "gnome-terminal",
    "xfce4-terminal",
    "tilix",
    "contour",
    "tabby",
];

fn process_comm(pid: i32) -> Option<String> {
    fs::read_to_string(format!("/proc/{pid}/comm"))
        .ok()
        .map(|s| s.trim().to_string())
}

fn process_cmdline_argv(pid: i32) -> Vec<String> {
    let Ok(raw) = fs::read(format!("/proc/{pid}/cmdline")) else {
        return Vec::new();
    };
    raw.split(|b: &u8| *b == 0)
        .filter(|s| !s.is_empty())
        .filter_map(|s| std::str::from_utf8(s).ok().map(str::to_string))
        .collect()
}

fn process_ppid(pid: i32) -> Option<i32> {
    let stat = fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    let parts: Vec<&str> = stat.split_whitespace().collect();
    parts.get(3)?.parse().ok()
}

fn argv0_base(argv: &[String]) -> String {
    argv.first()
        .map(|a| {
            Path::new(a)
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or(a)
                .to_string()
        })
        .unwrap_or_default()
}

fn comm_is_shell(comm: &str) -> bool {
    SHELL_NAMES.iter().any(|s| *s == comm.trim())
}

fn comm_is_terminal_emulator(comm: &str) -> bool {
    let low = comm.trim().to_lowercase();
    TERMINAL_EMULATOR_COMM_SUBSTRINGS
        .iter()
        .any(|s| low.contains(s))
}

fn shell_argv_has_dash_c(argv: &[String]) -> bool {
    if argv.is_empty() {
        return false;
    }
    if !SHELL_NAMES.iter().any(|s| *s == argv0_base(argv).as_str()) {
        return false;
    }
    let mut i = 1;
    while i < argv.len() {
        let arg = &argv[i];
        if arg == "--" {
            break;
        }
        if arg == "-c" {
            return true;
        }
        if arg.starts_with('-') {
            i += 1;
            continue;
        }
        break;
    }
    false
}

/// True when the immediate parent is the user's shell (or a shell `-c` one
/// level below another shell). Terminal emulators' internal `sh -c` pipelines
/// (Warp paste handling, etc.) are excluded.
pub fn is_user_pipeline_stage() -> bool {
    let ppid = unsafe { libc::getppid() };
    if ppid <= 1 {
        return false;
    }
    let Some(parent_comm) = process_comm(ppid) else {
        return false;
    };
    if !comm_is_shell(&parent_comm) {
        return false;
    }
    let parent_argv = process_cmdline_argv(ppid);
    if shell_argv_has_dash_c(&parent_argv) {
        let Some(gppid) = process_ppid(ppid) else {
            return false;
        };
        let Some(gp_comm) = process_comm(gppid) else {
            return false;
        };
        if comm_is_terminal_emulator(&gp_comm) {
            return false;
        }
        return comm_is_shell(&gp_comm);
    }
    true
}

/// Returns true when the immediate parent process is a shell executing a script
/// file (e.g. `bash /path/to/nix-scout`). Used to suppress activation for tools
/// called from within a script's internals, as opposed to a user or agent typing
/// the command directly.
pub fn parent_is_running_script() -> bool {
    let ppid = unsafe { libc::getppid() };
    if ppid <= 1 {
        return false;
    }
    let Ok(raw) = fs::read(format!("/proc/{ppid}/cmdline")) else {
        return false;
    };
    if raw.is_empty() {
        return false;
    }
    let argv: Vec<&str> = raw
        .split(|b: &u8| *b == 0)
        .filter(|s| !s.is_empty())
        .filter_map(|s| std::str::from_utf8(s).ok())
        .collect();
    if argv.is_empty() {
        return false;
    }
    let argv0_base = Path::new(argv[0])
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("");
    if !SHELL_NAMES.iter().any(|s| *s == argv0_base) {
        return false;
    }
    // Walk shell arguments looking for a script-file positional.
    // Bail on -c (command string, not a file) or -- (end of options).
    let mut i = 1;
    while i < argv.len() {
        let arg = argv[i];
        if arg == "--" {
            break;
        }
        if arg == "-c" {
            // Command string follows, not a script path — not a script invocation.
            return false;
        }
        if arg.starts_with('-') {
            i += 1;
            continue;
        }
        // First non-flag argument: treat it as the script path.
        return Path::new(arg).is_file();
    }
    false
}

pub fn is_interactive_session() -> bool {
    if env_truthy("TEA_INTERACTIVE") {
        return true;
    }
    if env::var("CI").map(|v| !v.trim().is_empty()).unwrap_or(false) {
        return false;
    }
    // Stderr being a TTY means we're in a terminal, but that's not enough: stdin
    // must also be non-TTY (i.e. actually piped) so we don't activate when a
    // subprocess of a non-piped command happens to inherit the terminal.
    let stderr_tty = unsafe { libc::isatty(libc::STDERR_FILENO) == 1 };
    let stdin_tty = unsafe { libc::isatty(libc::STDIN_FILENO) == 1 };
    stderr_tty && !stdin_tty
}

pub fn is_agentic() -> bool {
    if env_truthy("TEA_AGENT") {
        return true;
    }
    for key in AGENT_ENV_MARKERS {
        if let Ok(val) = env::var(key) {
            if !env_falsey_or_empty(&val) {
                return true;
            }
        }
    }
    let mut pid = unsafe { libc::getppid() };
    for _ in 0..8 {
        if pid <= 1 {
            break;
        }
        if let Ok(comm) = fs::read_to_string(format!("/proc/{pid}/comm")) {
            let low = comm.trim().to_lowercase();
            if AGENT_COMM_SUBSTRINGS.iter().any(|s| low.contains(s)) {
                return true;
            }
        }
        if let Ok(raw) = fs::read(format!("/proc/{pid}/cmdline")) {
            let argv0 = raw
                .split(|b| *b == 0)
                .next()
                .and_then(|b| std::str::from_utf8(b).ok())
                .unwrap_or("");
            let name = Path::new(argv0)
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("")
                .to_lowercase();
            if AGENT_COMM_SUBSTRINGS.iter().any(|s| name.contains(s)) {
                return true;
            }
        }
        let Ok(stat) = fs::read_to_string(format!("/proc/{pid}/stat")) else {
            break;
        };
        let parts: Vec<&str> = stat.split_whitespace().collect();
        if parts.len() < 4 {
            break;
        }
        match parts[3].parse::<i32>() {
            Ok(ppid) => pid = ppid,
            Err(_) => break,
        }
    }
    false
}

pub fn git_root(cwd: Option<&Path>) -> Option<PathBuf> {
    let start = cwd
        .map(Path::to_path_buf)
        .unwrap_or_else(|| env::current_dir().unwrap_or_else(|_| PathBuf::from(".")));
    let cur = start.canonicalize().unwrap_or(start);
    for p in cur.ancestors() {
        if p.join(".git").exists() {
            return Some(p.to_path_buf());
        }
    }
    None
}

pub fn in_git_repo(cwd: Option<&Path>) -> bool {
    git_root(cwd).is_some()
}

pub fn strip_tea_flags(argv: &[String]) -> (Vec<String>, bool, bool) {
    let mut out = Vec::new();
    let mut force_on = false;
    let mut force_off = false;
    let mut i = 0;
    while i < argv.len() {
        let a = &argv[i];
        if a == "--tea" {
            force_on = true;
        } else if a == "--no-tea" || a == "--coffee" {
            force_off = true;
        } else if a == "--" {
            out.push(a.clone());
            out.extend(argv[i + 1..].iter().cloned());
            break;
        } else {
            out.push(a.clone());
        }
        i += 1;
    }
    (out, force_on, force_off)
}

/// systemd sets INVOCATION_ID on every process it spawns as a unit (services,
/// timers' triggered services, etc.) — unlike the AGENT_ENV_MARKERS, it can't
/// collide with unrelated user env vars. User-session children (shells,
/// terminal emulators, compositors) inherit the same ID from user@.service,
/// so presence alone is not enough to identify a background unit.
pub fn invocation_id() -> Option<String> {
    env::var("INVOCATION_ID")
        .ok()
        .map(|v| v.trim().to_string())
        .filter(|v| !v.is_empty())
}

pub fn running_as_systemd_unit() -> bool {
    invocation_id().is_some()
}

/// Suppress auto-activation for background systemd units (INVOCATION_ID set,
/// stderr not a TTY). Terminal-attached user-session processes keep stderr on
/// a TTY and are not suppressed. TEA_INTERACTIVE bypasses suppression.
pub fn systemd_suppresses_activation() -> bool {
    if !running_as_systemd_unit() {
        return false;
    }
    if env_truthy("TEA_INTERACTIVE") {
        return false;
    }
    unsafe { libc::isatty(libc::STDERR_FILENO) != 1 }
}

pub fn should_activate(tool: &str, cfg: &Config, force_on: bool, force_off: bool) -> bool {
    if force_off {
        return false;
    }
    if force_on {
        return true;
    }
    if env_truthy("TEA_OFF") {
        return false;
    }
    if env_truthy("TEA_FORCE") {
        return true;
    }
    if systemd_suppresses_activation() {
        return false;
    }

    let tcfg = tool_config(cfg, tool);
    if !tcfg.enabled {
        return false;
    }

    let inside = in_git_repo(None);
    if tcfg.only_in_git_repos && !inside {
        return false;
    }
    if tcfg.only_outside_git_repos && inside {
        return false;
    }
    if tcfg.manual_only {
        return false;
    }
    if parent_is_running_script() {
        return false;
    }
    if is_agentic() {
        return true;
    }
    if tcfg.default_interactive && is_interactive_session() && is_user_pipeline_stage() {
        return true;
    }
    false
}

fn shell_quote(s: &str) -> String {
    if s.chars()
        .all(|c| c.is_ascii_alphanumeric() || "_./:@%+=,-".contains(c))
    {
        return s.to_string();
    }
    format!("'{}'", s.replace('\'', "'\\''"))
}

pub fn format_argv(tool: &str, args: &[String]) -> String {
    let mut parts = vec![tool.to_string()];
    parts.extend(args.iter().map(|a| shell_quote(a)));
    parts.join(" ")
}

fn display_cmdline(parts: &[String]) -> Option<String> {
    for (i, p) in parts.iter().enumerate() {
        let base = Path::new(p)
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("");
        if base == "tea-wrap" && i + 2 < parts.len() {
            let tool = &parts[i + 1];
            let args = &parts[i + 3..];
            return Some(format_argv(tool, args));
        }
    }
    let base0 = Path::new(&parts[0])
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("");
    if matches!(
        base0,
        "bash" | "fish" | "zsh" | "sh" | "dash" | "nu" | "python" | "python3"
    ) {
        return None;
    }
    Some(
        parts
            .iter()
            .map(|p| shell_quote(p))
            .collect::<Vec<_>>()
            .join(" "),
    )
}

pub fn discover_pipeline_siblings() -> Vec<(i32, String)> {
    let pgid = unsafe { libc::getpgid(0) };
    let my_ppid = unsafe { libc::getppid() };
    if pgid < 0 {
        return Vec::new();
    }
    let my_pid = process::id() as i32;
    let mut found = Vec::new();

    let Ok(entries) = fs::read_dir("/proc") else {
        return Vec::new();
    };
    for entry in entries.flatten() {
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if !name.chars().all(|c| c.is_ascii_digit()) {
            continue;
        }
        let Ok(pid) = name.parse::<i32>() else {
            continue;
        };
        let g = unsafe { libc::getpgid(pid) };
        if g != pgid {
            continue;
        }
        let Ok(stat) = fs::read_to_string(format!("/proc/{pid}/stat")) else {
            continue;
        };
        let parts: Vec<&str> = stat.split_whitespace().collect();
        if parts.len() < 4 {
            continue;
        }
        let Ok(ppid) = parts[3].parse::<i32>() else {
            continue;
        };
        if ppid != my_ppid && pid != my_pid {
            continue;
        }
        let Ok(raw) = fs::read(format!("/proc/{pid}/cmdline")) else {
            continue;
        };
        if raw.is_empty() {
            continue;
        }
        let argv: Vec<String> = raw
            .split(|b| *b == 0)
            .filter(|p| !p.is_empty())
            .map(|p| String::from_utf8_lossy(p).into_owned())
            .collect();
        if argv.is_empty() {
            continue;
        }
        if let Some(display) = display_cmdline(&argv) {
            found.push((pid, display));
        }
    }
    found.sort_by_key(|(pid, _)| *pid);
    found
}

pub fn highlight_command(
    tool: &str,
    args: &[String],
    siblings: Option<&[(i32, String)]>,
) -> String {
    let stage = format_argv(tool, args);
    let marked = format!("⟦{stage}⟧");
    let owned;
    let sibs = match siblings {
        Some(s) => s,
        None => {
            owned = discover_pipeline_siblings();
            &owned
        }
    };
    if sibs.len() <= 1 {
        return marked;
    }
    let me = process::id() as i32;
    let mut pieces = Vec::new();
    for (pid, cmd) in sibs {
        if *pid == me {
            pieces.push(marked.clone());
        } else {
            pieces.push(cmd.clone());
        }
    }
    if pieces.len() <= 1 {
        return marked;
    }
    pieces.join(" | ")
}

pub fn ensure_gitignore(cwd: &Path, tcfg: &ToolCfg) {
    if !tcfg.update_gitignore {
        return;
    }
    let Some(root) = git_root(Some(cwd)) else {
        return;
    };
    let gi = root.join(".gitignore");
    let needed = ["logs.csv"];
    let existing = if gi.is_file() {
        fs::read_to_string(&gi).unwrap_or_default()
    } else {
        String::new()
    };
    let present: HashSet<String> = existing
        .lines()
        .map(|ln| ln.trim().to_string())
        .collect();
    let mut to_add = Vec::new();
    for item in needed {
        let mut variants: HashSet<String> = HashSet::new();
        variants.insert(item.to_string());
        variants.insert(format!("/{item}"));
        variants.insert(format!("./{item}"));
        if present.is_disjoint(&variants) {
            to_add.push(item);
        }
    }
    if to_add.is_empty() {
        return;
    }
    let mut f = match OpenOptions::new().create(true).append(true).open(&gi) {
        Ok(f) => f,
        Err(exc) => {
            eprintln!("tea: warning: could not update .gitignore: {exc}");
            return;
        }
    };
    if !existing.is_empty() && !existing.ends_with('\n') {
        let _ = writeln!(f);
    }
    if !present.iter().any(|p| p.contains("# tea")) {
        let _ = writeln!(f, "\n# tea — transparent pipeline logs");
    }
    for item in to_add {
        let _ = writeln!(f, "{item}");
    }
}

pub fn csv_path(cwd: Option<&Path>) -> PathBuf {
    let base = cwd
        .map(Path::to_path_buf)
        .unwrap_or_else(|| env::current_dir().unwrap_or_else(|_| PathBuf::from(".")));
    base.join("logs.csv")
}

fn flock_ex(fd: i32) {
    unsafe {
        libc::flock(fd, libc::LOCK_EX);
    }
}

fn flock_sh(fd: i32) {
    unsafe {
        libc::flock(fd, libc::LOCK_SH);
    }
}

fn flock_un(fd: i32) {
    unsafe {
        libc::flock(fd, libc::LOCK_UN);
    }
}

fn parse_csv_rows(raw: &str) -> Vec<CsvRow> {
    let mut rows = Vec::new();
    if raw.trim().is_empty() {
        return rows;
    }
    let mut rdr = csv::ReaderBuilder::new()
        .flexible(true)
        .from_reader(raw.as_bytes());
    let headers: Vec<String> = match rdr.headers() {
        Ok(h) => h.iter().map(|s| s.to_string()).collect(),
        Err(_) => return rows,
    };
    for record in rdr.records().flatten() {
        let mut row = HashMap::new();
        for (i, field) in record.iter().enumerate() {
            if let Some(key) = headers.get(i) {
                row.insert(key.clone(), field.to_string());
            }
        }
        rows.push(row);
    }
    rows
}

pub fn read_csv_rows(csv_path: &Path) -> Vec<CsvRow> {
    if !csv_path.is_file() {
        return Vec::new();
    }
    let Ok(f) = File::open(csv_path) else {
        return Vec::new();
    };
    flock_sh(f.as_raw_fd());
    let mut raw = String::new();
    let mut fref = &f;
    let _ = fref.read_to_string(&mut raw);
    let rows = parse_csv_rows(&raw);
    flock_un(f.as_raw_fd());
    rows
}

fn next_id(rows: &[CsvRow]) -> i64 {
    let mut mx = 0i64;
    for row in rows {
        if let Some(id) = row.get("id") {
            if let Ok(n) = id.parse::<i64>() {
                mx = mx.max(n);
            }
        }
    }
    mx + 1
}

fn timestamp_now() -> String {
    unsafe {
        let mut t: libc::time_t = 0;
        libc::time(&mut t);
        let tm = libc::localtime(&t);
        if tm.is_null() {
            return "1970-01-01T00:00:00+0000".into();
        }
        let mut buf = [0u8; 64];
        let n = libc::strftime(
            buf.as_mut_ptr() as *mut libc::c_char,
            buf.len(),
            b"%Y-%m-%dT%H:%M:%S%z\0".as_ptr() as *const libc::c_char,
            tm,
        );
        if n == 0 {
            return "1970-01-01T00:00:00+0000".into();
        }
        String::from_utf8_lossy(&buf[..n as usize]).into_owned()
    }
}

/// Create logfile via `mktemp --suffix .tea` → $TMPDIR/tmp.XXXXXX.tea (often /tmp).
pub fn make_logfile_path() -> io::Result<PathBuf> {
    let output = process::Command::new("mktemp")
        .arg("--suffix")
        .arg(".tea")
        .output()?;
    if !output.status.success() {
        return Err(io::Error::other(format!(
            "mktemp failed: {}",
            String::from_utf8_lossy(&output.stderr)
        )));
    }
    let path = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if path.is_empty() {
        return Err(io::Error::other("mktemp returned empty path"));
    }
    Ok(PathBuf::from(path))
}

pub fn register_log(
    tool: &str,
    args: &[String],
    logfile: &Path,
    nbytes: u64,
    exit_code: i32,
    tcfg: &ToolCfg,
    cwd: Option<&Path>,
    siblings: Option<&[(i32, String)]>,
) -> io::Result<CsvRow> {
    let cwd = cwd
        .map(Path::to_path_buf)
        .unwrap_or_else(|| env::current_dir().unwrap_or_else(|_| PathBuf::from(".")));
    let index_path = csv_path(Some(&cwd));
    ensure_gitignore(&cwd, tcfg);

    let command = format_argv(tool, args);
    let highlighted = highlight_command(tool, args, siblings);
    let ts = timestamp_now();

    if let Some(parent) = index_path.parent() {
        fs::create_dir_all(parent)?;
    }

    let mut f = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(&index_path)?;
    flock_ex(f.as_raw_fd());

    let result = (|| {
        f.seek(SeekFrom::Start(0))?;
        let mut raw = String::new();
        f.read_to_string(&mut raw)?;

        let mut rows = parse_csv_rows(&raw);
        let new_id = next_id(&rows);

        // Captures live under TMPDIR (/tmp); store absolute path.
        let log_stored = logfile
            .canonicalize()
            .unwrap_or_else(|_| logfile.to_path_buf())
            .to_string_lossy()
            .into_owned();

        let mut row = HashMap::new();
        row.insert("id".into(), new_id.to_string());
        row.insert("timestamp".into(), ts);
        row.insert("cwd".into(), cwd.to_string_lossy().into_owned());
        row.insert("tool".into(), tool.to_string());
        row.insert("command".into(), command);
        row.insert("highlighted".into(), highlighted);
        row.insert("logfile".into(), log_stored);
        row.insert("bytes".into(), nbytes.to_string());
        row.insert("exit_code".into(), exit_code.to_string());
        rows.push(row.clone());

        let max_n = tcfg.max_log_records.max(1);
        while rows.len() > max_n {
            let old = rows.remove(0);
            if let Some(old_log) = old.get("logfile") {
                if !old_log.is_empty() {
                    let p = {
                        let p = PathBuf::from(old_log);
                        if p.is_absolute() {
                            p
                        } else {
                            cwd.join(p)
                        }
                    };
                    let _ = fs::remove_file(p);
                }
            }
        }

        f.seek(SeekFrom::Start(0))?;
        f.set_len(0)?;
        {
            let mut wtr = csv::WriterBuilder::new()
                .terminator(csv::Terminator::Any(b'\n'))
                .from_writer(&mut f);
            wtr.write_record(CSV_FIELDS)?;
            for r in &rows {
                let vals: Vec<&str> = CSV_FIELDS
                    .iter()
                    .map(|k| r.get(*k).map(|s| s.as_str()).unwrap_or(""))
                    .collect();
                wtr.write_record(&vals)?;
            }
            wtr.flush()?;
        }
        f.sync_all()?;
        Ok(row)
    })();

    flock_un(f.as_raw_fd());
    result
}

pub fn announce(row: &CsvRow, quiet: bool) {
    if quiet || env_truthy("TEA_QUIET") {
        return;
    }
    let id = row.get("id").map(|s| s.as_str()).unwrap_or("?");
    let logfile = row.get("logfile").map(|s| s.as_str()).unwrap_or("?");
    let command = row.get("command").map(|s| s.as_str()).unwrap_or("?");
    eprintln!("[tea] --id {id} {logfile} | {command}");
}

pub fn list_rows(cwd: Option<&Path>) -> Vec<CsvRow> {
    read_csv_rows(&csv_path(cwd))
}

pub fn last_row(cwd: Option<&Path>) -> Option<CsvRow> {
    list_rows(cwd).pop()
}

/// Copy stdin to both the child process stdin and the logfile.
pub fn copy_stdin_to_proc_and_log(
    proc_stdin: &mut impl Write,
    log_f: &mut impl Write,
) -> io::Result<u64> {
    let mut stdin = io::stdin().lock();
    let mut buf = [0u8; 65536];
    let mut nbytes = 0u64;
    loop {
        let n = stdin.read(&mut buf)?;
        if n == 0 {
            break;
        }
        log_f.write_all(&buf[..n])?;
        nbytes += n as u64;
        if let Err(e) = proc_stdin.write_all(&buf[..n]) {
            if e.kind() == io::ErrorKind::BrokenPipe {
                break;
            }
            return Err(e);
        }
    }
    log_f.flush()?;
    Ok(nbytes)
}
