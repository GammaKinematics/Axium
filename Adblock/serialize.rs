/// Build-time tool: reads a filter list and writes a serialized engine .dat file.
///
/// Usage: adblock-serialize <filters.txt> <engine.dat>

use adblock::lists::ParseOptions;
use adblock::Engine;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 3 {
        eprintln!("Usage: adblock-serialize <filters.txt> <engine.dat>");
        std::process::exit(1);
    }

    let text = std::fs::read_to_string(&args[1]).expect("failed to read filter list");
    let rules: Vec<String> = text.lines().map(String::from).collect();
    let rule_count = rules.len();

    let engine = Engine::from_rules(rules, ParseOptions::default());
    let data = engine.serialize();

    std::fs::write(&args[2], &data).expect("failed to write engine.dat");

    eprintln!(
        "Serialized {} rules → {} bytes",
        rule_count,
        data.len()
    );
}
