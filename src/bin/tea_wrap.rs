//! tea-wrap TOOL REAL_BIN [args...] — transparent tee for pipeline stages.

use std::io::{self, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::{Command, Stdio};

use tea::{
    announce, copy_stdin_to_proc_and_log, discover_pipeline_siblings, load_config, load_tools,
    make_logfile_path, register_log, should_activate, strip_tea_flags, tool_config, Config, ToolCfg,
};

fn passthrough_exec(real: &str, args: &[String]) -> ! {
    let err = Command::new(real).args(args).exec();
    eprintln!("tea-wrap: exec failed: {err}");
    std::process::exit(127);
}

fn run_wrapped(tool: &str, real: &str, args: &[String], tcfg: &ToolCfg) -> i32 {
    let logfile = match make_logfile_path() {
        Ok(p) => p,
        Err(e) => {
            eprintln!("tea-wrap: logfile: {e}");
            return 1;
        }
    };
    let quiet = tcfg.quiet;
    let siblings = discover_pipeline_siblings();

    let mut child = match Command::new(real)
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .spawn()
    {
        Ok(c) => c,
        Err(e) => {
            eprintln!("tea-wrap: spawn {real}: {e}");
            return 127;
        }
    };

    let nbytes = {
        let mut log_f = match std::fs::OpenOptions::new()
            .write(true)
            .truncate(true)
            .open(&logfile)
        {
            Ok(f) => f,
            Err(e) => {
                eprintln!("tea-wrap: open logfile: {e}");
                let _ = child.kill();
                return 1;
            }
        };
        let mut proc_stdin = child.stdin.take().expect("piped stdin");
        match copy_stdin_to_proc_and_log(&mut proc_stdin, &mut log_f) {
            Ok(n) => n,
            Err(e) if e.kind() == io::ErrorKind::BrokenPipe => {
                // Should be rare (copy handles EPIPE on write); keep going.
                let _ = log_f.flush();
                0
            }
            Err(e) => {
                eprintln!("tea-wrap: copy stdin: {e}");
                let _ = child.kill();
                return 1;
            }
        }
    };
    // Dropping proc_stdin closes the pipe.

    let rc = match child.wait() {
        Ok(status) => status.code().unwrap_or(1),
        Err(_) => 1,
    };

    match register_log(
        tool,
        args,
        &logfile,
        nbytes,
        rc,
        tcfg,
        None,
        Some(&siblings),
    ) {
        Ok(row) => announce(&row, quiet),
        Err(e) => eprintln!("tea-wrap: register log: {e}"),
    }
    rc
}

fn main() {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    if argv.len() < 2 {
        eprintln!("usage: tea-wrap TOOL REAL_BIN [args...]");
        std::process::exit(2);
    }

    let tool = &argv[0];
    let real = &argv[1];
    let raw_args = &argv[2..];

    let tools = load_tools();
    if !tools.iter().any(|t| t == tool) {
        eprintln!("tea-wrap: unsupported tool: {tool}");
        std::process::exit(2);
    }

    let real_path = Path::new(real);
    let executable = real_path.is_file()
        && real_path
            .metadata()
            .map(|m| m.permissions().mode() & 0o111 != 0)
            .unwrap_or(false);
    if !executable {
        eprintln!("tea-wrap: real binary not executable: {real}");
        std::process::exit(127);
    }

    let (passthrough, force_on, force_off) = strip_tea_flags(raw_args);
    let cfg: Config = load_config();
    let tcfg = tool_config(&cfg, tool);

    if !should_activate(tool, &cfg, force_on, force_off) {
        passthrough_exec(real, &passthrough);
    }

    let code = match std::panic::catch_unwind(|| run_wrapped(tool, real, &passthrough, &tcfg)) {
        Ok(rc) => rc,
        Err(_) => 1,
    };

    // BrokenPipe on stdout is normal when downstream closes early.
    let _ = io::stdout().flush();
    std::process::exit(code);
}
