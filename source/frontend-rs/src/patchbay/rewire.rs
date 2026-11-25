// SPDX-License-Identifier: GPL-2.0-or-later

//! Smart port matching for in-place plugin replacement.
//! Preserves audio, MIDI, CV, and sidechain connections when swapping one plugin for another.

#![allow(dead_code)]

use std::collections::HashSet;

use crate::ffi::types::*;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum PortKind {
    Audio,
    Midi,
    Cv,
    Other,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AudioRole {
    Main,
    Sidechain,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ChannelHint {
    Left,
    Right,
    Center,
    Indexed(u32),
    Unknown,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RewirePort {
    pub port_id: u32,
    pub name: String,
    pub is_input: bool,
    pub hints: u32,
    /// Zero-based index within the same (is_input, kind, role) group.
    pub role_index: usize,
}

impl RewirePort {
    pub fn kind(&self) -> PortKind {
        kind_from_hints(self.hints)
    }

    pub fn audio_role(&self) -> AudioRole {
        if self.kind() == PortKind::Audio && is_sidechain_name(&self.name) {
            AudioRole::Sidechain
        } else {
            AudioRole::Main
        }
    }

    pub fn channel_hint(&self) -> ChannelHint {
        parse_channel_hint(&self.name)
    }
}

/// A connection anchored to the old plugin before replacement.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CapturedConnection {
    /// The port on the plugin being replaced.
    pub old_port: RewirePort,
    /// The remote peer group name.
    pub peer_group_name: String,
    /// The remote peer port name.
    pub peer_port_name: String,
    /// True if the remote peer port is an input (meaning `old_port` is an output).
    pub peer_is_input: bool,
}

/// A planned connection to establish on the replacement plugin.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RewireAction {
    pub new_port_id: u32,
    pub new_port_is_input: bool,
    pub peer_group_name: String,
    pub peer_port_name: String,
    pub peer_is_input: bool,
}

pub fn kind_from_hints(hints: u32) -> PortKind {
    if (hints & PATCHBAY_PORT_TYPE_AUDIO) != 0 {
        PortKind::Audio
    } else if (hints & PATCHBAY_PORT_TYPE_MIDI) != 0 {
        PortKind::Midi
    } else if (hints & PATCHBAY_PORT_TYPE_CV) != 0 {
        PortKind::Cv
    } else {
        PortKind::Other
    }
}

pub fn is_sidechain_name(name: &str) -> bool {
    let lower = name.to_ascii_lowercase();
    if lower.contains("sidechain")
        || lower.contains("side chain")
        || lower.contains("side-chain")
        || lower.contains("side_chain")
        || lower.contains("external")
        || lower.contains("key in")
        || lower.contains("key_in")
        || lower.contains("key-in")
    {
        return true;
    }
    // Check standalone tokens: "sc", "key", "ext"
    for tok in lower.split(|c: char| !c.is_ascii_alphanumeric()) {
        if matches!(tok, "sc" | "key" | "ext" | "sidechain") {
            return true;
        }
    }
    false
}

pub fn parse_channel_hint(name: &str) -> ChannelHint {
    let lower = name.to_ascii_lowercase();
    let tokens: Vec<&str> = lower
        .split(|c: char| !c.is_ascii_alphanumeric())
        .filter(|t| !t.is_empty())
        .collect();

    // Check explicit stereo/channel tokens from right to left (most specific suffix wins)
    for &tok in tokens.iter().rev() {
        match tok {
            "l" | "left" | "fl" | "ch1" | "in1" | "out1" => return ChannelHint::Left,
            "r" | "right" | "fr" | "ch2" | "in2" | "out2" => return ChannelHint::Right,
            "c" | "center" | "centre" | "mono" | "m" => return ChannelHint::Center,
            _ => {}
        }
    }
    // Trailing integer channel number (e.g. "Audio In 1", "capture_2", "aux3")
    for &tok in tokens.iter().rev() {
        if let Ok(n) = tok.parse::<u32>() {
            return match n {
                1 => ChannelHint::Left,
                2 => ChannelHint::Right,
                other => ChannelHint::Indexed(other),
            };
        }
        let digits: String = tok
            .chars()
            .rev()
            .take_while(|c| c.is_ascii_digit())
            .collect::<String>()
            .chars()
            .rev()
            .collect();
        if !digits.is_empty() {
            if let Ok(n) = digits.parse::<u32>() {
                return match n {
                    1 => ChannelHint::Left,
                    2 => ChannelHint::Right,
                    other => ChannelHint::Indexed(other),
                };
            }
        }
    }
    ChannelHint::Unknown
}

fn normalized_name(s: &str) -> String {
    s.chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .map(|c| c.to_ascii_lowercase())
        .collect()
}

/// Assigns `role_index` within each `(is_input, kind, role)` bucket for a plugin's port list.
pub fn annotate_role_indices(ports: &mut [RewirePort]) {
    let mut counts: std::collections::HashMap<(bool, PortKind, bool), usize> =
        std::collections::HashMap::new();
    for p in ports.iter_mut() {
        let key = (p.is_input, p.kind(), p.audio_role() == AudioRole::Sidechain);
        let idx = counts.entry(key).or_insert(0);
        p.role_index = *idx;
        *idx += 1;
    }
}

fn score_port_pair(old: &RewirePort, new: &RewirePort) -> Option<i32> {
    if old.is_input != new.is_input {
        return None;
    }
    let ok = old.kind();
    let nk = new.kind();
    let compatible = ok == nk
        || (ok == PortKind::Audio && nk == PortKind::Cv)
        || (ok == PortKind::Cv && nk == PortKind::Audio);
    if !compatible {
        return None;
    }

    let mut score: i32 = 0;
    if ok == nk {
        score += 100;
    } else {
        score += 20;
    }

    // Strongly separate Main vs Sidechain audio ports
    if ok == PortKind::Audio && nk == PortKind::Audio {
        if old.audio_role() == new.audio_role() {
            score += 80;
        } else {
            // Never accidentally route main audio into sidechain or vice versa unless nothing else exists
            score -= 120;
        }
    }

    // Exact or normalized name match
    if old.name.eq_ignore_ascii_case(&new.name) {
        score += 60;
    } else if normalized_name(&old.name) == normalized_name(&new.name) {
        score += 45;
    }

    // Channel hint match (Left <-> Left, Right <-> Right, etc.)
    let oh = old.channel_hint();
    let nh = new.channel_hint();
    if oh != ChannelHint::Unknown && nh != ChannelHint::Unknown {
        if oh == nh {
            score += 35;
        } else if (oh == ChannelHint::Center && matches!(nh, ChannelHint::Left | ChannelHint::Right))
            || (nh == ChannelHint::Center && matches!(oh, ChannelHint::Left | ChannelHint::Right))
        {
            score += 10;
        } else {
            score -= 20;
        }
    }

    // Positional index within the same (direction, kind, role) bucket
    if old.role_index == new.role_index {
        score += 25;
    } else {
        let diff = old.role_index.abs_diff(new.role_index) as i32;
        score -= (diff * 4).min(24);
    }

    if score > 0 { Some(score) } else { None }
}

/// Computes a list of reconnection actions mapping `captured` old connections onto `new_ports`.
///
/// Handles:
/// - Exact/semantic stereo-to-stereo matching
/// - Main vs Sidechain separation
/// - Mono-to-stereo fan-out (if old had 1 main audio port and new has 2, connect mono source/dest cleanly)
/// - Stereo-to-mono fold-down (if old had L+R and new has 1 mono port, both map to that mono port)
pub fn compute_rewire_plan(
    old_ports: &[RewirePort],
    captured: &[CapturedConnection],
    new_ports: &[RewirePort],
) -> Vec<RewireAction> {
    if captured.is_empty() || new_ports.is_empty() {
        return Vec::new();
    }

    // Build best one-to-one mapping from old port_id -> new port_id(s) for each direction
    let mut old_to_new: std::collections::HashMap<(u32, bool), Vec<u32>> =
        std::collections::HashMap::new();

    for is_input in [true, false] {
        let olds: Vec<&RewirePort> = old_ports
            .iter()
            .filter(|p| p.is_input == is_input)
            .collect();
        let news: Vec<&RewirePort> = new_ports
            .iter()
            .filter(|p| p.is_input == is_input)
            .collect();
        if olds.is_empty() || news.is_empty() {
            continue;
        }

        // Greedy highest-score one-to-one pairing first
        let mut pairs: Vec<(i32, usize, usize)> = Vec::new();
        for (oi, o) in olds.iter().enumerate() {
            for (ni, n) in news.iter().enumerate() {
                if let Some(sc) = score_port_pair(o, n) {
                    pairs.push((sc, oi, ni));
                }
            }
        }
        pairs.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.cmp(&b.1)).then_with(|| a.2.cmp(&b.2)));

        let mut used_old = HashSet::new();
        let mut used_new = HashSet::new();
        for (_, oi, ni) in &pairs {
            if used_old.contains(oi) || used_new.contains(ni) {
                continue;
            }
            used_old.insert(*oi);
            used_new.insert(*ni);
            old_to_new
                .entry((olds[*oi].port_id, is_input))
                .or_default()
                .push(news[*ni].port_id);
        }

        // Stereo -> Mono fold-down: if an old Main audio port wasn't paired because new only has 1 Main audio port,
        // fold it onto that single Main audio port.
        let new_main_audio: Vec<&RewirePort> = news
            .iter()
            .copied()
            .filter(|p| p.kind() == PortKind::Audio && p.audio_role() == AudioRole::Main)
            .collect();
        if new_main_audio.len() == 1 {
            let mono_id = new_main_audio[0].port_id;
            for (oi, o) in olds.iter().enumerate() {
                if !used_old.contains(&oi)
                    && o.kind() == PortKind::Audio
                    && o.audio_role() == AudioRole::Main
                {
                    old_to_new
                        .entry((o.port_id, is_input))
                        .or_default()
                        .push(mono_id);
                }
            }
        }

        // Mono -> Stereo fan-out: if old had exactly 1 Main audio input and new has 2 Main audio inputs,
        // feed the mono source into both L and R of the new stereo plugin so output isn't one-sided.
        if is_input {
            let old_main_audio: Vec<&RewirePort> = olds
                .iter()
                .copied()
                .filter(|p| p.kind() == PortKind::Audio && p.audio_role() == AudioRole::Main)
                .collect();
            if old_main_audio.len() == 1 && new_main_audio.len() == 2 {
                let target_ids = old_to_new
                    .entry((old_main_audio[0].port_id, true))
                    .or_default();
                for np in &new_main_audio {
                    if !target_ids.contains(&np.port_id) {
                        target_ids.push(np.port_id);
                    }
                }
            }
        }
    }

    let mut actions = Vec::new();
    let mut seen = HashSet::new();
    for cap in captured {
        let targets = old_to_new
            .get(&(cap.old_port.port_id, cap.old_port.is_input))
            .cloned()
            .unwrap_or_default();
        for new_port_id in targets {
            let dedup_key = (
                new_port_id,
                cap.old_port.is_input,
                cap.peer_group_name.clone(),
                cap.peer_port_name.clone(),
                cap.peer_is_input,
            );
            if seen.insert(dedup_key) {
                actions.push(RewireAction {
                    new_port_id,
                    new_port_is_input: cap.old_port.is_input,
                    peer_group_name: cap.peer_group_name.clone(),
                    peer_port_name: cap.peer_port_name.clone(),
                    peer_is_input: cap.peer_is_input,
                });
            }
        }
    }
    actions
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mk_port(id: u32, name: &str, is_input: bool, hints: u32) -> RewirePort {
        let mut h = hints;
        if is_input {
            h |= PATCHBAY_PORT_IS_INPUT;
        }
        RewirePort {
            port_id: id,
            name: name.into(),
            is_input,
            hints: h,
            role_index: 0,
        }
    }

    #[test]
    fn stereo_renamed_ports_match_cleanly() {
        let mut old = vec![
            mk_port(1, "in_l", true, PATCHBAY_PORT_TYPE_AUDIO),
            mk_port(2, "in_r", true, PATCHBAY_PORT_TYPE_AUDIO),
            mk_port(3, "out_l", false, PATCHBAY_PORT_TYPE_AUDIO),
            mk_port(4, "out_r", false, PATCHBAY_PORT_TYPE_AUDIO),
        ];
        annotate_role_indices(&mut old);

        let mut new = vec![
            mk_port(10, "Audio In 1", true, PATCHBAY_PORT_TYPE_AUDIO),
            mk_port(11, "Audio In 2", true, PATCHBAY_PORT_TYPE_AUDIO),
            mk_port(12, "Audio Out 1", false, PATCHBAY_PORT_TYPE_AUDIO),
            mk_port(13, "Audio Out 2", false, PATCHBAY_PORT_TYPE_AUDIO),
        ];
        annotate_role_indices(&mut new);

        let captured = vec![
            CapturedConnection {
                old_port: old[0].clone(),
                peer_group_name: "System".into(),
                peer_port_name: "capture_1".into(),
                peer_is_input: false,
            },
            CapturedConnection {
                old_port: old[1].clone(),
                peer_group_name: "System".into(),
                peer_port_name: "capture_2".into(),
                peer_is_input: false,
            },
            CapturedConnection {
                old_port: old[2].clone(),
                peer_group_name: "System".into(),
                peer_port_name: "playback_1".into(),
                peer_is_input: true,
            },
            CapturedConnection {
                old_port: old[3].clone(),
                peer_group_name: "System".into(),
                peer_port_name: "playback_2".into(),
                peer_is_input: true,
            },
        ];

        let plan = compute_rewire_plan(&old, &captured, &new);
        assert_eq!(plan.len(), 4);
        assert_eq!(plan[0].new_port_id, 10);
        assert_eq!(plan[1].new_port_id, 11);
        assert_eq!(plan[2].new_port_id, 12);
        assert_eq!(plan[3].new_port_id, 13);
    }

    #[test]
    fn sidechain_ports_do_not_steal_main_audio() {
        let mut old = vec![
            mk_port(1, "Input Left", true, PATCHBAY_PORT_TYPE_AUDIO),
            mk_port(2, "Input Right", true, PATCHBAY_PORT_TYPE_AUDIO),
            mk_port(3, "Sidechain Left", true, PATCHBAY_PORT_TYPE_AUDIO),
        ];
        annotate_role_indices(&mut old);

        // New plugin lists sidechain FIRST before main inputs
        let mut new = vec![
            mk_port(20, "SC In L", true, PATCHBAY_PORT_TYPE_AUDIO),
            mk_port(21, "Main In L", true, PATCHBAY_PORT_TYPE_AUDIO),
            mk_port(22, "Main In R", true, PATCHBAY_PORT_TYPE_AUDIO),
        ];
        annotate_role_indices(&mut new);

        let captured = vec![
            CapturedConnection {
                old_port: old[0].clone(),
                peer_group_name: "Bus".into(),
                peer_port_name: "out_L".into(),
                peer_is_input: false,
            },
            CapturedConnection {
                old_port: old[1].clone(),
                peer_group_name: "Bus".into(),
                peer_port_name: "out_R".into(),
                peer_is_input: false,
            },
            CapturedConnection {
                old_port: old[2].clone(),
                peer_group_name: "Kick".into(),
                peer_port_name: "out".into(),
                peer_is_input: false,
            },
        ];

        let plan = compute_rewire_plan(&old, &captured, &new);
        assert_eq!(plan.len(), 3);
        assert_eq!(plan[0].new_port_id, 21); // Main L -> Main In L
        assert_eq!(plan[1].new_port_id, 22); // Main R -> Main In R
        assert_eq!(plan[2].new_port_id, 20); // Sidechain -> SC In L
    }

    #[test]
    fn mono_to_stereo_input_fans_out_and_midi_preserved() {
        let mut old = vec![
            mk_port(1, "Input", true, PATCHBAY_PORT_TYPE_AUDIO),
            mk_port(2, "MIDI In", true, PATCHBAY_PORT_TYPE_MIDI),
        ];
        annotate_role_indices(&mut old);

        let mut new = vec![
            mk_port(30, "In L", true, PATCHBAY_PORT_TYPE_AUDIO),
            mk_port(31, "In R", true, PATCHBAY_PORT_TYPE_AUDIO),
            mk_port(32, "Events In", true, PATCHBAY_PORT_TYPE_MIDI),
        ];
        annotate_role_indices(&mut new);

        let captured = vec![
            CapturedConnection {
                old_port: old[0].clone(),
                peer_group_name: "Mic".into(),
                peer_port_name: "capture_1".into(),
                peer_is_input: false,
            },
            CapturedConnection {
                old_port: old[1].clone(),
                peer_group_name: "Keyboard".into(),
                peer_port_name: "midi_out".into(),
                peer_is_input: false,
            },
        ];

        let plan = compute_rewire_plan(&old, &captured, &new);
        assert_eq!(plan.len(), 3);
        assert!(plan.iter().any(|a| a.new_port_id == 30 && a.peer_group_name == "Mic"));
        assert!(plan.iter().any(|a| a.new_port_id == 31 && a.peer_group_name == "Mic"));
        assert!(plan.iter().any(|a| a.new_port_id == 32 && a.peer_group_name == "Keyboard"));
    }
}
