//! Writes up a transcript the way the Summarise button does -- the model
//! download if it is missing, loading, reading, writing -- and prints the
//! result with how long each step took.
//!
//! ```text
//! cargo run -p huh --release --example summarise -- path\to\transcript.txt
//! ```
//!
//! For checking the summariser without the interface, or on a transcript
//! that isn't in anyone's history.
use std::time::Instant;

use huh_lib::fetch;
use huh_lib::llm::{self, Llm, Step};

fn main() {
    let Some(path) = std::env::args().nth(1) else {
        eprintln!("usage: summarise <transcript.txt>");
        std::process::exit(2);
    };
    let transcript = std::fs::read_to_string(&path).unwrap_or_else(|e| {
        eprintln!("could not read {path}: {e}");
        std::process::exit(1);
    });

    let folder = llm::directory();
    let started = Instant::now();
    fetch::download(&llm::SOURCE, &folder, &llm::PARTS, &mut |done, total| {
        eprint!(
            "\rdownloading {} of {}   ",
            fetch::readable(done),
            fetch::readable(total)
        );
    })
    .unwrap_or_else(|e| {
        eprintln!("\n{e}");
        std::process::exit(1);
    });
    println!("files in place: {:.1?}", started.elapsed());

    let started = Instant::now();
    let mut model = Llm::load(&folder).unwrap_or_else(|e| {
        eprintln!("{e}");
        std::process::exit(1);
    });
    println!("loaded: {:.1?}", started.elapsed());

    let instructions =
        "You write up meeting notes from a transcript produced by a speech recogniser. \
        The transcript is imperfect: names may be misspelled and sentences garbled. \
        Work only from what is there. Never invent a name, a date, an owner or a \
        decision, and never assign a task to someone the transcript does not name.";
    let prompt = format!(
        "Use exactly these headings, in this order. If a section has nothing, write \"None recorded.\" under it.\n\n\
         ## In one line\nOne sentence: what this was about and what came of it.\n\n\
         ## What was discussed\nThree to five short bullets.\n\n\
         ## Decisions\nBullets. Only what was actually settled.\n\n\
         ## Action items\nBullets formatted \"Owner — task\". Write \"Unassigned\" when no owner is named.\n\n\
         ## Open questions\nBullets.\n\nTranscript:\n{transcript}"
    );
    println!("prompt: {} tokens", model.count(&prompt).unwrap_or(0));

    let started = Instant::now();
    let mut reading = None;
    let mut writing = None;
    let mut words = 0;
    let text = model
        .respond(instructions, &prompt, 1024, &mut |step| match step {
            Step::Reading { done, total } => {
                if done == total {
                    reading = Some(started.elapsed());
                }
            }
            Step::Writing { text } => {
                if writing.is_none() {
                    writing = Some(started.elapsed());
                }
                words = text.split_whitespace().count();
            }
        })
        .unwrap_or_else(|e| {
            eprintln!("{e}");
            std::process::exit(1);
        });
    println!(
        "read in {:.1?}, first word at {:.1?}, {words} words in {:.1?}\n",
        reading.unwrap_or_default(),
        writing.unwrap_or_default(),
        started.elapsed()
    );
    println!("{text}");
}
