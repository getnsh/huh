//! Qwen3 4B, run on this PC through ONNX Runtime, for meeting summaries.
//!
//! The Mac runs the same model through MLX on its GPU, downloaded the first
//! time a summary asks for it, and so does this: an int4 build made for ONNX
//! Runtime's CPU kernels, pinned to a commit and checked against its hashes
//! like the recogniser's files.
//!
//! The model is driven by hand rather than through a generation library. Two
//! things about that are worth knowing:
//!
//!  * **One cache, written in place.** Each layer's keys and values live in a
//!    buffer sized for the whole conversation, bound as both the layer's past
//!    input and its present output. ONNX Runtime's attention sees the same
//!    buffer on both sides and appends to it, where otherwise every new word
//!    would copy the whole cache, which for an hour of meeting is gigabytes a
//!    word.
//!  * **The prompt in pieces.** The model returns scores for every position it
//!    is given, and a whole meeting at once would be gigabytes of scores of
//!    which only the last row is wanted. Fed a few hundred words at a time, the
//!    cache fills the same and the scores stay small.
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use ort::memory::{AllocationDevice, AllocatorType, MemoryInfo, MemoryType};
use ort::session::builder::GraphOptimizationLevel;
use ort::session::Session;
use ort::value::Tensor;
use tokenizers::Tokenizer;

use crate::fetch::{Part, Source};

pub const DISPLAY_NAME: &str = "Qwen3 4B";

pub const SOURCE: Source = Source {
    repository: "onnx-community/Qwen3-4B-ONNX",
    revision: "98ddba15d05dede4435afb63f13280abcdbc2a48",
    prefix: "onnxruntime/cpu_and_mobile/cpu-int4-kld-block-128/",
};

pub const PARTS: [Part; 3] = [
    Part {
        name: "tokenizer.json",
        bytes: 11_422_648,
        sha256: "979d160e081df25a1bf7f4e2e8f4c441b5dfdc9a8e84aec9f32e80445e1b59b8",
    },
    Part {
        name: "model.onnx",
        bytes: 519_634,
        sha256: "b4547cf9327bd532cb81703cf013f958117ba5a3e5a81c7c79a33aba534ff337",
    },
    Part {
        name: "model.onnx.data",
        bytes: 2_885_434_880,
        sha256: "d6003acd70841b99a44ce4c21d13dc42244e3ec3b7c12d70919f9b55440bbc45",
    },
];

/// What the three files come to, for the interface to quote before anyone
/// commits to fetching them.
pub fn download_size() -> u64 {
    PARTS.iter().map(|part| part.bytes).sum()
}

const FOLDER: &str = "qwen3-4b-int4";

/// The model's shape, from its configuration.
const LAYERS: usize = 36;
const KV_HEADS: usize = 8;
const HEAD_SIZE: usize = 128;

/// `<|im_end|>` and `<|endoftext|>`: either ends the answer.
const END_OF_TURN: u32 = 151_645;
const END_OF_TEXT: u32 = 151_643;

/// How much of the prompt goes in at a time. The scores for a piece this size
/// are 150 MB; for a whole meeting they would be several gigabytes. Reading
/// is no faster in larger pieces: on a laptop's processor the model reads
/// about fifty tokens a second however it is fed.
const PIECE: usize = 256;

/// The longest conversation the cache is allowed to reach: about two hours of
/// meeting. Each position costs 288 KB of cache across the 36 layers, so this
/// is seven gigabytes at the very most, and an ordinary meeting a fraction.
pub const LONGEST: usize = 24_576;

/// Qwen3's own advice for answers without reasoning.
const TEMPERATURE: f32 = 0.7;
const TOP_K: usize = 20;
const TOP_P: f32 = 0.8;

/// Where the model lives: beside the recogniser, in `%LOCALAPPDATA%`, which
/// is never roamed. `HUH_LLM_DIR` names the folder directly, for development.
pub fn directory() -> PathBuf {
    if let Ok(explicit) = std::env::var("HUH_LLM_DIR") {
        return PathBuf::from(explicit);
    }
    crate::speech::models_root().join(FOLDER)
}

/// What a long generation reports while it works.
pub enum Step<'a> {
    /// The prompt, read so far, in tokens.
    Reading { done: usize, total: usize },
    /// The answer so far.
    Writing { text: &'a str },
}

pub struct Llm {
    session: Session,
    tokenizer: Tokenizer,
}

