pub struct Gossip {
    pub lsn: u64,
    pub in_recovery: bool,
    pub reconfirm: bool,
    pub seq: u64,
    pub adopt: bool,
}

pub fn encode_gossip(lsn: u64, in_recovery: bool, reconfirm: bool, seq: u64, adopt: bool) -> Vec<u8> {
    let mut buf = Vec::with_capacity(19);
    buf.extend_from_slice(&lsn.to_be_bytes());
    buf.push(in_recovery as u8);
    buf.push(reconfirm as u8);
    buf.extend_from_slice(&seq.to_be_bytes());
    buf.push(adopt as u8);
    buf
}

pub fn decode_gossip(bytes: &[u8]) -> Option<Gossip> {
    if bytes.len() < 9 {
        return None;
    }
    let mut lsn = [0u8; 8];
    lsn.copy_from_slice(&bytes[..8]);
    let seq = bytes
        .get(10..18)
        .map_or(0, |raw| u64::from_be_bytes(raw.try_into().unwrap()));
    Some(Gossip {
        lsn: u64::from_be_bytes(lsn),
        in_recovery: bytes[8] != 0,
        reconfirm: bytes.get(9).map_or(false, |byte| *byte != 0),
        seq,
        adopt: bytes.get(18).map_or(false, |byte| *byte != 0),
    })
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct Decision {
    pub seq: u64,
    pub primary: u64,
}

pub fn choose_primary(candidates: &[(u64, u64, bool)]) -> Option<u64> {
    candidates
        .iter()
        .max_by(|a, b| {
            a.1.cmp(&b.1)
                .then((!a.2 as u8).cmp(&(!b.2 as u8)))
                .then(b.0.cmp(&a.0))
        })
        .map(|candidate| candidate.0)
}

pub fn parse_lsn(text: &str) -> Option<u64> {
    let (hi, lo) = text.trim().split_once('/')?;
    Some((u64::from_str_radix(hi, 16).ok()? << 32) | u64::from_str_radix(lo, 16).ok()?)
}

pub fn diverged(my_tli: u32, my_lsn: u64, primary_tli: u32, history: &str) -> bool {
    if my_tli == primary_tli {
        return false;
    }
    for line in history.lines() {
        let mut fields = line.split_whitespace();
        let (Some(parent), Some(switch)) = (fields.next(), fields.next()) else {
            continue;
        };
        let (Ok(parent), Some(switch)) = (parent.parse::<u32>(), parse_lsn(switch)) else {
            continue;
        };
        if parent == my_tli {
            return my_lsn > switch;
        }
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    const HISTORY_28: &str = "24\tE/26000000\tno recovery target specified\n\
25\tE/2C000000\tno recovery target specified\n\
26\tE/30003AF8\tbefore transaction 22132 at 2026-10-06 13:48:43.03546+00\n";

    #[test]
    fn gossip_round_trips_adopt_flag() {
        let g = decode_gossip(&encode_gossip(7, false, true, 28, true)).unwrap();
        assert_eq!((g.lsn, g.in_recovery, g.reconfirm, g.seq, g.adopt), (7, false, true, 28, true));
    }

    #[test]
    fn older_gossip_has_no_adopt_flag() {
        let mut old = encode_gossip(7, true, false, 3, true);
        old.truncate(18);
        assert!(!decode_gossip(&old).unwrap().adopt);
    }

    #[test]
    fn parses_lsn() {
        assert_eq!(parse_lsn("E/30003AF8"), Some(0xE_3000_3AF8));
        assert_eq!(parse_lsn("junk"), None);
    }

    #[test]
    fn standby_on_a_timeline_the_primary_never_had_has_diverged() {
        assert!(diverged(27, 0xE_3C00_0000, 28, HISTORY_28));
    }

    #[test]
    fn standby_behind_the_switch_point_can_follow() {
        assert!(!diverged(26, 0xE_3000_0000, 28, HISTORY_28));
        assert!(!diverged(26, 0xE_3000_3AF8, 28, HISTORY_28));
    }

    #[test]
    fn standby_past_the_switch_point_has_diverged() {
        assert!(diverged(26, 0xE_3000_3B00, 28, HISTORY_28));
    }

    #[test]
    fn same_timeline_never_diverges() {
        assert!(!diverged(28, 0xE_4000_0000, 28, ""));
    }
}
