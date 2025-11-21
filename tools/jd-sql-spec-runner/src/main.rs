use std::{fs, path::PathBuf, process};

use anyhow::{anyhow, Context, Result};
use clap::Parser;
use serde::Deserialize;
use serde_json::Value as JsonValue;

#[derive(Debug, Deserialize, Clone)]
struct Config {
    // Which SQL engine to use. For now only "postgres" is supported.
    engine: String,
    // Connection string/DSN. Example: postgres://postgres:postgres@localhost:5432/postgres
    dsn: String,
    // SQL to execute. Use $1 and $2 as parameters for the two input JSON docs.
    // Optionally $3 for options header if supported in the future.
    // Example: SELECT jd_diff($1::jsonb, $2::jsonb)::text
    sql: String,
}

#[derive(Parser, Debug)]
#[command(name = "jd-sql-spec-runner", about = "jd-sql test harness calling SQL implementation")]
struct Cli {
    /// Path to YAML config file for selecting SQL engine and query
    /// If omitted, the runner will search for jd-sql-spec.yaml in:
    ///   1) current working directory
    ///   2) the directory containing this executable
    #[arg(short, long, value_name = "FILE")]
    config: Option<PathBuf>,

    /// First input file (created by upstream test harness)
    file1: Option<PathBuf>,
    /// Second input file (created by upstream test harness)
    file2: Option<PathBuf>,

    /// Additional args (ignored for now; reserved for jd-like flags)
    #[arg(last = true)]
    extra: Vec<String>,
}

#[tokio::main]
async fn main() {
    match run().await {
        Ok(code) => process::exit(code),
        Err(err) => {
            eprintln!("{}", err);
            // Runner error distinct from diff/no-diff semantics
            process::exit(2);
        }
    }
}

async fn run() -> Result<i32> {
    let cli = Cli::parse();

    // The upstream spec runner passes args first, then two file paths. We tolerate extra args.
    let (file1, file2) = parse_files_from_args(&cli)?;

    // Resolve config path, allowing auto-discovery when -c/--config is not provided.
    let cfg_path = resolve_config_path(cli.config.as_ref())?;
    let cfg_bytes = fs::read(&cfg_path)
        .with_context(|| format!("failed to read config file: {}", cfg_path.display()))?;
    let cfg: Config = serde_yaml::from_slice(&cfg_bytes)
        .with_context(|| format!("failed to parse YAML config: {}", cfg_path.display()))?;

    let result = match cfg.engine.as_str() {
        "postgres" | "pg" => run_postgres(&cfg, &file1, &file2).await?,
        other => {
            return Err(anyhow!(
                "unsupported engine '{}' (supported: postgres)",
                other
            ));
        }
    };

    // Print output (if any) and compute exit code semantics:
    // 0 => no diff, 1 => diff present
    let mut exit_code = 0;
    match result {
        QueryResult::None => {
            exit_code = 0;
        }
        QueryResult::Text(s) => {
            // Do not force trailing newline
            print!("{}", s);
            // Determine diff presence for TEXT: treat whitespace-only as no-diff
            if !s.trim().is_empty() {
                exit_code = 1;
            }
        }
        QueryResult::Json(v) => {
            // Compact JSON output
            print!("{}", serde_json::to_string(&v)?);
            // Determine diff presence for JSON outputs
            exit_code = json_diff_present(&v) as i32;
        }
    }

    Ok(exit_code)
}

fn parse_files_from_args(cli: &Cli) -> Result<(PathBuf, PathBuf)> {
    // The clap struct has file1/file2 as options; if not set, try to pick from extra tail args
    let mut a = cli.file1.clone();
    let mut b = cli.file2.clone();
    if a.is_none() || b.is_none() {
        // Look for last two entries in extra that look like paths
        if cli.extra.len() >= 2 {
            let len = cli.extra.len();
            if a.is_none() {
                a = Some(PathBuf::from(&cli.extra[len - 2]));
            }
            if b.is_none() {
                b = Some(PathBuf::from(&cli.extra[len - 1]));
            }
        }
    }
    let a = a.ok_or_else(|| anyhow!("missing first input file argument"))?;
    let b = b.ok_or_else(|| anyhow!("missing second input file argument"))?;
    Ok((a, b))
}

