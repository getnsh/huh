//! The system's spell checker, for the learning pass.
//!
//! The Mac asks `NSSpellChecker` whether a word is real; Windows has had the
//! same service since Windows 8, behind `ISpellCheckerFactory`, with the same
//! dictionaries Word and Edge underline with. Nothing is bundled and nothing
//! leaves the machine. A word the user has added to the Windows dictionary
//! counts as known here too, which is the right answer.
use huh_core::vocabulary::SpellCheck;

/// The language to check in, from the app's locale: `en_US` becomes `en-US`.
fn tag(locale: &str) -> String {
    let tag = locale.replace('_', "-");
    if tag.is_empty() {
        "en-US".into()
    } else {
        tag
    }
}

/// Built on the thread that uses it: COM objects stay where they were made.
pub fn system(locale: &str) -> Box<dyn SpellCheck> {
    platform::create(&tag(locale)).unwrap_or_else(|| Box::new(huh_core::vocabulary::NoSpellCheck))
}

#[cfg(windows)]
mod platform {
    use huh_core::vocabulary::SpellCheck;
    use windows::core::{HSTRING, PCWSTR};
    use windows::Win32::Foundation::S_OK;
    use windows::Win32::Globalization::{ISpellChecker, ISpellCheckerFactory, SpellCheckerFactory};
    use windows::Win32::System::Com::{
        CoCreateInstance, CoInitializeEx, CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED,
    };

    struct System {
        checker: ISpellChecker,
    }

    impl SpellCheck for System {
        fn is_misspelled(&self, word: &str) -> bool {
            let wide = HSTRING::from(word);
            unsafe {
                let Ok(errors) = self.checker.Check(PCWSTR(wide.as_ptr())) else {
                    return false;
                };
                let mut first = None;
                errors.Next(&mut first) == S_OK && first.is_some()
            }
        }
    }

    pub fn create(tag: &str) -> Option<Box<dyn SpellCheck>> {
        unsafe {
            let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
            let factory: ISpellCheckerFactory =
                CoCreateInstance(&SpellCheckerFactory, None, CLSCTX_INPROC_SERVER).ok()?;
            let wanted = HSTRING::from(tag);
            let fallback = HSTRING::from("en-US");
            let language = if factory
                .IsSupported(&wanted)
                .map(|b| b.as_bool())
                .unwrap_or(false)
            {
                wanted
            } else {
                fallback
            };
            let checker = factory.CreateSpellChecker(&language).ok()?;
            Some(Box::new(System { checker }))
        }
    }
}

#[cfg(not(windows))]
mod platform {
    use huh_core::vocabulary::SpellCheck;

    pub fn create(_tag: &str) -> Option<Box<dyn SpellCheck>> {
        None
    }
}

#[cfg(all(test, windows))]
mod tests {
    use super::*;

    #[test]
    fn the_system_dictionary_knows_english_and_not_a_mishearing() {
        let spell = system("en_US");
        assert!(!spell.is_misspelled("meeting"));
        assert!(spell.is_misspelled("cubernetties"));
    }

    /// What the name detector leans on: Windows knows many names as proper
    /// nouns, so "Priya" passes, but not written in lower case, which is how
    /// the detector asks. An ordinary word capitalised, "Zoom", passes both
    /// ways, and so is never taken for a person.
    #[test]
    fn a_name_is_only_a_word_with_its_capital() {
        let spell = system("en_US");
        assert!(spell.is_misspelled("priya"));
        assert!(spell.is_misspelled("okonkwo"));
        assert!(!spell.is_misspelled("zoom"));
    }
}
