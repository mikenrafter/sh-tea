//! tea — inspect / manage transparent pipeline logs.

use std::io::{self, Write};
use std::path::PathBuf;
use std::process;
use std::str::FromStr;

use tea::agent_hooks::{
    emit_hooks_document, install_hooks_globally, install_skill_globally, run_hook, Agent,
    SKILL_TEXT,
};
use tea::{
    ensure_user_config, evaluate_activation, last_row, list_rows, load_config, load_tools,
    tool_config, ActivationContext, ActivationOutcome, ActivationReport, Config, CSV_FIELDS,
};

const USAGE: &str = "\
tea — transparent pipeline stage logger

Wrappers shadow stdin→stdout filter utilities (grep, sort, sed, …). When
activated they copy stdin to a mktemp --suffix .tea file (usually under /tmp)
and index rows in ./logs.csv, then run the real command unchanged.

Activation (first match wins):
  --coffee / --no-tea   force off
  --tea                 force on
  agentic user pipeline auto on (unless manual-only)
  interactive user pipeline auto on when default-interactive = true

Agent helpers (print by default; install only with flags):
  tea skill [--agent AGENT] [--install-hooks-globally]
  tea hooks --agent AGENT [--install-hooks-globally]
  tea hooks run --agent AGENT   (hook stdin→stdout; used by harness hooks)

Agents: claude | cursor | codex  (also: claude-code, cursor-cli)

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

fn parse_which_args(extra_args: &[String]) -> (Vec<String>, bool, bool, bool) {
    let mut rest = Vec::new();
    let mut force_on = false;
    let mut force_off = false;
    let mut simulate_piped = false;
    for a in extra_args {
        if a == "--tea" {
            force_on = true;
        } else if a == "--no-tea" || a == "--coffee" {
            force_off = true;
        } else if a == "--piped" {
            simulate_piped = true;
        } else if a == "--" {
            break;
        } else {
            rest.push(a.clone());
        }
    }
    (rest, force_on, force_off, simulate_piped)
}

fn outcome_label(outcome: &ActivationOutcome) -> &'static str {
    match outcome {
        ActivationOutcome::ActivatedForceTea => "activated:force_tea",
        ActivationOutcome::ActivatedTeaForce => "activated:tea_force",
        ActivationOutcome::ActivatedAgentic => "activated:agentic",
        ActivationOutcome::ActivatedInteractive => "activated:interactive",
        ActivationOutcome::SuppressedForceOff => "suppressed:force_off",
        ActivationOutcome::SuppressedTeaOff => "suppressed:tea_off",
        ActivationOutcome::SuppressedSystemd => "suppressed:systemd",
        ActivationOutcome::SuppressedDisabled => "suppressed:disabled",
        ActivationOutcome::SuppressedOnlyInGitRepos => "suppressed:only_in_git_repos",
        ActivationOutcome::SuppressedOnlyOutsideGitRepos => "suppressed:only_outside_git_repos",
        ActivationOutcome::SuppressedManualOnly => "suppressed:manual_only",
        ActivationOutcome::SuppressedParentScript => "suppressed:parent_script",
        ActivationOutcome::SuppressedNotAuto => "suppressed:not_auto",
    }
}

fn print_activation_report(tool: &str, cfg: &Config, report: &ActivationReport) {
    let tcfg = tool_config(cfg, tool);
    let f = &report.factors;
    println!("tool={tool}");
    println!("would_activate={}", report.activate);
    println!("outcome={}", outcome_label(&report.outcome));
    println!("stdin_tty={}", f.stdin_tty);
    println!("stderr_tty={}", f.stderr_tty);
    println!("interactive_session={}", f.interactive_session);
    println!("user_pipeline={}", f.user_pipeline);
    println!("tea_user_pipe={}", f.tea_user_pipe);
    println!("agentic={}", f.agentic);
    println!("parent_script={}", f.parent_script);
    println!("systemd_unit={}", f.systemd_unit);
    println!("invocation_id={}", f.invocation_id);
    println!("systemd_suppress={}", f.systemd_suppress);
    println!("parent_comm={}", f.parent_comm);
    println!("parent_cmdline={}", f.parent_cmdline);
    println!("term_program={}", f.term_program);
    println!("shlvl={}", f.shlvl);
    println!("in_git_repo={}", f.in_git_repo);
    println!("config={}", cfg.path);
    println!("  enabled={}", tcfg.enabled);
    println!("  only-in-git-repos={}", tcfg.only_in_git_repos);
    println!("  only-outside-git-repos={}", tcfg.only_outside_git_repos);
    println!("  update-gitignore={}", tcfg.update_gitignore);
    println!("  default-interactive={}", tcfg.default_interactive);
    println!("  manual-only={}", tcfg.manual_only);
    println!("  max-log-records={}", tcfg.max_log_records);
    println!("  quiet={}", tcfg.quiet);
    println!("  min-duration-ms={}", tcfg.min_duration_ms);
}

fn cmd_which(tool: &str, extra_args: &[String]) -> i32 {
    let tools = load_tools();
    if !tools.iter().any(|t| t == tool) {
        eprintln!("tea: unknown tool: {tool}");
        return 2;
    }
    let (_, force_on, force_off, simulate_piped) = parse_which_args(extra_args);
    let cfg = load_config();
    let ctx = if simulate_piped {
        ActivationContext::piped_stdin()
    } else {
        ActivationContext::current()
    };
    let report = evaluate_activation(tool, &cfg, force_on, force_off, ctx);
    print_activation_report(tool, &cfg, &report);
    0
}

