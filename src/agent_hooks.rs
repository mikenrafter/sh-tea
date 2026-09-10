//! Agent skill + slow-command hooks for Claude Code, Cursor CLI, and Codex.
//!
//! Default CLI behavior prints installable artifacts to stdout (pipeable).
//! `--install-hooks-globally` merges tea-owned entries into the agent config
//! without removing foreign hooks (entire, babeltele, …).

use std::env;
use std::fs;
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::str::FromStr;

use serde_json::{json, Value};

/// Wall-clock threshold matching tea's default `min-duration-ms`.
pub const SLOW_COMMAND_MS: u64 = 5000;

/// Substring present in every tea-owned hook command (idempotent merge key).
pub const HOOK_COMMAND_MARKER: &str = "tea hooks run";

pub const SKILL_TEXT: &str = "\
---
name: tea
description: How to read tea ([tea]) pipeline stage log pointers on stderr
---

# tea logs

Wrapped filters (`grep`, `sort`, `rg`, …) may print a one-line pointer on **stderr**:

```
[tea] --id N /tmp/….tea | <command>
```

That line is the paper trail. Do not ignore stderr. When you need the stage's stdin:

1. Read any `[tea]` lines from the tool's stderr (or the slow-command hook context).
2. Open the logfile path, or run `tea last` / `tea show [id]` / `tea list`.

Prefer those captures over re-running long pipelines.
";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Agent {
    Claude,
    Cursor,
    Codex,
}

impl Agent {
    pub fn as_str(self) -> &'static str {
        match self {
            Agent::Claude => "claude",
            Agent::Cursor => "cursor",
            Agent::Codex => "codex",
        }
    }

    pub fn all() -> &'static [Agent] {
        &[Agent::Claude, Agent::Cursor, Agent::Codex]
    }
}

impl FromStr for Agent {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "claude" | "claude-code" => Ok(Agent::Claude),
            "cursor" | "cursor-cli" => Ok(Agent::Cursor),
            "codex" => Ok(Agent::Codex),
            other => Err(format!(
                "unknown agent '{other}': must be claude, cursor, or codex"
            )),
        }
    }
}

fn home_dir() -> io::Result<PathBuf> {
    env::var_os("HOME")
        .map(PathBuf::from)
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "HOME is not set"))
}

pub fn skill_install_path(agent: Agent) -> io::Result<PathBuf> {
    let home = home_dir()?;
    Ok(match agent {
        Agent::Claude => home.join(".claude/skills/tea/SKILL.md"),
        Agent::Cursor => home.join(".cursor/skills/tea/SKILL.md"),
        Agent::Codex => home.join(".codex/skills/tea/SKILL.md"),
    })
}

pub fn hooks_config_path(agent: Agent) -> io::Result<PathBuf> {
    let home = home_dir()?;
    Ok(match agent {
        Agent::Claude => home.join(".claude/settings.json"),
        Agent::Cursor => home.join(".cursor/hooks.json"),
        Agent::Codex => home.join(".codex/hooks.json"),
    })
}

pub fn hook_command(agent: Agent) -> String {
    format!(
        "sh -c 'if ! command -v tea >/dev/null 2>&1; then exit 0; fi; exec tea hooks run --agent {}'",
        agent.as_str()
    )
}

/// Emit a complete hooks document for one agent (stdout-friendly / pipeable).
pub fn emit_hooks_document(agent: Agent) -> Value {
    let cmd = hook_command(agent);
    match agent {
        Agent::Claude | Agent::Codex => {
            let matcher = if agent == Agent::Claude {
                Value::String("Bash".into())
            } else {
                // Codex tool names vary; filter duration inside `tea hooks run`.
                Value::Null
            };
            json!({
                "hooks": {
                    "PostToolUse": [{
                        "matcher": matcher,
                        "hooks": [{
                            "type": "command",
                            "command": cmd,
                            "timeout": 30
                        }]
                    }]
                }
            })
        }
        Agent::Cursor => json!({
            "version": 1,
            "hooks": {
                "postToolUse": [{
                    "matcher": "Shell",
                    "command": cmd
                }]
            }
        }),
    }
}

fn tea_owned_command(cmd: &str) -> bool {
    cmd.contains(HOOK_COMMAND_MARKER)
}

fn read_json_file(path: &Path) -> io::Result<Value> {
    if !path.exists() {
        return Ok(json!({}));
    }
    // Follow symlink-to-store into a writable merge base.
    let raw = fs::read_to_string(path)?;
    if raw.trim().is_empty() {
        return Ok(json!({}));
    }
    serde_json::from_str(&raw).map_err(|e| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("{}: {e}", path.display()),
        )
    })
}

