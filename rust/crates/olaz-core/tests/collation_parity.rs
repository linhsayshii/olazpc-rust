#![allow(clippy::expect_used, clippy::unwrap_used)]
//! 300+ item parity test verifying `contact_fold` and `localized_standard_cmp` against
//! Swift Foundation's `ZaloEngine.contactFold` + `String.localizedStandardCompare`.

use olaz_core::messages::{contact_fold, localized_standard_cmp};
use serde::Deserialize;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CorpusEntry {
    raw: String,
    folded: String,
    section: String,
    sort_key: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CollationCorpus {
    entries: Vec<CorpusEntry>,
    friend_sorted_raw_order: Vec<usize>,
    sorted_distinct_sort_keys: Vec<String>,
}

fn compute_section(sort_key: &str) -> String {
    sort_key
        .chars()
        .next()
        .map(|c| c.to_ascii_uppercase())
        .filter(char::is_ascii_uppercase)
        .map_or_else(|| "#".to_owned(), |c| c.to_string())
}

#[test]
fn contact_fold_and_collation_match_swift_foundation_300_plus_corpus() {
    let raw_json = include_str!("fixtures/contact_collation_swift_corpus.json");
    let corpus: CollationCorpus = serde_json::from_str(raw_json).expect("valid corpus JSON");
    assert!(
        corpus.entries.len() >= 300,
        "corpus must contain >= 300 items, got {}",
        corpus.entries.len()
    );

    // 1. Exact fold, sortKey, and section parity across every corpus item.
    for (idx, item) in corpus.entries.iter().enumerate() {
        let got_fold = contact_fold(&item.raw);
        assert_eq!(
            got_fold, item.folded,
            "fold mismatch at #{idx} raw={:?}: expected {:?}, got {:?}",
            item.raw, item.folded, got_fold
        );
        let got_key = got_fold.trim().to_owned();
        assert_eq!(
            got_key, item.sort_key,
            "sort_key mismatch at #{idx} raw={:?}",
            item.raw
        );
        let got_section = compute_section(&got_key);
        assert_eq!(
            got_section, item.section,
            "section mismatch at #{idx} raw={:?}",
            item.raw
        );
    }

    // 2. Pairwise ordering parity across all distinct sort keys (O(N^2) ~ 70,000+ comparisons).
    let keys = &corpus.sorted_distinct_sort_keys;
    for i in 0..keys.len() {
        assert_eq!(
            localized_standard_cmp(&keys[i], &keys[i]),
            std::cmp::Ordering::Equal,
            "reflexivity failed for {:?}",
            keys[i]
        );
        for j in (i + 1)..keys.len() {
            let cmp_ij = localized_standard_cmp(&keys[i], &keys[j]);
            assert_eq!(
                cmp_ij,
                std::cmp::Ordering::Less,
                "order mismatch: expected {:?} < {:?}, got {cmp_ij:?}",
                keys[i],
                keys[j]
            );
            let cmp_ji = localized_standard_cmp(&keys[j], &keys[i]);
            assert_eq!(
                cmp_ji,
                std::cmp::Ordering::Greater,
                "antisymmetry mismatch: expected {:?} > {:?}, got {cmp_ji:?}",
                keys[j],
                keys[i]
            );
        }
    }

    // 3. Full friend-list sort order parity (section with '#' last + localized_standard_cmp).
    let mut indices: Vec<usize> = (0..corpus.entries.len()).collect();
    indices.sort_by(|&i, &j| {
        let a = &corpus.entries[i];
        let b = &corpus.entries[j];
        if a.section != b.section {
            if a.section == "#" {
                return std::cmp::Ordering::Greater;
            }
            if b.section == "#" {
                return std::cmp::Ordering::Less;
            }
            return a.section.cmp(&b.section);
        }
        localized_standard_cmp(&a.sort_key, &b.sort_key)
    });
    assert_eq!(indices, corpus.friend_sorted_raw_order);
}
