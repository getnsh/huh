//! The fixtures the Swift engine is held to, run against the Rust one.
//!
//! The point of a shared file is that neither implementation can be "fixed" in
//! a way the other does not follow. A case added here fails on whichever
//! platform has not learned it yet, which is the only way two engines written
//! in two languages stay the same engine.
use huh_core::corrections;
use huh_core::model::CorrectionPair;
use serde::Deserialize;

#[derive(Deserialize)]
struct Fixtures {
    cases: Vec<Case>,
}

#[derive(Deserialize)]
struct Case {
    name: String,
    rules: Vec<Rule>,
    #[serde(rename = "in")]
    input: String,
    #[serde(rename = "out")]
    expected: String,
}

#[derive(Deserialize)]
struct Rule {
    hear: String,
    write: String,
    #[serde(default = "yes")]
    enabled: bool,
}

fn yes() -> bool {
    true
}

#[test]
fn matches_the_shared_fixtures() {
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../../shared/correction-fixtures.json"
    );
    let raw =
        std::fs::read_to_string(path).unwrap_or_else(|e| panic!("could not read {path}: {e}"));
    let fixtures: Fixtures = serde_json::from_str(&raw).expect("fixtures are not valid JSON");
    assert!(!fixtures.cases.is_empty(), "no cases in the fixtures file");

    let mut failures = Vec::new();
    for case in &fixtures.cases {
        let rules: Vec<CorrectionPair> = case
            .rules
            .iter()
            .map(|rule| {
                let mut pair = CorrectionPair::new(&rule.hear, &rule.write);
                pair.enabled = rule.enabled;
                pair
            })
            .collect();
        let result = corrections::apply(&case.input, &rules);
        if result.text != case.expected {
            failures.push(format!(
                "{}\n   in:       {:?}\n   expected: {:?}\n   got:      {:?}",
                case.name, case.input, case.expected, result.text
            ));
        }
    }

    assert!(
        failures.is_empty(),
        "{} of {} fixtures failed:\n\n{}",
        failures.len(),
        fixtures.cases.len(),
        failures.join("\n\n")
    );
}