fn write_json_file(path: &Path, value: &Value) -> io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    // Replace nix-store symlinks with a real file we can merge into later.
    if path
        .symlink_metadata()
        .map(|m| m.file_type().is_symlink())
        .unwrap_or(false)
    {
        let _ = fs::remove_file(path);
    }
    let pretty = serde_json::to_string_pretty(value)
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
    let mut f = fs::File::create(path)?;
    f.write_all(pretty.as_bytes())?;
    f.write_all(b"\n")?;
    Ok(())
}

fn merge_claude_style(doc: &mut Value, command: &str, matcher: Value) {
    let hooks = doc
        .as_object_mut()
        .expect("root object")
        .entry("hooks")
        .or_insert_with(|| json!({}));
    let post = hooks
        .as_object_mut()
        .expect("hooks object")
        .entry("PostToolUse")
        .or_insert_with(|| json!([]));
    let arr = post.as_array_mut().expect("PostToolUse array");

    // Already installed?
    for entry in arr.iter() {
        if let Some(inner) = entry.get("hooks").and_then(|h| h.as_array()) {
            for h in inner {
                if h.get("command")
                    .and_then(|c| c.as_str())
                    .is_some_and(tea_owned_command)
                {
                    return;
                }
            }
        }
    }

    arr.push(json!({
        "matcher": matcher,
        "hooks": [{
            "type": "command",
            "command": command,
            "timeout": 30
        }]
    }));
}

fn merge_cursor_style(doc: &mut Value, command: &str) {
    if doc.get("version").is_none() {
        doc.as_object_mut()
            .expect("root object")
            .insert("version".into(), json!(1));
    }
    let hooks = doc
        .as_object_mut()
        .expect("root object")
        .entry("hooks")
        .or_insert_with(|| json!({}));
    let post = hooks
        .as_object_mut()
        .expect("hooks object")
        .entry("postToolUse")
        .or_insert_with(|| json!([]));
    let arr = post.as_array_mut().expect("postToolUse array");

    for entry in arr.iter() {
        if entry
            .get("command")
            .and_then(|c| c.as_str())
            .is_some_and(tea_owned_command)
        {
            return;
        }
    }

    arr.push(json!({
        "matcher": "Shell",
        "command": command
    }));
}

pub fn install_hooks_globally(agent: Agent) -> io::Result<PathBuf> {
    let path = hooks_config_path(agent)?;
    let mut doc = read_json_file(&path)?;
    if !doc.is_object() {
        doc = json!({});
    }
    let cmd = hook_command(agent);
    match agent {
        Agent::Claude => merge_claude_style(&mut doc, &cmd, Value::String("Bash".into())),
        Agent::Codex => merge_claude_style(&mut doc, &cmd, Value::Null),
        Agent::Cursor => merge_cursor_style(&mut doc, &cmd),
    }
    write_json_file(&path, &doc)?;
    Ok(path)
}

pub fn install_skill_globally(agent: Agent) -> io::Result<PathBuf> {
    let path = skill_install_path(agent)?;
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    if path
        .symlink_metadata()
        .map(|m| m.file_type().is_symlink())
        .unwrap_or(false)
    {
        let _ = fs::remove_file(&path);
    }
    fs::write(&path, SKILL_TEXT)?;
    Ok(path)
}

fn duration_ms_from_payload(v: &Value) -> Option<u64> {
    v.get("duration_ms")
        .and_then(|x| x.as_u64().or_else(|| x.as_f64().map(|f| f as u64)))
        .or_else(|| {
            v.get("duration")
                .and_then(|x| x.as_u64().or_else(|| x.as_f64().map(|f| f as u64)))
        })
}

fn collect_tea_blurbs(text: &str) -> Vec<String> {
    text.lines()
        .filter(|l| l.contains("[tea]"))
        .map(|l| l.trim().to_string())
        .collect()
}

fn extract_output_text(v: &Value) -> String {
    let mut chunks = Vec::new();
    if let Some(s) = v.get("output").and_then(|x| x.as_str()) {
        chunks.push(s.to_string());
    }
    if let Some(s) = v.get("tool_output").and_then(|x| x.as_str()) {
        chunks.push(s.to_string());
    }
    if let Some(tr) = v.get("tool_response") {
        if let Some(s) = tr.as_str() {
            chunks.push(s.to_string());
        } else if let Some(s) = tr.get("output").and_then(|x| x.as_str()) {
            chunks.push(s.to_string());
        } else {
            chunks.push(tr.to_string());
        }
    }
    chunks.join("\n")
}

fn slow_context_message(blurbs: &[String], duration_ms: u64) -> String {
    let mut msg = format!(
        "Command took {duration_ms}ms (>{}ms). tea may have logged pipeline-stage stdin; check stderr for `[tea] --id …` lines, then `tea last` / `tea show` / the logfile path — prefer that over re-running.",
        SLOW_COMMAND_MS
    );
    if !blurbs.is_empty() {
        msg.push_str("\nSeen [tea] lines:\n");
        for b in blurbs {
            msg.push_str(b);
            msg.push('\n');
        }
    }
    msg
}

