/// Build-time tool:
///   adblock-serialize filters <filters.txt> <engine.dat>
///   adblock-serialize resources <war_dir> <redirect-resources.js> <scriptlets.js> <resources.json>

use adblock::lists::ParseOptions;
use adblock::Engine;
use std::path::Path;

#[allow(deprecated)]
fn main() {
    let args: Vec<String> = std::env::args().collect();

    if args.len() < 2 {
        eprintln!("Usage:");
        eprintln!("  adblock-serialize filters <filters.txt> <engine.dat>");
        eprintln!("  adblock-serialize resources <war_dir> <redirect-resources.js> <scriptlets.js> <resources.json>");
        std::process::exit(1);
    }

    match args[1].as_str() {
        "filters" => {
            if args.len() != 4 {
                eprintln!("Usage: adblock-serialize filters <filters.txt> <engine.dat>");
                std::process::exit(1);
            }
            let text = std::fs::read_to_string(&args[2]).expect("failed to read filter list");
            let rules: Vec<String> = text.lines().map(String::from).collect();
            let rule_count = rules.len();
            let engine = Engine::from_rules(rules, ParseOptions::default());
            let data = engine.serialize();
            std::fs::write(&args[3], &data).expect("failed to write engine.dat");
            eprintln!("Serialized {} rules -> {} bytes", rule_count, data.len());
        }
        "resources" => {
            if args.len() != 6 {
                eprintln!("Usage: adblock-serialize resources <war_dir> <redirect-resources.js> <scriptlets.js> <resources.json>");
                std::process::exit(1);
            }
            use adblock::resources::resource_assembler::*;
            let mut resources = assemble_web_accessible_resources(
                Path::new(&args[2]),
                Path::new(&args[3]),
            );
            resources.extend(assemble_scriptlet_resources(Path::new(&args[4])));
            let json = serde_json::to_string(&resources).expect("failed to serialize resources");
            std::fs::write(&args[5], &json).expect("failed to write resources.json");
            eprintln!("Assembled {} resources -> {} bytes", resources.len(), json.len());
        }
        _ => {
            eprintln!("Unknown subcommand: {}", args[1]);
            std::process::exit(1);
        }
    }
}