#[derive(Debug, Default)]
struct AgentFlags {
    agent: Option<Agent>,
    install_globally: bool,
    agents_all: bool,
}

fn parse_agent_flags(args: &[String]) -> Result<AgentFlags, String> {
    let mut flags = AgentFlags::default();
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--install-hooks-globally" => {
                flags.install_globally = true;
                i += 1;
            }
            "--agent" => {
                let Some(val) = args.get(i + 1) else {
                    return Err("--agent requires a value (claude|cursor|codex|all)".into());
                };
                if val == "all" {
                    flags.agents_all = true;
                } else {
                    flags.agent = Some(Agent::from_str(val)?);
                }
                i += 2;
            }
            other if other.starts_with('-') => {
                return Err(format!("unknown flag: {other}"));
            }
            other => return Err(format!("unexpected argument: {other}")),
        }
    }
    Ok(flags)
}

fn agents_from_flags(flags: &AgentFlags) -> Result<Vec<Agent>, String> {
    if flags.agents_all {
        Ok(Agent::all().to_vec())
    } else if let Some(a) = flags.agent {
        Ok(vec![a])
    } else {
        Err("--agent is required (claude|cursor|codex|all)".into())
    }
}

fn install_agent_pair(agent: Agent) -> i32 {
    let mut failed = false;
    match install_skill_globally(agent) {
        Ok(path) => eprintln!("tea: installed skill → {}", path.display()),
        Err(e) => {
            eprintln!(
                "tea: skill install skipped ({}): {e} — hooks may still install; root/tmpfiles-owned skill dirs need nix activation",
                agent.as_str()
            );
            failed = true;
        }
    }
    match install_hooks_globally(agent) {
        Ok(path) => eprintln!("tea: installed hooks → {}", path.display()),
        Err(e) => {
            eprintln!("tea: install hooks ({}): {e}", agent.as_str());
            failed = true;
        }
    }
    if failed {
        1
    } else {
        0
    }
}

fn cmd_skill(args: &[String]) -> i32 {
    let flags = match parse_agent_flags(args) {
        Ok(f) => f,
        Err(e) => {
            eprintln!("tea skill: {e}");
            return 2;
        }
    };
    if flags.install_globally {
        let agents = match agents_from_flags(&flags) {
            Ok(a) => a,
            Err(e) => {
                eprintln!("tea skill: {e}");
                return 2;
            }
        };
        let mut code = 0;
        for agent in agents {
            code |= install_agent_pair(agent);
        }
        code
    } else {
        print!("{SKILL_TEXT}");
        0
    }
}

fn cmd_hooks(args: &[String]) -> i32 {
    if args.first().map(|s| s.as_str()) == Some("run") {
        let flags = match parse_agent_flags(&args[1..]) {
            Ok(f) => f,
            Err(e) => {
                eprintln!("tea hooks run: {e}");
                return 2;
            }
        };
        if flags.install_globally || flags.agents_all {
            eprintln!("tea hooks run: only --agent <claude|cursor|codex> is accepted");
            return 2;
        }
        let Some(agent) = flags.agent else {
            eprintln!("usage: tea hooks run --agent <claude|cursor|codex>");
            return 2;
        };
        return match run_hook(agent, &mut io::stdin(), &mut io::stdout()) {
            Ok(code) => code,
            Err(e) => {
                eprintln!("tea hooks run: {e}");
                1
            }
        };
    }

    let flags = match parse_agent_flags(args) {
        Ok(f) => f,
        Err(e) => {
            eprintln!("tea hooks: {e}");
            return 2;
        }
    };
    let agents = match agents_from_flags(&flags) {
        Ok(a) => a,
        Err(e) => {
            eprintln!("tea hooks: {e}");
            eprintln!("usage: tea hooks --agent <claude|cursor|codex|all> [--install-hooks-globally]");
            return 2;
        }
    };

    if flags.install_globally {
        let mut code = 0;
        for agent in agents {
            code |= install_agent_pair(agent);
        }
        code
    } else if agents.len() == 1 {
        let doc = emit_hooks_document(agents[0]);
        println!("{}", serde_json::to_string_pretty(&doc).unwrap());
        0
    } else {
        let mut map = serde_json::Map::new();
        for agent in agents {
            map.insert(agent.as_str().into(), emit_hooks_document(agent));
        }
        println!(
            "{}",
            serde_json::to_string_pretty(&serde_json::Value::Object(map)).unwrap()
        );
        0
    }
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
                eprintln!("usage: tea which TOOL [--tea | --coffee | --no-tea] [--piped]");
                process::exit(2);
            };
            let extra = argv.get(2..).unwrap_or(&[]);
            cmd_which(tool, extra)
        }
        "skill" => cmd_skill(argv.get(1..).unwrap_or(&[])),
        "hooks" => cmd_hooks(argv.get(1..).unwrap_or(&[])),
        _ => {
            eprint!("{USAGE}");
            2
        }
    };
    process::exit(code);
}