/// Hook runner: read agent stdin JSON, emit reminder JSON if duration > threshold.
pub fn run_hook(agent: Agent, stdin: &mut dyn Read, stdout: &mut dyn Write) -> io::Result<i32> {
    let mut raw = String::new();
    stdin.read_to_string(&mut raw)?;
    if raw.trim().is_empty() {
        return Ok(0);
    }
    let payload: Value = match serde_json::from_str(&raw) {
        Ok(v) => v,
        Err(_) => return Ok(0), // fail open
    };

    let Some(duration_ms) = duration_ms_from_payload(&payload) else {
        return Ok(0);
    };
    if duration_ms < SLOW_COMMAND_MS {
        return Ok(0);
    }

    let blurbs = collect_tea_blurbs(&extract_output_text(&payload));
    let msg = slow_context_message(&blurbs, duration_ms);

    let out = match agent {
        Agent::Cursor => json!({ "additional_context": msg }),
        Agent::Claude | Agent::Codex => json!({
            "hookSpecificOutput": {
                "hookEventName": "PostToolUse",
                "additionalContext": msg
            },
            "systemMessage": msg
        }),
    };
    writeln!(stdout, "{}", serde_json::to_string(&out).unwrap())?;
    Ok(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    #[test]
    fn agent_aliases() {
        assert_eq!(Agent::from_str("claude-code").unwrap(), Agent::Claude);
        assert_eq!(Agent::from_str("cursor-cli").unwrap(), Agent::Cursor);
        assert_eq!(Agent::from_str("codex").unwrap(), Agent::Codex);
    }

    #[test]
    fn emit_contains_marker() {
        for a in Agent::all() {
            let doc = emit_hooks_document(*a);
            let s = doc.to_string();
            assert!(s.contains(HOOK_COMMAND_MARKER), "{s}");
        }
    }

    #[test]
    fn merge_preserves_foreign_cursor_hooks() {
        let mut doc = json!({
            "version": 1,
            "hooks": {
                "preCompact": [{ "command": "/babeltele" }],
                "postToolUse": [{ "command": "entire hooks cursor stop" }]
            }
        });
        merge_cursor_style(&mut doc, &hook_command(Agent::Cursor));
        merge_cursor_style(&mut doc, &hook_command(Agent::Cursor)); // idempotent
        let arr = doc["hooks"]["postToolUse"].as_array().unwrap();
        assert_eq!(arr.len(), 2);
        assert!(arr.iter().any(|e| {
            e["command"]
                .as_str()
                .is_some_and(|c| c.contains("entire hooks"))
        }));
        assert_eq!(
            arr.iter()
                .filter(|e| e["command"]
                    .as_str()
                    .is_some_and(tea_owned_command))
                .count(),
            1
        );
        assert!(doc["hooks"]["preCompact"].as_array().unwrap().len() == 1);
    }

    #[test]
    fn merge_preserves_foreign_claude_hooks() {
        let mut doc = json!({
            "hooks": {
                "PostToolUse": [{
                    "matcher": "Task",
                    "hooks": [{ "type": "command", "command": "entire hooks claude-code post-task" }]
                }]
            }
        });
        merge_claude_style(
            &mut doc,
            &hook_command(Agent::Claude),
            Value::String("Bash".into()),
        );
        merge_claude_style(
            &mut doc,
            &hook_command(Agent::Claude),
            Value::String("Bash".into()),
        );
        let arr = doc["hooks"]["PostToolUse"].as_array().unwrap();
        assert_eq!(arr.len(), 2);
    }

    #[test]
    fn run_hook_silent_when_fast() {
        let input = r#"{"duration": 100, "output": "ok"}"#;
        let mut out = Vec::new();
        let code = run_hook(Agent::Cursor, &mut Cursor::new(input), &mut out).unwrap();
        assert_eq!(code, 0);
        assert!(out.is_empty());
    }

    #[test]
    fn run_hook_emits_on_slow_with_tea_line() {
        let input = json!({
            "duration_ms": 8000,
            "tool_response": { "output": "stdout\n[tea] --id 3 /tmp/x.tea | grep x\n" }
        })
        .to_string();
        let mut out = Vec::new();
        let code = run_hook(Agent::Claude, &mut Cursor::new(input), &mut out).unwrap();
        assert_eq!(code, 0);
        let s = String::from_utf8(out).unwrap();
        assert!(s.contains("additionalContext") || s.contains("systemMessage"));
        assert!(s.contains("[tea] --id 3"));
        assert!(s.contains("8000"));
    }
}