impl Llm {
    pub fn load(folder: &Path) -> Result<Self, String> {
        let tokenizer = Tokenizer::from_file(folder.join("tokenizer.json"))
            .map_err(|e| format!("Couldn't read the model's vocabulary: {e}"))?;
        // Half the logical processors, which on a machine with two threads a
        // core is one per core: the most the matrix work gains from, and it
        // leaves the rest for dictation, which may be happening meanwhile.
        let threads = std::thread::available_parallelism()
            .map(|n| (n.get() / 2).max(1))
            .unwrap_or(4);
        let failed = |e: String| format!("Couldn't load the model: {e}");
        let session = Session::builder()
            .map_err(|e| failed(e.to_string()))?
            .with_optimization_level(GraphOptimizationLevel::Level3)
            .map_err(|e| failed(e.to_string()))?
            .with_intra_threads(threads)
            .map_err(|e| failed(e.to_string()))?
            .commit_from_file(folder.join("model.onnx"))
            .map_err(|e| failed(e.to_string()))?;
        Ok(Self { session, tokenizer })
    }

    /// The model's token count for `text`, for checking a prompt will fit.
    pub fn count(&self, text: &str) -> Result<usize, String> {
        self.tokenizer
            .encode(text, false)
            .map(|encoding| encoding.len())
            .map_err(|e| e.to_string())
    }

    /// One question, one fresh conversation, answered without reasoning, as
    /// the Mac asks it with `/no_think`. Nothing carries over between calls.
    pub fn respond(
        &mut self,
        instructions: &str,
        prompt: &str,
        most: usize,
        report: &mut dyn FnMut(Step),
    ) -> Result<String, String> {
        let text = chat(instructions, prompt);
        let ids: Vec<u32> = self
            .tokenizer
            .encode(text, false)
            .map_err(|e| e.to_string())?
            .get_ids()
            .to_vec();
        if ids.len() + most > LONGEST {
            return Err(
                "That transcript is longer than the model can read at once — about two hours."
                    .into(),
            );
        }
        let capacity = ids.len() + most;
        let failed = |e: ort::Error| format!("The model stopped: {e}");

        // The cache: one buffer per layer and kind, bound to both sides.
        let mut binding = self.session.create_binding().map_err(failed)?;
        {
            let allocator = self.session.allocator();
            for layer in 0..LAYERS {
                for kind in ["key", "value"] {
                    let buffer =
                        Tensor::<f32>::new(allocator, [1usize, KV_HEADS, capacity, HEAD_SIZE])
                            .map_err(failed)?;
                    binding
                        .bind_input(format!("past_key_values.{layer}.{kind}"), &buffer)
                        .map_err(failed)?;
                    binding
                        .bind_output(format!("present.{layer}.{kind}"), buffer)
                        .map_err(failed)?;
                }
            }
        }
        let cpu = MemoryInfo::new(
            AllocationDevice::CPU,
            0,
            AllocatorType::Device,
            MemoryType::Default,
        )
        .map_err(failed)?;

        // Reading: the prompt, a piece at a time, keeping only the last
        // position's scores.
        let mut position = 0usize;
        let mut scores = Vec::new();
        for piece in ids.chunks(PIECE) {
            scores = self.step(&mut binding, &cpu, piece, position)?;
            position += piece.len();
            report(Step::Reading {
                done: position,
                total: ids.len(),
            });
        }

        // Writing: a word at a time until the model says it is done.
        let mut seed = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos() as u64)
            .unwrap_or(0x9E37_79B9_7F4A_7C15)
            | 1;
        let mut answer: Vec<u32> = Vec::new();
        while answer.len() < most {
            let next = sample(&scores, &mut seed);
            if next == END_OF_TURN || next == END_OF_TEXT {
                break;
            }
            answer.push(next);
            let so_far = self
                .tokenizer
                .decode(&answer, true)
                .map_err(|e| e.to_string())?;
            report(Step::Writing {
                text: without_thinking(&so_far),
            });
            if position + 1 >= capacity {
                break;
            }
            scores = self.step(&mut binding, &cpu, &[next], position)?;
            position += 1;
        }
        let text = self
            .tokenizer
            .decode(&answer, true)
            .map_err(|e| e.to_string())?;
        Ok(without_thinking(&text).trim().to_string())
    }

    /// Runs `tokens` through the model after `before` tokens already in the
    /// cache, and returns the scores for the last of them.
    fn step(
        &mut self,
        binding: &mut ort::session::IoBinding,
        cpu: &MemoryInfo,
        tokens: &[u32],
        before: usize,
    ) -> Result<Vec<f32>, String> {
        let failed = |e: ort::Error| format!("The model stopped: {e}");
        // Bound afresh every time: once allocated, an output bound to a device
        // keeps its first shape, and the scores are as long as the input.
        binding
            .bind_output_to_device("logits", cpu)
            .map_err(failed)?;
        let ids: Vec<i64> = tokens.iter().map(|&t| i64::from(t)).collect();
        let total = before + tokens.len();
        let input = Tensor::from_array(([1usize, tokens.len()], ids)).map_err(failed)?;
        let mask = Tensor::from_array(([1usize, total], vec![1i64; total])).map_err(failed)?;
        binding.bind_input("input_ids", &input).map_err(failed)?;
        binding
            .bind_input("attention_mask", &mask)
            .map_err(failed)?;
        let outputs = self.session.run_binding(binding).map_err(failed)?;
        let (shape, logits) = outputs["logits"]
            .try_extract_tensor::<f32>()
            .map_err(failed)?;
        let vocabulary = *shape.last().unwrap_or(&0) as usize;
        if vocabulary == 0 || logits.len() < vocabulary {
            return Err("The model returned no scores.".into());
        }
        Ok(logits[logits.len() - vocabulary..].to_vec())
    }
}