enum QueryResult {
    Text(String),
    Json(JsonValue),
    None,
}

async fn run_postgres(cfg: &Config, file1: &PathBuf, file2: &PathBuf) -> Result<QueryResult> {
    // Read input documents as raw text
    let a_text = fs::read_to_string(file1)
        .with_context(|| format!("failed to read input file A: {}", file1.display()))?;
    let b_text = fs::read_to_string(file2)
        .with_context(|| format!("failed to read input file B: {}", file2.display()))?;

    // Interpret empty files as "void" (SQL NULL). Otherwise, parse as JSON.
    // This aligns with the jd spec cases empty_to_value/value_to_empty.
    let a_param: Option<JsonValue> = if a_text.trim().is_empty() {
        None
    } else {
        Some(
            serde_json::from_str(&a_text)
                .with_context(|| format!("invalid JSON in {}", file1.display()))?,
        )
    };
    let b_param: Option<JsonValue> = if b_text.trim().is_empty() {
        None
    } else {
        Some(
            serde_json::from_str(&b_text)
                .with_context(|| format!("invalid JSON in {}", file2.display()))?,
        )
    };

    // Connect to Postgres
    let (client, connection) = tokio_postgres::connect(&cfg.dsn, tokio_postgres::NoTls)
        .await
        .with_context(|| format!("failed to connect to postgres: {}", cfg.dsn))?;

    // Spawn the connection driver
    tokio::spawn(async move {
        if let Err(e) = connection.await {
            eprintln!("postgres connection error: {}", e);
        }
    });

    // Prepare and execute SQL
    // We assume cfg.sql returns text output in jd diff structural format or empty string
    let stmt = client.prepare(&cfg.sql).await.context("prepare SQL failed")?;

    let rows = client
        // Pass NULL for voids by binding None; SQL casts ($1::jsonb) will receive NULLs.
        .query(&stmt, &[&a_param, &b_param])
        .await
        .context("SQL execution failed")?;

    if rows.is_empty() {
        // No output
        return Ok(QueryResult::None);
    }

    // Accept either TEXT or JSONB result. If JSONB, print compact JSON.
    // Try TEXT first.
    if let Ok(v) = rows[0].try_get::<_, String>(0) {
        return Ok(QueryResult::Text(v));
    }
    if let Ok(v) = rows[0].try_get::<_, JsonValue>(0) {
        return Ok(QueryResult::Json(v));
    }

    Err(anyhow!("unsupported result type in first column; expected text or json"))
}

fn resolve_config_path(opt: Option<&PathBuf>) -> Result<PathBuf> {
    if let Some(p) = opt {
        return Ok(p.clone());
    }

    // 1) current working directory
    let cwd = std::env::current_dir().context("cannot determine current working directory")?;
    let cwd_cfg = cwd.join("jd-sql-spec.yaml");
    if cwd_cfg.is_file() {
        return Ok(cwd_cfg);
    }

    // 2) directory where the executable is located
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            let exe_cfg = dir.join("jd-sql-spec.yaml");
            if exe_cfg.is_file() {
                return Ok(exe_cfg);
            }
        }
    }

    Err(anyhow!(
        "config file not found. Provide -c <file> or place jd-sql-spec.yaml in the current directory or next to the executable"
    ))
}

fn json_diff_present(v: &JsonValue) -> bool {
    match v {
        JsonValue::Null => false,
        JsonValue::Bool(b) => *b, // unlikely result type; treat true as diff
        JsonValue::Number(n) => n.as_i64().unwrap_or(0) != 0, // conservative
        JsonValue::String(s) => !s.is_empty(),
        JsonValue::Array(arr) => !arr.is_empty(),
        JsonValue::Object(map) => !map.is_empty(),
    }
}
