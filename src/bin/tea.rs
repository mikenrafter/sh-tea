//! tea — inspect / manage transparent pipeline logs.

use std::io::{self, Write};
use std::path::PathBuf;
use std::process;

use tea::{
    ensure_user_config, in_git_repo, is_agentic, is_interactive_session, last_row, list_rows,
    load_config, load_tools, parent_is_running_script, should_activate, tool_config, CSV_FIELDS,
};

const USAGE: &str = "\
tea — transparent pipeline stage logger

Wrappers shadow stdin→stdout filter utilities (grep, sort, sed, …). When
activated they copy stdin to a mktemp --suffix .tea file (usually under /tmp)
and index rows in ./logs.csv, then run the real command unchanged.

Activation (first match wins):
  --coffee / --no-tea   force off
  --tea                 force on
  agentic session       auto on (unless manual-only)
  interactive session   auto on when default-interactive = true

Config: ~/.config/tea/config.toml  (created on first use)
See:    man tea
";

fn cmd_last() -> i32 {
    match last_row(None) {
        Some(row) => {
            println!("{}", row.get("logfile").map(|s| s.as_str()).unwrap_or(""));
            0
        }
        None => {
            eprintln!("tea: no log records in ./logs.csv");
            1
        }
    }
}

fn cmd_list() -> i32 {
    let rows = list_rows(None);
    if rows.is_empty() {
        eprintln!("tea: no log records in ./logs.csv");
        return 1;
    }
    let mut wtr = csv::WriterBuilder::new()
        .terminator(csv::Terminator::Any(b'\n'))
        .from_writer(io::stdout());
    if wtr.write_record(CSV_FIELDS).is_err() {
        return 1;
    }
    for r in &rows {
        let vals: Vec<&str> = CSV_FIELDS
            .iter()
            .map(|k| r.get(*k).map(|s| s.as_str()).unwrap_or(""))
            .collect();
        if wtr.write_record(&vals).is_err() {
            return 1;
        }
    }
    let _ = wtr.flush();
    0
}

fn cmd_show(id: Option<&str>) -> i32 {
    let rows = list_rows(None);
    if rows.is_empty() {
        eprintln!("tea: no log records in ./logs.csv");
        return 1;
    }
    let row = if let Some(want) = id {
        match rows.iter().find(|r| r.get("id").map(|s| s.as_str()) == Some(want)) {
            Some(r) => r,
            None => {
                eprintln!("tea: no record id={want}");
                return 1;
            }
        }
    } else {
        rows.last().unwrap()
    };
    let logfile = row.get("logfile").map(|s| s.as_str()).unwrap_or("");
    let mut path = PathBuf::from(logfile);
    if !path.is_absolute() {
        path = std::env::current_dir().unwrap_or_else(|_| PathBuf::from(".")).join(path);
    }
    match std::fs::read(&path) {
        Ok(bytes) => {
            let _ = io::stdout().write_all(&bytes);
            0
        }
        Err(_) => {
            eprintln!("tea: missing logfile: {}", path.display());
            1
        }
    }
}

fn cmd_config() -> i32 {
    match ensure_user_config() {
        Ok(path) => {
            println!("{}", path.display());
            0
        }
        Err(e) => {
            eprintln!("tea: config: {e}");
            1
        }
    }
}

fn cmd_which(tool: &str) -> i32 {
    let tools = load_tools();
    if !tools.iter().any(|t| t == tool) {
        eprintln!("tea: unknown tool: {tool}");
        return 2;
    }
    let cfg = load_config();
    let on = should_activate(tool, &cfg, false, false);
    let tcfg = tool_config(&cfg, tool);
    println!("tool={tool}");
    println!("would_activate={on}");
    println!("interactive={}", is_interactive_session());
    println!("agentic={}", is_agentic());
    println!("parent_script={}", parent_is_running_script());
    println!("in_git_repo={}", in_git_repo(None));
    println!("config={}", cfg.path);
    println!("  enabled={}", tcfg.enabled);
    println!("  only-in-git-repos={}", tcfg.only_in_git_repos);
    println!("  only-outside-git-repos={}", tcfg.only_outside_git_repos);
    println!("  update-gitignore={}", tcfg.update_gitignore);
    println!("  default-interactive={}", tcfg.default_interactive);
    println!("  manual-only={}", tcfg.manual_only);
    println!("  max-log-records={}", tcfg.max_log_records);
    println!("  quiet={}", tcfg.quiet);
    0
}

fn main() {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    if argv.is_empty() || argv[0] == "-h" || argv[0] == "--help" {
        print!("{USAGE}");
        process::exit(0);
    }

    let code = match argv[0].as_str() {
        "last" => cmd_last(),
        "list" => cmd_list(),
        "show" => {
            let id = argv.get(1).map(|s| s.as_str());
            cmd_show(id)
        }
        "config" => cmd_config(),
        "which" => {
            let Some(tool) = argv.get(1) else {
                eprintln!("usage: tea which TOOL");
                process::exit(2);
            };
            cmd_which(tool)
        }
        _ => {
            eprint!("{USAGE}");
            2
        }
    };
    process::exit(code);
}