/// Qwen3's chat template, with reasoning turned off the way its template does
/// it: an empty thought already written at the start of the answer.
fn chat(instructions: &str, prompt: &str) -> String {
    format!(
        "<|im_start|>system\n{instructions}<|im_end|>\n<|im_start|>user\n{prompt}\n\n/no_think<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
    )
}

/// The answer without any thought the model wrote ahead of it anyway.
fn without_thinking(text: &str) -> &str {
    match text.find("</think>") {
        Some(end) => &text[end + "</think>".len()..],
        None if text.trim_start().starts_with("<think>") => "",
        None => text,
    }
}

/// Picks the next token: the twenty likeliest, softened by the temperature,
/// cut to the smallest set holding 80 % of the probability, drawn from.
fn sample(scores: &[f32], seed: &mut u64) -> u32 {
    let mut order: Vec<usize> = (0..scores.len()).collect();
    let k = TOP_K.min(order.len());
    if k == 0 {
        return END_OF_TEXT;
    }
    order.select_nth_unstable_by(k - 1, |&a, &b| scores[b].total_cmp(&scores[a]));
    order.truncate(k);
    order.sort_by(|&a, &b| scores[b].total_cmp(&scores[a]));

    let top = scores[order[0]];
    let mut weights: Vec<f32> = order
        .iter()
        .map(|&i| ((scores[i] - top) / TEMPERATURE).exp())
        .collect();
    let sum: f32 = weights.iter().sum();
    weights.iter_mut().for_each(|w| *w /= sum);

    let mut kept = 0;
    let mut mass = 0.0;
    for weight in &weights {
        kept += 1;
        mass += weight;
        if mass >= TOP_P {
            break;
        }
    }
    let mut draw = random(seed) * mass;
    for (index, weight) in weights.iter().take(kept).enumerate() {
        draw -= weight;
        if draw <= 0.0 {
            return order[index] as u32;
        }
    }
    order[kept - 1] as u32
}

/// xorshift64*, enough for choosing among twenty words.
fn random(state: &mut u64) -> f32 {
    *state ^= *state >> 12;
    *state ^= *state << 25;
    *state ^= *state >> 27;
    let value = state.wrapping_mul(0x2545_F491_4F6C_DD1D);
    (value >> 40) as f32 / (1u64 << 24) as f32
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_thought_written_anyway_is_not_part_of_the_answer() {
        assert_eq!(
            without_thinking("<think>\nhmm\n</think>\n\n## In one line"),
            "\n\n## In one line"
        );
        assert_eq!(without_thinking("<think>\nstill thinking"), "");
        assert_eq!(without_thinking("## In one line"), "## In one line");
    }

    #[test]
    fn sampling_only_ever_picks_among_the_likeliest() {
        let mut scores = vec![-10.0f32; 1000];
        scores[7] = 9.0;
        scores[42] = 8.5;
        scores[99] = 1.0;
        let mut seed = 12345;
        for _ in 0..200 {
            let pick = sample(&scores, &mut seed);
            assert!(pick == 7 || pick == 42, "picked {pick}");
        }
    }

    #[test]
    fn the_prompt_follows_qwen3s_template() {
        let text = chat("Be brief.", "Hello");
        assert!(text.starts_with("<|im_start|>system\nBe brief.<|im_end|>\n"));
        assert!(text.contains("<|im_start|>user\nHello\n\n/no_think<|im_end|>\n"));
        assert!(text.ends_with("<|im_start|>assistant\n<think>\n\n</think>\n\n"));
    }
}
